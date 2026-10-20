import Foundation
import KubeKit

/// Finds objects by name across all browsable kinds. Names are listed once per kind (metadata only) and
/// reused for 30 seconds, so typing a query filters locally instead of hitting the API server per keystroke.
@MainActor
final class GlobalSearchIndex {
    static let lifetime: Duration = .seconds(30)
    static let maxResults = 40

    nonisolated static let maxConcurrentLists = 8

    private var cache: (built: ContinuousClock.Instant, scopes: [String?], entries: [(ResourceKind, ObjectKey)])?
    /// One shared build, not tied to any query: typing cancels the waiting query, never the build.
    private var building: (scopes: [String?], task: Task<[(ResourceKind, ObjectKey)]?, Never>)?

    func search(_ query: String, session: ClusterSession) async -> [(ResourceKind, ObjectKey)] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard needle.count >= 2, let client = session.client else { return [] }
        guard let entries = await entries(session: session, client: client) else { return [] }
        return Array(entries.lazy.filter { $0.1.name.lowercased().contains(needle) }.prefix(Self.maxResults))
    }

    private func entries(session: ClusterSession, client: DynamicClient) async -> [(ResourceKind, ObjectKey)]? {
        let scopes = session.watchNamespaces
        if let cache, cache.scopes == scopes, ContinuousClock.now - cache.built < Self.lifetime { return cache.entries }
        if let building, building.scopes == scopes { return await building.task.value }
        // Events are numerous and short-lived; they are found through their objects instead.
        let jobs = session.kinds.filter { $0.gvr != .events }.flatMap { kind in
            (kind.namespaced ? scopes : [nil]).map { (kind, $0) }
        }
        let task = Task.detached { () -> [(ResourceKind, ObjectKey)]? in
            await withTaskGroup(of: [(ResourceKind, ObjectKey)]?.self) { group in
                var all: [(ResourceKind, ObjectKey)] = []
                var succeeded = 0
                var next = jobs.makeIterator()
                // Bounded parallelism: large clusters have many kinds and namespaces.
                func enqueue() {
                    guard let (kind, scope) = next.next() else { return }
                    group.addTask { (try? await client.listKeys(kind.gvr, namespace: scope))?.map { (kind, $0) } }
                }
                for _ in 0..<Self.maxConcurrentLists { enqueue() }
                for await batch in group {
                    if let batch {
                        all += batch
                        succeeded += 1
                    }
                    enqueue()
                }
                return succeeded == 0 ? nil : all
            }
        }
        building = (scopes, task)
        let result = await task.value
        building = nil
        // Failed builds are not cached, so the next keystroke tries again.
        if let result { cache = (.now, scopes, result) }
        return result
    }
}
