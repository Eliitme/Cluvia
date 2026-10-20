import KubeKit
import SwiftUI

/// A context in the sidebar: connection state, name and whether it is kubectl's current context.
struct ContextRow: View {
    let context: ContextSummary
    @Environment(ClusterCatalogModel.self) private var catalog

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: indicator.symbol).font(.system(size: 8)).foregroundStyle(indicator.color)
            Text(context.name).lineLimit(1)
            if context.isCurrent { Text("current").font(.caption).foregroundStyle(.secondary) }
        }
        .help(tooltip)
    }

    private var indicator: (symbol: String, color: Color) {
        if let session = catalog.sessions[context.name] {
            return switch session.state {
            case .connected: ("circle.fill", .green)
            case .disconnected, .connecting: ("circle.dotted", .orange)
            case .failed: ("circle.fill", .red)
            }
        }
        return switch catalog.health[context.name] ?? .unknown {
        case .unreachable: ("circle", .red)
        default: ("circle", .secondary)
        }
    }

    private var tooltip: String {
        var lines = [context.server ?? "No server", "Namespace: \(context.namespace ?? "default")"]
        switch catalog.health[context.name] ?? .unknown {
        case let .reachable(version, nodes): lines.append("\(version) · \(nodes) node\(nodes == 1 ? "" : "s")")
        case let .unreachable(reason): lines.append("Unreachable: \(reason)")
        case .unknown, .checking: break
        }
        if case let .failed(reason) = catalog.sessions[context.name]?.state { lines.append(reason) }
        return lines.joined(separator: "\n")
    }
}

/// Right-click actions for a context row.
struct ContextRowMenu: View {
    let context: ContextSummary
    @Binding var editing: ContextEditing?
    @Binding var failure: String?
    @Environment(ClusterCatalogModel.self) private var catalog
    @Environment(AppSettingsStore.self) private var settings

    var body: some View {
        if catalog.sessions[context.name] == nil {
            Button("Connect") { catalog.open(context.name, settings: settings) }
        } else {
            Button("Disconnect") { catalog.disconnect(context.name) }
        }
        Button(settings.isFavorite(context.name) ? "Remove from Favorites" : "Add to Favorites") {
            settings.toggleFavorite(context.name)
        }
        Divider()
        Button("Edit…") { editing = .edit(context.name) }
        Button("Set as Current Context") {
            Task {
                do { try await catalog.setCurrentContext(context.name) } catch { failure = error.localizedDescription }
            }
        }
        .disabled(context.isCurrent)
        Button("Show Kubeconfig in Finder") { catalog.revealInFinder(context.name) }
        Divider()
        Button("Delete…", role: .destructive) { editing = .delete(context.name) }
    }
}
