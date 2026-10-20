import SwiftUI

/// Bottom bar: which cluster this is (its badge color matches the sidebar), whether it is live, and background
/// work that keeps running: port forwards and usage metrics.
struct StatusBarView: View {
    let session: ClusterSession

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                ClusterBadge(name: session.contextName, size: 14)
                Text(session.contextName)
            }
            Label("Live", systemImage: "circle.fill")
                .foregroundStyle(Color.brandTeal)
                .help("Watching the cluster for changes")
            if let version = session.serverVersion { Text(version).foregroundStyle(.secondary) }
            Spacer()
            if !session.portForwards.entries.isEmpty {
                Button { session.dock.showPortForwards() } label: {
                    Label("\(session.portForwards.entries.count) port forward\(session.portForwards.entries.count == 1 ? "" : "s")",
                          systemImage: "arrow.left.arrow.right")
                }
                .buttonStyle(.borderless)
                .help("Show Port Forwards")
            }
            Label(session.metricsAvailable ? "Metrics" : "No metrics", systemImage: "chart.xyaxis.line")
                .foregroundStyle(session.metricsAvailable ? .secondary : .tertiary)
                .help(session.metricsAvailable ? "CPU and memory usage from metrics-server" : "metrics-server is not installed in this cluster")
        }
        .font(.callout)
        .labelStyle(.titleAndIcon)
        .imageScale(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }
}
