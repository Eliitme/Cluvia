import Foundation
import KubeKit

/// Finds objects by name across all browsable kinds. Names are listed once per kind (metadata only) and
/// reused for 30 seconds, so typing a query filters locally instead of hitting the API server per keystroke.
@MainActor
final class GlobalSearchIndex {
    static let lifetime: Duration = .seconds(30)
    static let maxResults = 40

    private var cache: (built: ContinuousClock.Instant, scopes: [String?], entries: [(ResourceKind, ObjectKey)])?

    func search(_ query: String, session: ClusterSession) async -> [(ResourceKind, ObjectKey)] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard needle.count >= 2, let client = session.client else { return [] }
        let entries = await self.entries(session: session, client: client)
        return Array(entries.lazy.filter { $0.1.name.lowercased().contains(needle) }.prefix(Self.maxResults))
    }

    private func entries(session: ClusterSession, client: DynamicClient) async -> [(ResourceKind, ObjectKey)] {
        let scopes = session.watchNamespaces
        if let cache, cache.scopes == scopes, ContinuousClock.now - cache.built < Self.lifetime { return cache.entries }
        // Events are numerous and short-lived; they are found through their objects instead.
        let kinds = session.kinds.filter { $0.gvr != .events }
        let entries = await withTaskGroup(of: [(ResourceKind, ObjectKey)].self) { group in
            for kind in kinds {
                group.addTask {
                    var keys: [ObjectKey] = []
                    for scope in kind.namespaced ? scopes : [nil] {
                        keys += (try? await client.listKeys(kind.gvr, namespace: scope)) ?? []
                    }
                    return keys.map { (kind, $0) }
                }
            }
            var all: [(ResourceKind, ObjectKey)] = []
            for await batch in group { all += batch }
            return all
        }
        cache = (.now, scopes, entries)
        return entries
    }
}
