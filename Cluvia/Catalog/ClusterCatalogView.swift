import KubeKit
import SwiftUI

/// Main window: all kubeconfig contexts. Opening one starts a cluster window.
struct ClusterCatalogView: View {
    @Environment(ClusterCatalogModel.self) private var catalog
    @Environment(AppSettingsStore.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @State private var selection: ContextSummary.ID?
    @State private var search = ""

    private var rows: [ContextSummary] {
        let filtered = search.isEmpty ? catalog.contexts : catalog.contexts.filter {
            $0.name.localizedCaseInsensitiveContains(search) || ($0.server ?? "").localizedCaseInsensitiveContains(search)
        }
        // Favorites first, then alphabetical.
        return filtered.sorted { lhs, rhs in
            let (l, r) = (settings.isFavorite(lhs.name), settings.isFavorite(rhs.name))
            return l != r ? l : lhs.name < rhs.name
        }
    }

    var body: some View {
        Table(rows, selection: $selection) {
            TableColumn("") { context in
                Button { settings.toggleFavorite(context.name) } label: {
                    Image(systemName: settings.isFavorite(context.name) ? "star.fill" : "star")
                        .foregroundStyle(settings.isFavorite(context.name) ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .help("Favorite")
            }
            .width(24)
            TableColumn("Context") { context in
                HStack {
                    Text(context.name).fontWeight(context.isCurrent ? .semibold : .regular)
                    if context.isCurrent { Text("current").font(.caption).foregroundStyle(.secondary) }
                }
            }
            TableColumn("Server") { Text($0.server ?? "—").foregroundStyle(.secondary).lineLimit(1) }
            TableColumn("Namespace") { Text($0.namespace ?? "default").foregroundStyle(.secondary) }
            TableColumn("Status") { ClusterHealthView(name: $0.name) }
                .width(min: 160, ideal: 220)
        }
        .contextMenu(forSelectionType: ContextSummary.ID.self) { ids in
            if let name = ids.first {
                Button("Open") { open(name) }
                Button("Check Connection") { Task { await catalog.check(name) } }
            }
        } primaryAction: { ids in
            ids.forEach(open)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Filter contexts")
        .overlay {
            if catalog.contexts.isEmpty, !catalog.isLoading {
                ContentUnavailableView {
                    Label {
                        Text("No Kubernetes Contexts")
                    } icon: {
                        Image("BrandMark").resizable().scaledToFit().frame(width: 72)
                    }
                } description: {
                    Text(catalog.loadErrors.first ?? "No contexts found in ~/.kube/config or KUBECONFIG.")
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { Task { await reload() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r")
            }
        }
        .navigationTitle("Clusters")
        .task { await reload() }
    }

    private func open(_ name: String) {
        catalog.markRequested(name)
        openWindow(value: name)
    }

    private func reload() async {
        await catalog.reload()
        await catalog.checkAutomatically()
    }
}

struct ClusterHealthView: View {
    @Environment(ClusterCatalogModel.self) private var catalog
    let name: String

    var body: some View {
        switch catalog.health[name] ?? .unknown {
        case .unknown:
            Button("Check") { Task { await catalog.check(name) } }
                .controlSize(.small)
        case .checking:
            ProgressView().controlSize(.small)
        case let .reachable(version, nodes):
            Label("\(version) · \(nodes) node\(nodes == 1 ? "" : "s")", systemImage: "circle.fill")
                .labelStyle(StatusLabelStyle(color: .green))
        case let .unreachable(reason):
            Label("Unreachable", systemImage: "circle.fill")
                .labelStyle(StatusLabelStyle(color: .red))
                .help(reason)
        }
    }
}

struct StatusLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 7)).foregroundStyle(color)
            configuration.title
        }
    }
}
