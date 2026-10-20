import Foundation

public enum PortForwardError: Error, LocalizedError, Sendable {
    case servicePortNotFound(service: String, port: Int)
    case noReadyEndpoints(service: String)
    case remote(String)

    public var errorDescription: String? {
        switch self {
        case let .servicePortNotFound(service, port): "Service \(service) has no port \(port)"
        case let .noReadyEndpoints(service): "Service \(service) has no ready pods"
        case let .remote(message): message
        }
    }
}

/// Picks a ready pod and container port behind a service port, the same way the service itself routes:
/// via the service's EndpointSlices, so named target ports resolve to each pod's actual port number.
enum ServiceTargetResolver {
    static let endpointSlices = GroupVersionResource(group: "discovery.k8s.io", version: "v1", resource: "endpointslices")
    static let services = GroupVersionResource(group: "", version: "v1", resource: "services")

    static func resolve(client: DynamicClient, namespace: String, service: String, port: Int) async throws -> (pod: String, port: Int) {
        let object = try await client.get(services, name: service, namespace: namespace)
        let ports = object.json[path: "spec", "ports"]?.arrayValue ?? []
        guard let servicePort = ports.first(where: { $0["port"]?.intValue == Int64(port) }) else {
            throw PortForwardError.servicePortNotFound(service: service, port: port)
        }
        let slices = try await client.list(
            endpointSlices, namespace: namespace, options: ListOptions(labelSelector: "kubernetes.io/service-name=\(service)")
        ).items
        guard let target = pick(portName: servicePort["name"]?.stringValue, slices: slices) else {
            throw PortForwardError.noReadyEndpoints(service: service)
        }
        return target
    }

    /// First ready pod endpoint and its port number for the service port named `portName`.
    static func pick(portName: String?, slices: [Unstructured]) -> (pod: String, port: Int)? {
        for slice in slices {
            let slicePorts = slice.json["ports"]?.arrayValue ?? []
            // Unnamed service ports appear as a single unnamed slice port.
            guard let match = slicePorts.first(where: { $0["name"]?.stringValue == portName }) ?? (slicePorts.count == 1 ? slicePorts.first : nil),
                  let targetPort = match["port"]?.intValue else { continue }
            for endpoint in slice.json["endpoints"]?.arrayValue ?? [] {
                guard endpoint[path: "conditions", "ready"] != .bool(false),
                      endpoint[path: "targetRef", "kind"]?.stringValue == "Pod",
                      let pod = endpoint[path: "targetRef", "name"]?.stringValue else { continue }
                return (pod, Int(targetPort))
            }
        }
        return nil
    }
}
