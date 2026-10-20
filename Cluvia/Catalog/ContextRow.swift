import KubeKit
import SwiftUI

/// A context in the sidebar: its badge with connection state, name, kubectl's current marker, and on hover a menu
/// with the same actions as right-click.
struct ContextRow: View {
    let context: ContextSummary
    let expanded: Bool
    @Binding var editing: ContextEditing?
    @Binding var failure: String?
    let onToggle: () -> Void
    @Environment(ClusterCatalogModel.self) private var catalog
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Button(action: onToggle) { Chevron(open: expanded) }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Collapse \(context.name)" : "Expand \(context.name)")
            ClusterBadge(name: context.name)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(indicator.color)
                        .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                        .frame(width: 8, height: 8)
                        .offset(x: 3, y: 3)
                        .opacity(indicator.visible ? 1 : 0)
                }
            Text(context.name).lineLimit(1).truncationMode(.middle)
            if context.isCurrent {
                Text("current").font(.caption2).foregroundStyle(.secondary)
                    .help("kubectl's current context")
            }
            Spacer(minLength: 0)
            if hovering {
                Menu {
                    ContextRowMenu(context: context, editing: $editing, failure: $failure)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Actions for \(context.name)")
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(tooltip)
    }

    /// Connected (teal), connecting (orange), failed or unreachable (red); idle clusters show no dot.
    private var indicator: (color: Color, visible: Bool) {
        if let session = catalog.sessions[context.name] {
            return switch session.state {
            case .connected: (.brandTeal, true)
            case .disconnected, .connecting: (.orange, true)
            case .failed: (.red, true)
            }
        }
        if case .unreachable = catalog.health[context.name] { return (.red, true) }
        return (.clear, false)
    }

    private var tooltip: String {
        var lines = [context.server ?? "No server", "Namespace: \(context.namespace ?? "default")"]
        if let session = catalog.sessions[context.name] {
            switch session.state {
            case .connected: lines.append("Connected")
            case .disconnected, .connecting: lines.append("Connecting…")
            case let .failed(reason): lines.append("Cannot connect: \(reason)")
            }
        } else {
            switch catalog.health[context.name] ?? .unknown {
            case let .reachable(version, nodes): lines.append("Reachable · \(version) · \(nodes) node\(nodes == 1 ? "" : "s")")
            case let .unreachable(reason): lines.append("Unreachable: \(reason)")
            case .unknown, .checking: break
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Actions for a context row, shared by right-click and the hover menu.
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
        Toggle("Connect Automatically", isOn: Binding(
            get: { settings.connectsAutomatically(context.name) },
            set: { settings.setConnectsAutomatically($0, for: context.name) }
        ))
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
