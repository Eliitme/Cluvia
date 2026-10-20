import Charts
import KubeKit
import SwiftUI

/// CPU and memory over the last hour from Prometheus, for pods, nodes and workloads.
struct MetricsChartsSection: View {
    let session: ClusterSession
    let object: Unstructured
    @State private var cpu: [MetricPoint] = []
    @State private var memory: [MetricPoint] = []
    @State private var error: String?
    @State private var editing = false
    @State private var override = ""

    static let supportedKinds: Set<String> = ["Pod", "Node", "Deployment", "StatefulSet", "DaemonSet"]

    private var queries: (cpu: String, memory: String)? {
        let namespace = object.namespace ?? ""
        switch object.kind {
        case "Node": return (MetricQueries.nodeCPU(object.name), MetricQueries.nodeMemory(object.name))
        case "Pod":
            let regex = NSRegularExpression.escapedPattern(for: object.name)
            return (MetricQueries.podCPU(namespace: namespace, podRegex: regex), MetricQueries.podMemory(namespace: namespace, podRegex: regex))
        case let kind?:
            let regex = MetricQueries.podRegex(kind: kind, name: object.name)
            return (MetricQueries.podCPU(namespace: namespace, podRegex: regex), MetricQueries.podMemory(namespace: namespace, podRegex: regex))
        case nil: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Usage (last hour)").font(.headline)
                Spacer()
                // The data source matters only when it is wrong; a quiet button keeps it out of the way.
                Button { override = session.prometheus.endpoint?.description ?? ""; editing = true } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Prometheus: \(sourceLabel)")
                .accessibilityLabel("Prometheus Source")
            }
            switch session.prometheus.state {
            case .unknown, .detecting:
                ProgressView().controlSize(.small)
            case .unavailable:
                Text("No Prometheus found. Set one with the link above.").foregroundStyle(.secondary).font(.callout)
            case .available:
                if let error { Text(error).foregroundStyle(.secondary).font(.callout) }
                // Empty series are left out rather than drawn as blank frames.
                if !cpu.isEmpty { chart("CPU", points: cpu) { Quantity.formatCPU($0) } }
                if !memory.isEmpty { chart("Memory", points: memory) { Quantity.formatMemory($0) } }
            }
        }
        .task(id: "\(object.uid ?? "")|\(session.prometheus.endpoint?.description ?? "")") { await load() }
        .alert("Prometheus", isPresented: $editing) {
            TextField("namespace/service:port", text: $override)
            Button("Save") {
                guard let client = session.client else { return }
                Task { await session.prometheus.setOverride(override, client: client) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave empty to detect automatically.")
        }
    }

    private var sourceLabel: String {
        if case let .available(endpoint, manual) = session.prometheus.state { return "\(endpoint)\(manual ? "" : " (detected)")" }
        return "Configure…"
    }

    private func chart(_ title: String, points: [MetricPoint], format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title)\(points.last.map { " · \(format($0.value))" } ?? "")").font(.caption).foregroundStyle(.secondary)
            Chart(points, id: \.date) { LineMark(x: .value("Time", $0.date), y: .value(title, $0.value)) }
                // Few marks: tiny values would otherwise repeat the same rounded label ("0m 0m 0m").
                .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { value in AxisValueLabel { Text(value.as(Double.self).map(format) ?? "") } } }
                .frame(height: 72)
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        await session.prometheus.resolve(client: client)
        guard let endpoint = session.prometheus.endpoint, let queries else { return }
        let prometheus = PrometheusClient(client: client, endpoint: endpoint)
        do {
            async let cpuPoints = prometheus.range(queries.cpu)
            async let memoryPoints = prometheus.range(queries.memory)
            (cpu, memory) = try await (cpuPoints, memoryPoints)
            error = cpu.isEmpty && memory.isEmpty ? "No data for this object yet." : nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
