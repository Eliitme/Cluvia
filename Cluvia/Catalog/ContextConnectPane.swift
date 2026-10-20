import KubeKit
import SwiftUI

/// Detail area for a selected cluster that is not connected yet: what it points at, and a Connect button.
struct ContextConnectPane: View {
    let context: ContextSummary
    @Environment(ClusterCatalogModel.self) private var catalog
    @Environment(AppSettingsStore.self) private var settings

    var body: some View {
        ContentUnavailableView {
            Label(context.name, systemImage: "server.rack")
        } description: {
            VStack(spacing: 4) {
                Text(context.server ?? "No server")
                Text("Namespace: \(context.namespace ?? "default")")
                if case let .reachable(version, nodes) = catalog.health[context.name] {
                    Text("\(version) · \(nodes) node\(nodes == 1 ? "" : "s")")
                } else if case let .unreachable(reason) = catalog.health[context.name] {
                    Text("Unreachable: \(reason)").foregroundStyle(.red)
                }
                if catalog.usesExecPlugin(context.name) {
                    Text("Signs in with a credential plugin, which may open a browser.").font(.caption)
                }
            }
            .textSelection(.enabled)
        } actions: {
            Button("Connect") { catalog.open(context.name, settings: settings) }
                .keyboardShortcut(.defaultAction)
        }
        .navigationTitle(context.name)
    }
}
