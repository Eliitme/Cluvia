import Foundation
import KubeKit
import Observation

/// Live CPU/memory for pod and node tables, polled while the table is on screen.
@MainActor @Observable
final class LiveUsageModel {
    static let interval: Duration = .seconds(15)

    private(set) var pods: [ObjectKey: ResourceUsage] = [:]
    private(set) var nodes: [String: ResourceUsage] = [:]
    private(set) var version = 0

    static func supports(_ kind: ResourceKind) -> Bool {
        kind.gvr.group.isEmpty && ["Pod", "Node"].contains(kind.kind)
    }

    /// Polls until cancelled. Errors (metrics-server restarting, RBAC) just leave the last values in place.
    func poll(client: DynamicClient, kind: ResourceKind, scopes: [String?]) async {
        let metrics = MetricsService(client: client)
        while !Task.isCancelled {
            if kind.kind == "Node" {
                if let usage = try? await metrics.nodeUsage() { nodes = usage }
            } else {
                var merged: [ObjectKey: ResourceUsage] = [:]
                var succeeded = false
                for scope in scopes {
                    if let usage = try? await metrics.podUsage(namespace: scope) {
                        merged.merge(usage) { _, new in new }
                        succeeded = true
                    }
                }
                if succeeded { pods = merged }
            }
            version += 1
            try? await Task.sleep(for: Self.interval)
        }
    }

    func extras(for kind: ResourceKind) -> TableExtras {
        guard Self.supports(kind) else { return .none }
        let pods = pods, nodes = nodes
        let byNode = kind.kind == "Node"
        let lookup: @Sendable (ResourceTableRow) -> ResourceUsage? = { row in
            byNode ? nodes[row.object.name] : pods[row.id]
        }
        return TableExtras(columns: [.init(id: "cpu", title: "CPU"), .init(id: "memory", title: "Memory")], version: version) { id, row in
            guard let usage = lookup(row) else { return nil }
            return id == "cpu"
                ? (Quantity.formatCPU(usage.cpuCores), usage.cpuCores)
                : (Quantity.formatMemory(usage.memoryBytes), usage.memoryBytes)
        }
    }
}
