import KubeKit
import SwiftUI

enum SidebarItem: Hashable {
    case kind(ResourceKind)
    case helm
}

struct ClusterSidebarView: View {
    @Bindable var session: ClusterSession

    private var selection: Binding<SidebarItem?> {
        Binding {
            session.showingHelm ? .helm : session.selectedKind.map(SidebarItem.kind)
        } set: { item in
            switch item {
            case .helm: session.showingHelm = true
            case let .kind(kind): session.selectedKind = kind
            case nil: break
            }
        }
    }

    var body: some View {
        List(selection: selection) {
            ForEach(ResourceCategory.allCases) { category in
                let kinds = session.kinds.filter { $0.category == category }
                if !kinds.isEmpty {
                    Section {
                        ForEach(kinds) { kind in
                            HStack {
                                Text(kind.title).lineLimit(1)
                                Spacer()
                                if let count = session.counts[kind.gvr] {
                                    Text("\(count)").monospacedDigit().foregroundStyle(.secondary).font(.callout)
                                }
                            }
                            .help(kind.category == .customResources ? "\(kind.kind) (\(kind.gvr.groupVersion))" : kind.kind)
                            .tag(SidebarItem.kind(kind))
                        }
                    } header: {
                        Label(category.rawValue, systemImage: category.symbol)
                    }
                }
            }
            Section {
                Label("Releases", systemImage: "shippingbox.fill").tag(SidebarItem.helm)
            } header: {
                Label("Helm", systemImage: "helm")
            }
        }
        .listStyle(.sidebar)
        // Counts are a cheap one-item list per kind; refreshed while the window is open.
        .task(id: session.watchNamespaces) {
            while !Task.isCancelled {
                await session.refreshCounts()
                try? await Task.sleep(for: .seconds(30))
            }
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
