import KubeKit
import SwiftUI

/// Detail area for a selected cluster that is not connected yet: what it points at, how it signs in, and Connect.
struct ContextConnectPane: View {
    let context: ContextSummary
    @Environment(ClusterCatalogModel.self) private var catalog
    @Environment(AppSettingsStore.self) private var settings

    var body: some View {
        VStack(spacing: 18) {
            ClusterBadge(name: context.name, size: 56)
            VStack(spacing: 4) {
                Text(context.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                health
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Server", context.server ?? "—")
                row("Namespace", context.namespace ?? "default")
                row("Signs in with", signIn)
                if let file = catalog.file(for: context.name) { row("Defined in", WorkspaceSidebarView.displayPath(file)) }
            }
            .font(.callout)
            .frame(maxWidth: 460)
            VStack(spacing: 10) {
                Button { catalog.open(context.name, settings: settings) } label: {
                    Text("Connect").frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                Toggle("Connect automatically when Cluvia opens", isOn: Binding(
                    get: { settings.connectsAutomatically(context.name) },
                    set: { settings.setConnectsAutomatically($0, for: context.name) }
                ))
                .toggleStyle(.checkbox)
                .font(.callout)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(context.name)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var health: some View {
        switch catalog.health[context.name] ?? .unknown {
        case let .reachable(version, nodes):
            Label("Reachable · \(version) · \(nodes) node\(nodes == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.brandTeal)
        case let .unreachable(reason):
            Label("Unreachable: \(reason)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .checking:
            Text("Checking…").foregroundStyle(.secondary)
        case .unknown:
            EmptyView()
        }
    }

    private var signIn: String {
        guard let user = try? catalog.resolve(context.name).user else { return "—" }
        if let exec = user.exec {
            return "Credential plugin (\((exec.command as NSString).lastPathComponent)), may open a browser"
        }
        if user.clientCertificate != nil || user.clientCertificateData != nil { return "Client certificate" }
        if user.token != nil || user.tokenFile != nil { return "Bearer token" }
        if let provider = user.authProvider { return "Auth provider \(provider.name) (not supported)" }
        return "No credentials"
    }
}
