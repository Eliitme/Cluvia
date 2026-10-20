import Foundation

/// A Prometheus server reached through the API server's service proxy (no port-forward or ingress needed).
public struct PrometheusEndpoint: Sendable, Hashable, CustomStringConvertible {
    public let namespace: String
    public let service: String
    public let port: String

    public init(namespace: String, service: String, port: String) {
        self.namespace = namespace
        self.service = service
        self.port = port
    }

    /// Parses `namespace/service:port`, the format used for the manual override.
    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let servicePort = parts[1].split(separator: ":", maxSplits: 1).map(String.init)
        guard !parts[0].isEmpty, let service = servicePort.first, !service.isEmpty else { return nil }
        self.init(namespace: parts[0], service: service, port: servicePort.count == 2 ? servicePort[1] : "9090")
    }

    public var description: String { "\(namespace)/\(service):\(port)" }

    var proxyPath: String { "/api/v1/namespaces/\(namespace)/services/\(service):\(port)/proxy" }
}

public struct PrometheusError: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

public struct MetricPoint: Sendable, Hashable {
    public let date: Date
    public let value: Double
}

public struct PrometheusClient: Sendable {
    /// Namespaces the common Prometheus distributions install into.
    static let candidateNamespaces = ["monitoring", "prometheus", "kube-prometheus-stack", "observability", "default"]
    static let excludedNames = ["operator", "alertmanager", "node-exporter", "pushgateway", "kube-state", "adapter", "blackbox"]

    public let client: DynamicClient
    public let endpoint: PrometheusEndpoint

    public init(client: DynamicClient, endpoint: PrometheusEndpoint) {
        self.client = client
        self.endpoint = endpoint
    }

    /// Finds a Prometheus server service and confirms it answers queries; nil if none is reachable.
    public static func detect(client: DynamicClient) async -> PrometheusEndpoint? {
        let services = GroupVersionResource(group: "", version: "v1", resource: "services")
        for namespace in candidateNamespaces {
            guard let list = try? await client.list(services, namespace: namespace).items else { continue }
            for service in list where isCandidate(service.name) {
                let ports = (service.json[path: "spec", "ports"]?.arrayValue ?? []).compactMap { $0["port"]?.intValue }
                for port in ports.sorted(by: { ($0 == 9090 ? 0 : 1, $0) < ($1 == 9090 ? 0 : 1, $1) }) {
                    let endpoint = PrometheusEndpoint(namespace: namespace, service: service.name, port: String(port))
                    if (try? await PrometheusClient(client: client, endpoint: endpoint).instant("vector(1)")) != nil { return endpoint }
                }
            }
        }
        return nil
    }

    static func isCandidate(_ name: String) -> Bool {
        name.contains("prometheus") && !excludedNames.contains { name.contains($0) }
    }

    /// One series (summed by the query) over the last `window`.
    public func range(_ query: String, window: Duration = .seconds(3600), step: Duration = .seconds(60), now: Date = Date()) async throws -> [MetricPoint] {
        let start = now.addingTimeInterval(-Double(window.components.seconds))
        let json = try await get("/api/v1/query_range", [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "start", value: String(Int(start.timeIntervalSince1970))),
            URLQueryItem(name: "end", value: String(Int(now.timeIntervalSince1970))),
            URLQueryItem(name: "step", value: String(step.components.seconds)),
        ])
        return Self.points(json)
    }

    func instant(_ query: String) async throws -> JSONValue {
        try await get("/api/v1/query", [URLQueryItem(name: "query", value: query)])
    }

    private func get(_ path: String, _ query: [URLQueryItem]) async throws -> JSONValue {
        let (data, _) = try await client.transport.data(KubeRequest(path: endpoint.proxyPath + path, query: query))
        let json = try JSONValue.parse(data)
        guard json["status"]?.stringValue == "success" else {
            throw PrometheusError(message: json["error"]?.stringValue ?? "Prometheus query failed")
        }
        return json
    }

    /// `[[unixSeconds, "value"], ...]` of the first result series.
    static func points(_ json: JSONValue) -> [MetricPoint] {
        let values = json[path: "data", "result"]?.arrayValue?.first?["values"]?.arrayValue ?? []
        return values.compactMap { pair in
            guard let items = pair.arrayValue, items.count == 2,
                  let time = items[0].intValue.map(Double.init) ?? (items[0] == .null ? nil : Double(items[0].displayText)),
                  let value = items[1].stringValue.flatMap(Double.init), value.isFinite else { return nil }
            return MetricPoint(date: Date(timeIntervalSince1970: time), value: value)
        }
    }
}

/// PromQL for cAdvisor metrics, which every Prometheus setup scraping kubelets has.
public enum MetricQueries {
    public static func podCPU(namespace: String, podRegex: String) -> String {
        #"sum(rate(container_cpu_usage_seconds_total{namespace="\#(namespace)",pod=~"\#(podRegex)",container!=""}[2m]))"#
    }

    public static func podMemory(namespace: String, podRegex: String) -> String {
        #"sum(container_memory_working_set_bytes{namespace="\#(namespace)",pod=~"\#(podRegex)",container!=""})"#
    }

    /// Node label names differ between distributions (`node`, `kubernetes_io_hostname`, `instance`); try each.
    public static func nodeCPU(_ node: String) -> String {
        nodeSelectors(node).map { #"sum(rate(container_cpu_usage_seconds_total{id="/",\#($0)}[2m]))"# }.joined(separator: " or ")
    }

    public static func nodeMemory(_ node: String) -> String {
        nodeSelectors(node).map { #"sum(container_memory_working_set_bytes{id="/",\#($0)})"# }.joined(separator: " or ")
    }

    static func nodeSelectors(_ node: String) -> [String] {
        [#"node="\#(node)""#, #"kubernetes_io_hostname="\#(node)""#, #"instance=~"\#(node)(:[0-9]+)?""#]
    }

    /// Pods belonging to a workload, from the names its controllers generate.
    public static func podRegex(kind: String, name: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        switch kind {
        case "Deployment": return "\(escaped)-[a-z0-9]+-[a-z0-9]+"
        case "StatefulSet": return "\(escaped)-[0-9]+"
        case "DaemonSet", "ReplicaSet", "Job": return "\(escaped)-[a-z0-9]+"
        default: return escaped
        }
    }
}
