import KubeKit
import SwiftUI

/// Connected cluster: resource table, detail inspector, bottom panel and status bar. Its resource kinds are listed
/// in the main window's sidebar.
struct ClusterBrowserView: View {
    @Bindable var session: ClusterSession

    var body: some View {
        VStack(spacing: 0) {
            // One structure whether or not the bottom panel shows: switching between a split and a bare browser
            // rebuilt the browser (table, watches, inspector) on every toggle, which made the window jump and flash.
            VSplitView {
                browser.frame(minHeight: 200, maxHeight: .infinity)
                if session.dock.isVisible {
                    DockView(dock: session.dock, portForwards: session.portForwards).frame(minHeight: 140, idealHeight: 280)
                }
            }
            Divider()
            StatusBarView(session: session)
        }
        .modifier(ActionSheetsModifier(session: session))
        // Sidebar counts are a cheap one-item list per kind, refreshed while the cluster is on screen.
        .task(id: session.watchNamespaces) {
            while !Task.isCancelled {
                await session.refreshCounts()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    @ViewBuilder
    private var browser: some View {
        if session.showingHelm {
            HelmReleasesView(model: session.helm, namespaces: session.selectedNamespaces)
        } else if let kind = session.selectedKind {
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
    @Environment(AppSettingsStore.self) private var settings

    private func runPaletteCommand() {
        guard let command = session.paletteCommand else { return }
        session.paletteCommand = nil
        switch command {
        case let .selectKind(kind): session.selectedKind = kind
        case let .selectNamespace(namespace): session.selectedNamespaces = namespace.map { [$0] } ?? []
        case let .openContext(name): catalog.open(name, settings: settings)
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
                } else if pending.action == .portForward {
                    ForwardPortSheetLoader(session: session, pending: pending)
                } else if pending.action == .drain {
                    DrainSheet(pending: pending, contextName: session.contextName, client: session.client)
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

private struct ForwardPortSheetLoader: View {
    let session: ClusterSession
    let pending: PendingAction
    @State private var ports: [Int]?

    var body: some View {
        Group {
            if let ports {
                ForwardPortSheet(pending: pending, contextName: session.contextName, ports: ports) { remote, local in
                    await session.startForward(pending, remotePort: remote, localPort: local)
                }
            } else {
                ProgressView().padding(40)
            }
        }
        .task { ports = await session.declaredPorts(pending) }
    }
}
