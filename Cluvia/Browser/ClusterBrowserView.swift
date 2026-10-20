import KubeKit
import SwiftUI

/// Connected cluster: category sidebar, resource table, detail inspector and status bar.
struct ClusterBrowserView: View {
    @Bindable var session: ClusterSession

    var body: some View {
        NavigationSplitView {
            ClusterSidebarView(session: session)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if let kind = session.selectedKind {
                    ResourceBrowserView(session: session, kind: kind)
                        .id(kind.id)
                } else {
                    ContentUnavailableView("Select a Resource", systemImage: "sidebar.left")
                }
                Divider()
                StatusBarView(session: session)
            }
        }
    }
}

struct ClusterSidebarView: View {
    @Bindable var session: ClusterSession

    var body: some View {
        List(selection: $session.selectedKind) {
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
                            .tag(kind)
                        }
                    } header: {
                        Label(category.rawValue, systemImage: category.symbol)
                    }
                }
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
