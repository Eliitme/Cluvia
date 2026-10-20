import Foundation

public enum ReflectorPhase: Sendable, Equatable {
    /// Initial list in progress.
    case connecting
    /// Listed and watching.
    case live
    /// Watch or list failed; retrying after a backoff. Cached items stay visible meanwhile.
    case reconnecting(reason: String)
    /// The server refuses the collection (unauthorized, forbidden, not found). Retried slowly in case
    /// permissions or CRDs change, but shown as an error rather than a transient outage.
    case failed(reason: String)
}

public struct ReflectorSnapshot<Item: Sendable>: Sendable {
    public let items: [Item]
    public let columns: [TableColumn]
    public let phase: ReflectorPhase
}

/// Jittered exponential backoff between reconnect attempts.
public struct ReconnectBackoff: Sendable {
    public var initial: Duration
    public var maximum: Duration

    public static let standard = ReconnectBackoff(initial: .seconds(1), maximum: .seconds(30))

    public func delay(attempt: Int) -> Duration {
        let base = initial * Int(pow(2, Double(min(attempt, 16))))
        let capped = min(base, maximum)
        return capped * Double.random(in: 0.5...1.0)
    }
}

/// Keeps a local copy of one collection in sync: list, then watch from the listed resource version.
///
/// - Watch ends normally (server timeout): re-watch from the last seen resource version.
/// - 410 Gone: relist and replace everything, so deletions missed while disconnected disappear (no duplicates).
/// - Any other failure: keep the cached items, back off, then resume watching.
/// Snapshots are coalesced so a burst of events becomes one UI update per `coalesceInterval`.
public actor Reflector<Source: ListWatchSource> {
    public nonisolated let updates: AsyncStream<ReflectorSnapshot<Source.Item>>
    private let continuation: AsyncStream<ReflectorSnapshot<Source.Item>>.Continuation
    private let source: Source
    private let coalesceInterval: Duration
    private let backoff: ReconnectBackoff

    private var items: [ObjectKey: Source.Item] = [:]
    private var columns: [TableColumn] = []
    private var phase = ReflectorPhase.connecting
    private var flushScheduled = false
    private var runTask: Task<Void, Never>?
    /// Set by `stop()`; a later `start()` (racing from another task) must not resurrect the watch.
    private var stopped = false

    public init(source: Source, coalesceInterval: Duration = .milliseconds(150), backoff: ReconnectBackoff = .standard) {
        self.source = source
        self.coalesceInterval = coalesceInterval
        self.backoff = backoff
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    public func start() {
        guard runTask == nil, !stopped else { return }
        runTask = Task { await run() }
    }

    public func stop() {
        stopped = true
        runTask?.cancel()
        runTask = nil
        continuation.finish()
    }

    private func run() async {
        var resourceVersion: String?
        var attempt = 0
        let clock = ContinuousClock()
        while !Task.isCancelled {
            do {
                if resourceVersion == nil {
                    let snapshot = try await source.list()
                    items = Dictionary(snapshot.items, uniquingKeysWith: { _, latest in latest })
                    columns = snapshot.columns
                    resourceVersion = snapshot.resourceVersion
                    publish(phase: .live)
                }
                let watchStart = clock.now
                var received = 0
                for try await event in source.watch(from: resourceVersion ?? "") {
                    received += 1
                    attempt = 0
                    if phase != .live { publish(phase: .live) }
                    switch event {
                    case let .upsert(key, item, version):
                        items[key] = item
                        resourceVersion = version ?? resourceVersion
                    case let .delete(key, version):
                        items[key] = nil
                        resourceVersion = version ?? resourceVersion
                    case let .bookmark(version):
                        if !version.isEmpty { resourceVersion = version }
                        continue
                    case .expired:
                        resourceVersion = nil
                    }
                    if resourceVersion == nil { break }
                    scheduleFlush()
                }
                // A watch that closes immediately without events (misbehaving proxy) must not spin.
                if received == 0, clock.now - watchStart < .seconds(1) {
                    try await Task.sleep(for: backoff.delay(attempt: attempt))
                    attempt += 1
                }
            } catch is CancellationError {
                return
            } catch let error as KubeAPIError where error.statusCode == 410 {
                resourceVersion = nil
            } catch {
                if Task.isCancelled { return }
                let permanent = (error as? KubeAPIError).map { [401, 403, 404].contains($0.statusCode) } ?? false
                let reason = error.localizedDescription
                publish(phase: permanent ? .failed(reason: reason) : .reconnecting(reason: reason))
                if permanent { attempt = max(attempt, 16) }
                try? await Task.sleep(for: backoff.delay(attempt: attempt))
                attempt += 1
            }
        }
    }

    private func publish(phase newPhase: ReflectorPhase) {
        phase = newPhase
        flush()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [coalesceInterval] in
            try? await Task.sleep(for: coalesceInterval)
            self.flush()
        }
    }

    private func flush() {
        flushScheduled = false
        let ordered = items.sorted { $0.key < $1.key }.map(\.value)
        continuation.yield(ReflectorSnapshot(items: ordered, columns: columns, phase: phase))
    }
}
