import Foundation

/// Addresses one resource collection on the API server, e.g. `apps/v1 deployments`.
public struct GroupVersionResource: Sendable, Hashable, CustomStringConvertible {
    /// Empty for the core group (`/api/v1`).
    public let group: String
    public let version: String
    public let resource: String

    public init(group: String, version: String, resource: String) {
        self.group = group
        self.version = version
        self.resource = resource
    }

    public var groupVersion: String { group.isEmpty ? version : "\(group)/\(version)" }
    public var description: String { "\(resource).\(groupVersion)" }

    /// `/api/v1[/namespaces/{ns}]/{resource}[/{name}[/{subresource}]]`
    public func path(namespace: String? = nil, name: String? = nil, subresource: String? = nil) -> String {
        var path = group.isEmpty ? "/api/\(version)" : "/apis/\(group)/\(version)"
        if let namespace, !namespace.isEmpty { path += "/namespaces/\(namespace)" }
        path += "/\(resource)"
        if let name {
            path += "/\(name)"
            if let subresource { path += "/\(subresource)" }
        }
        return path
    }

    public static let pods = GroupVersionResource(group: "", version: "v1", resource: "pods")
    public static let namespaces = GroupVersionResource(group: "", version: "v1", resource: "namespaces")
    public static let events = GroupVersionResource(group: "", version: "v1", resource: "events")
    public static let customResourceDefinitions = GroupVersionResource(
        group: "apiextensions.k8s.io", version: "v1", resource: "customresourcedefinitions"
    )
}
