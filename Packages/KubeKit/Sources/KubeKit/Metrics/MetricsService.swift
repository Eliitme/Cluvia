import Foundation

public struct ResourceUsage: Sendable, Hashable {
    public let cpuCores: Double
    public let memoryBytes: Double
}

/// Current CPU/memory from the metrics API (metrics-server). Absent on many clusters, so callers check
/// `isAvailable` and treat errors as "no data" rather than failures.
public struct MetricsService: Sendable {
    static let group = "metrics.k8s.io"
    static let pods = GroupVersionResource(group: group, version: "v1beta1", resource: "pods")
    static let nodes = GroupVersionResource(group: group, version: "v1beta1", resource: "nodes")

    public let client: DynamicClient

    public init(client: DynamicClient) {
        self.client = client
    }

    public static func isAvailable(in catalog: APIResourceCatalog) -> Bool {
        catalog.resources.contains { $0.gvr.group == group && $0.gvr.resource == "pods" }
    }

    /// Usage per pod, summed over its containers.
    public func podUsage(namespace: String?) async throws -> [ObjectKey: ResourceUsage] {
        var usage: [ObjectKey: ResourceUsage] = [:]
        for item in try await client.list(Self.pods, namespace: namespace).items {
            let containers = item.json["containers"]?.arrayValue ?? []
            usage[item.key] = Self.sum(containers.compactMap { $0["usage"] })
        }
        return usage
    }

    public func nodeUsage() async throws -> [String: ResourceUsage] {
        var usage: [String: ResourceUsage] = [:]
        for item in try await client.list(Self.nodes).items {
            if let values = item.json["usage"] { usage[item.name] = Self.sum([values]) }
        }
        return usage
    }

    static func sum(_ usages: [JSONValue]) -> ResourceUsage {
        let cpu = usages.compactMap { $0["cpu"]?.stringValue.flatMap(Quantity.parse) }.reduce(0, +)
        let memory = usages.compactMap { $0["memory"]?.stringValue.flatMap(Quantity.parse) }.reduce(0, +)
        return ResourceUsage(cpuCores: cpu, memoryBytes: memory)
    }
}
