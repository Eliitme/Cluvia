import Foundation

/// One listable resource type served by the cluster.
public struct APIResourceInfo: Sendable, Hashable, Identifiable {
    public let gvr: GroupVersionResource
    public let kind: String
    public let namespaced: Bool
    public let verbs: Set<String>
    public let shortNames: [String]
    /// True for the group's preferred version; browsing uses only preferred versions.
    public let preferred: Bool

    public var id: GroupVersionResource { gvr }
    public var isListable: Bool { verbs.contains("list") }
    public var isWatchable: Bool { verbs.contains("watch") }
}

/// Result of API discovery for one cluster.
public struct APIResourceCatalog: Sendable {
    public let resources: [APIResourceInfo]

    public init(resources: [APIResourceInfo]) {
        self.resources = resources
    }

    public var preferred: [APIResourceInfo] { resources.filter(\.preferred) }

    /// Preferred resource for a kind (`Deployment`) optionally constrained to a group.
    public func resource(forKind kind: String, group: String? = nil) -> APIResourceInfo? {
        preferred.first { $0.kind == kind && (group == nil || $0.gvr.group == group) }
            ?? resources.first { $0.kind == kind && (group == nil || $0.gvr.group == group) }
    }

    /// Resolves user input the way `kubectl get` does: plural, singular kind, or short name.
    public func resource(matching name: String) -> APIResourceInfo? {
        let lower = name.lowercased()
        return preferred.first {
            $0.gvr.resource == lower || $0.kind.lowercased() == lower || $0.shortNames.contains(lower)
        }
    }

    public func resource(for gvr: GroupVersionResource) -> APIResourceInfo? {
        resources.first { $0.gvr == gvr }
    }
}
