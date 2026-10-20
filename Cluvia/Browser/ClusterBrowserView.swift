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
                if session.dock.isVisible {
                    VSplitView {
                        browser.frame(minHeight: 200)
                        DockView(dock: session.dock).frame(minHeight: 140, idealHeight: 280)
                    }
                } else {
                    browser
                }
                Divider()
                StatusBarView(session: session)
            }
        }
        .modifier(ActionSheetsModifier(session: session))
    }

    @ViewBuilder
    private var browser: some View {
        if let kind = session.selectedKind {
            ResourceBrowserView(session: session, kind: kind)
                .id(kind.id)
        } else {
            ContentUnavailableView("Select a Resource", systemImage: "sidebar.left")
        }
    }
}

/// Sheets and alerts for actions, the editor and the command palette.
struct ActionSheetsModifier: ViewModifier {
    @Bindable var session: ClusterSession
    @Environment(ClusterCatalogModel.self) private var catalog
    @Environment(\.openWindow) private var openWindow

    private func runPaletteCommand() {
        guard let command = session.paletteCommand else { return }
        session.paletteCommand = nil
        switch command {
        case let .selectKind(kind): session.selectedKind = kind
        case let .selectNamespace(namespace): session.selectedNamespaces = namespace.map { [$0] } ?? []
        case let .openContext(name):
            catalog.markRequested(name)
            openWindow(value: name)
        case let .reveal(kind, key): session.reveal(kind, key)
        case let .action(action, kind, key): session.request(action, kind: kind, key: key)
        case let .create(kind): session.createResource(of: kind)
        }
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: $session.pendingAction) { pending in
                if pending.action == .scale {
                    ScaleSheetLoader(session: session, pending: pending)
                } else {
                    ConfirmActionSheet(pending: pending, contextName: session.contextName) { policy in
                        await session.perform(pending, propagation: policy)
                    }
                }
            }
            .sheet(item: $session.editModel) { model in
                YamlEditSheet(model: model, contextName: session.contextName)
            }
            // Palette choices run after the palette closes: presenting another sheet while one is dismissing
            // can be dropped by SwiftUI.
            .sheet(isPresented: $session.showPalette, onDismiss: runPaletteCommand) {
                CommandPaletteView(session: session)
            }
            .alert("Action Failed", isPresented: Binding(get: { session.actionError != nil }, set: { if !$0 { session.actionError = nil } })) {
                Button("OK") { session.actionError = nil }
            } message: {
                Text(session.actionError ?? "")
            }
    }
}

private struct ScaleSheetLoader: View {
    let session: ClusterSession
    let pending: PendingAction
    @State private var current: Int?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let current {
                ScaleSheet(pending: pending, contextName: session.contextName, current: current) { await session.scale(pending, to: $0) }
            } else if let error {
                VStack(spacing: 12) {
                    Label("Cannot read current replicas: \(error)", systemImage: "xmark.octagon").foregroundStyle(.red)
                    Button("Close") { dismiss() }
                }
                .padding(30)
            } else {
                ProgressView().padding(40)
            }
        }
        .task {
            do { current = try await session.currentReplicas(pending) } catch { self.error = error.localizedDescription }
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
