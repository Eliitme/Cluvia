import Foundation
import Testing
@testable import KubeKit

/// Scripted source: each `list()` returns the next listing, each `watch` the next script of events/failures.
final class ScriptedSource: ListWatchSource, @unchecked Sendable {
    enum Step: Sendable {
        case event(SourceEvent<String>)
        case fail(Error)
        /// Keeps the stream open until the test ends (cancellation).
        case hang
    }

    private let lock = NSLock()
    private var listings: [[String: String]]
    private var scripts: [[Step]]
    private(set) var listCount = 0
    private(set) var watchedFrom: [String] = []

    init(listings: [[String: String]], scripts: [[Step]]) {
        self.listings = listings
        self.scripts = scripts
    }

    func list() async throws -> ListSnapshot<String> {
        let (listing, version) = lock.withLock {
            listCount += 1
            return (listings.isEmpty ? [:] : listings.removeFirst(), "list-\(listCount)")
        }
        return ListSnapshot(items: listing.map { (ObjectKey(namespace: "ns", name: $0.key), $0.value) }, resourceVersion: version)
    }

    func watch(from resourceVersion: String) -> AsyncThrowingStream<SourceEvent<String>, Error> {
        let script = lock.withLock {
            watchedFrom.append(resourceVersion)
            return scripts.isEmpty ? [.hang] : scripts.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                for step in script {
                    switch step {
                    case let .event(event): continuation.yield(event)
                    case let .fail(error): return continuation.finish(throwing: error)
                    case .hang: try? await Task.sleep(for: .seconds(3600))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

struct ReflectorRelistTests {
    static let fast = ReconnectBackoff(initial: .milliseconds(5), maximum: .milliseconds(20))

    static func key(_ name: String) -> ObjectKey { ObjectKey(namespace: "ns", name: name) }

    /// Waits until a snapshot satisfies `condition` or times out.
    static func snapshot<S>(
        of reflector: Reflector<S>, where condition: @escaping @Sendable (ReflectorSnapshot<String>) -> Bool
    ) async throws -> ReflectorSnapshot<String> where S.Item == String {
        try await withThrowingTaskGroup(of: ReflectorSnapshot<String>?.self) { group in
            group.addTask {
                for await snapshot in reflector.updates where condition(snapshot) { return snapshot }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                return nil
            }
            let result = try await group.next() ?? nil
            group.cancelAll()
            return try #require(result)
        }
    }

    @Test func appliesWatchEventsAfterList() async throws {
        let source = ScriptedSource(listings: [["a": "1", "b": "1"]], scripts: [[
            .event(.upsert(Self.key("c"), "1", resourceVersion: "5")),
            .event(.upsert(Self.key("a"), "2", resourceVersion: "6")),
            .event(.delete(Self.key("b"), resourceVersion: "7")),
            .hang,
        ]])
        let reflector = Reflector(source: source, coalesceInterval: .milliseconds(10), backoff: Self.fast)
        await reflector.start()
        let snapshot = try await Self.snapshot(of: reflector) { $0.items == ["2", "1"] }
        #expect(snapshot.phase == .live)
        await reflector.stop()
    }

    @Test func expiredWatchRelistsAndDropsStaleItems() async throws {
        let source = ScriptedSource(
            listings: [["a": "1", "b": "1"], ["b": "2", "c": "1"]],
            scripts: [[.event(.expired)], [.hang]]
        )
        let reflector = Reflector(source: source, coalesceInterval: .milliseconds(10), backoff: Self.fast)
        await reflector.start()
        let snapshot = try await Self.snapshot(of: reflector) { $0.items == ["2", "1"] }
        #expect(snapshot.items.count == 2) // "a" gone, no duplicates of "b"
        #expect(source.listCount == 2)
        #expect(source.watchedFrom == ["list-1", "list-2"])
        await reflector.stop()
    }

    @Test func http410FromWatchRequestAlsoRelists() async throws {
        let gone = KubeAPIError(statusCode: 410, body: Data(#"{"reason":"Expired","message":"too old"}"#.utf8))
        let source = ScriptedSource(listings: [["a": "1"], ["z": "1"]], scripts: [[.fail(gone)], [.hang]])
        let reflector = Reflector(source: source, coalesceInterval: .milliseconds(10), backoff: Self.fast)
        await reflector.start()
        _ = try await Self.snapshot(of: reflector) { $0.items == ["1"] && $0.phase == .live }
        #expect(source.listCount == 2)
        await reflector.stop()
    }

    @Test func networkFailureKeepsItemsAndResumesFromLastVersion() async throws {
        let source = ScriptedSource(listings: [["a": "1"]], scripts: [
            [.event(.upsert(Self.key("b"), "1", resourceVersion: "9")), .fail(URLError(.networkConnectionLost))],
            [.event(.bookmark(resourceVersion: "12"))],
            [.hang],
        ])
        let reflector = Reflector(source: source, coalesceInterval: .milliseconds(10), backoff: Self.fast)
        await reflector.start()
        _ = try await Self.snapshot(of: reflector) { $0.items.count == 2 && $0.phase == .live && source.watchedFrom.count == 3 }
        // No relist: resumed from the last event, then from the bookmark after a normal stream end.
        #expect(source.listCount == 1)
        #expect(source.watchedFrom == ["list-1", "9", "12"])
        await reflector.stop()
    }

    @Test func forbiddenIsReportedAsFailedNotReconnecting() async throws {
        let forbidden = KubeAPIError(statusCode: 403, body: Data(#"{"reason":"Forbidden","message":"no"}"#.utf8))
        let source = ScriptedSource(listings: [["a": "1"]], scripts: [[.fail(forbidden)]])
        let reflector = Reflector(source: source, coalesceInterval: .milliseconds(10), backoff: Self.fast)
        await reflector.start()
        let snapshot = try await Self.snapshot(of: reflector) { if case .failed = $0.phase { true } else { false } }
        #expect(snapshot.items == ["1"])
        await reflector.stop()
    }

    @Test func stopBeforeStartPreventsWatching() async throws {
        let source = ScriptedSource(listings: [["a": "1"]], scripts: [])
        let reflector = Reflector(source: source, coalesceInterval: .milliseconds(10), backoff: Self.fast)
        await reflector.stop()
        await reflector.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(source.listCount == 0)
    }

    @Test func emptyImmediateWatchEndsBackOffInsteadOfSpinning() async throws {
        let source = ScriptedSource(listings: [["a": "1"]], scripts: Array(repeating: [], count: 1000))
        let slow = ReconnectBackoff(initial: .milliseconds(200), maximum: .milliseconds(200))
        let reflector = Reflector(source: source, coalesceInterval: .milliseconds(10), backoff: slow)
        await reflector.start()
        try await Task.sleep(for: .milliseconds(500))
        await reflector.stop()
        #expect(source.watchedFrom.count < 10)
    }

    @MainActor
    @Test func storeRestartRelistsWithFreshReflector() async throws {
        let source = ScriptedSource(listings: [["a": "1"], ["a": "2"]], scripts: [[.hang], [.hang]])
        let store = ResourceStore(source: source, coalesceInterval: .milliseconds(10))
        defer { store.stop() }
        _ = try await WatchCacheIntegrationTests.elapsed { store.items == ["1"] }
        store.restart()
        _ = try await WatchCacheIntegrationTests.elapsed { store.items == ["2"] && store.phase == .live }
        #expect(source.listCount == 2)
    }

    @Test func backoffGrowsAndIsCapped() {
        let backoff = ReconnectBackoff.standard
        #expect(backoff.delay(attempt: 0) <= .seconds(1))
        #expect(backoff.delay(attempt: 0) >= .milliseconds(500))
        #expect(backoff.delay(attempt: 20) <= .seconds(30))
        #expect(backoff.delay(attempt: 20) >= .seconds(15))
    }
}
