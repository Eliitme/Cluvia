import Foundation

/// Discovers every resource type on a cluster (built-ins, aggregated APIs, CRDs).
///
/// Uses aggregated discovery (`apidiscovery.k8s.io/v2`, two requests total) and falls back to the legacy
/// per-group-version walk for servers that predate it. Results are cached until `refresh()`.
public actor APIDiscovery {
    /// v2 is GA since 1.30; v2beta1 covers 1.26-1.29.
    static let aggregatedAccept = "application/json;g=apidiscovery.k8s.io;v=v2;as=APIGroupDiscoveryList,"
        + "application/json;g=apidiscovery.k8s.io;v=v2beta1;as=APIGroupDiscoveryList,application/json"

    private let transport: KubeTransport
    private var cached: APIResourceCatalog?

    public init(transport: KubeTransport) {
        self.transport = transport
    }

    public func catalog() async throws -> APIResourceCatalog {
        if let cached { return cached }
        return try await refresh()
    }

    @discardableResult
    public func refresh() async throws -> APIResourceCatalog {
        let catalog = try await Self.discover(transport: transport, allowAggregated: true)
        cached = catalog
        return catalog
    }

    static func discover(transport: KubeTransport, allowAggregated: Bool) async throws -> APIResourceCatalog {
        if allowAggregated {
            let core = try await json(transport, "/api", accept: aggregatedAccept)
            let groups = try await json(transport, "/apis", accept: aggregatedAccept)
            if core["kind"]?.stringValue == "APIGroupDiscoveryList", groups["kind"]?.stringValue == "APIGroupDiscoveryList" {
                return APIResourceCatalog(resources: DiscoveryDecoding.aggregated(core) + DiscoveryDecoding.aggregated(groups))
            }
        }
        return try await legacy(transport: transport)
    }

    private static func legacy(transport: KubeTransport) async throws -> APIResourceCatalog {
        var groupVersions: [(group: String, version: String, preferred: Bool)] = []
        for version in try await json(transport, "/api")["versions"]?.arrayValue ?? [] {
            if let version = version.stringValue { groupVersions.append(("", version, true)) }
        }
        for group in try await json(transport, "/apis")["groups"]?.arrayValue ?? [] {
            guard let name = group["name"]?.stringValue else { continue }
            let preferred = group[path: "preferredVersion", "version"]?.stringValue
            for version in group["versions"]?.arrayValue ?? [] {
                guard let version = version["version"]?.stringValue else { continue }
                groupVersions.append((name, version, version == preferred))
            }
        }
        // One request per group-version; done concurrently because large clusters have hundreds.
        return try await withThrowingTaskGroup(of: (Int, [APIResourceInfo]).self) { group in
            for (index, entry) in groupVersions.enumerated() {
                group.addTask {
                    let path = entry.group.isEmpty ? "/api/\(entry.version)" : "/apis/\(entry.group)/\(entry.version)"
                    // Aggregated API servers can be down; their resources are skipped rather than failing discovery.
                    guard let list = try? await json(transport, path) else { return (index, []) }
                    return (index, DiscoveryDecoding.legacy(list, group: entry.group, version: entry.version, preferred: entry.preferred))
                }
            }
            var batches: [(Int, [APIResourceInfo])] = []
            for try await batch in group { batches.append(batch) }
            // Server order (core first) keeps lookups like "events" deterministic.
            return APIResourceCatalog(resources: batches.sorted { $0.0 < $1.0 }.flatMap(\.1))
        }
    }

    private static func json(_ transport: KubeTransport, _ path: String, accept: String = "application/json") async throws -> JSONValue {
        let (data, _) = try await transport.data(KubeRequest(path: path, accept: accept))
        return try JSONValue.parse(data)
    }
}
