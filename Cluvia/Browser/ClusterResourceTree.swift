import KubeKit
import SwiftUI

/// What the main window's sidebar can select: a cluster, or one of its resource kinds or Helm releases.
enum SidebarItem: Hashable {
    case context(String)
    case kind(String, ResourceKind)
    case helm(String)
}

/// Resource kinds of a connected cluster, nested under its row in the main window's sidebar.
struct ClusterResourceTree: View {
    @Bindable var session: ClusterSession

    var body: some View {
        switch session.state {
        case .disconnected, .connecting:
            Label("Connecting…", systemImage: "hourglass").foregroundStyle(.secondary)
        case .failed:
            Label("Cannot connect", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        case .connected:
            ForEach(ResourceCategory.allCases) { category in
                let kinds = session.kinds.filter { $0.category == category }
                if !kinds.isEmpty {
                    DisclosureGroup(isExpanded: expanded(category)) {
                        ForEach(kinds) { kind in
                            HStack {
                                Text(kind.title).lineLimit(1)
                                Spacer()
                                if let count = session.counts[kind.gvr] {
                                    Text("\(count)").monospacedDigit().foregroundStyle(.secondary).font(.callout)
                                }
                            }
                            .help(kind.category == .customResources ? "\(kind.kind) (\(kind.gvr.groupVersion))" : kind.kind)
                            .tag(SidebarItem.kind(session.contextName, kind))
                        }
                    } label: {
                        Label(category.rawValue, systemImage: category.symbol)
                    }
                }
            }
            Label("Helm Releases", systemImage: "shippingbox.fill").tag(SidebarItem.helm(session.contextName))
                // Counts are a cheap one-item list per kind; refreshed while the cluster is expanded.
                .task(id: session.watchNamespaces) {
                    while !Task.isCancelled {
                        await session.refreshCounts()
                        try? await Task.sleep(for: .seconds(30))
                    }
                }
        }
    }

    private func expanded(_ category: ResourceCategory) -> Binding<Bool> {
        Binding {
            session.expandedCategories.contains(category)
        } set: { open in
            if open { session.expandedCategories.insert(category) } else { session.expandedCategories.remove(category) }
        }
    }
}

struct StatusBarView: View {
    let session: ClusterSession

    var body: some View {
        HStack(spacing: 14) {
            Label(session.contextName, systemImage: "server.rack")
            Label(namespaceText, systemImage: "square.stack.3d.up")
            if let version = session.serverVersion { Text(version).foregroundStyle(.secondary) }
            Spacer()
        }
        .font(.callout)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private var namespaceText: String {
        switch session.selectedNamespaces.count {
        case 0: "All namespaces"
        case 1: session.selectedNamespaces.first!
        default: "\(session.selectedNamespaces.count) namespaces"
        }
    }
}
