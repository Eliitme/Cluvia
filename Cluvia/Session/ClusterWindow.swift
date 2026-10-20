import KubeKit
import SwiftUI

/// Root of a cluster window: owns the session for its context and tears its watches down on close.
struct ClusterWindow: View {
    let contextName: String
    @Environment(ClusterCatalogModel.self) private var catalog
    @Environment(AppSettingsStore.self) private var settings
    @State private var session: ClusterSession?

    var body: some View {
        Group {
            if let session {
                switch session.state {
                case .disconnected where !catalog.usesExecPlugin(contextName):
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .disconnected:
                    ContentUnavailableView {
                        Label("Not Connected", systemImage: "bolt.horizontal.circle")
                    } description: {
                        Text("This context authenticates with a credential plugin, which may open a browser to sign in.")
                    } actions: {
                        Button("Connect") { Task { await connect(session) } }
                    }
                case .connecting:
                    ProgressView("Connecting to \(contextName)…").frame(maxWidth: .infinity, maxHeight: .infinity)
                case let .failed(reason):
                    ContentUnavailableView {
                        Label("Cannot Connect", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(reason).textSelection(.enabled)
                    } actions: {
                        Button("Retry") { Task { await connect(session) } }
                    }
                case .connected:
                    ClusterBrowserView(session: session)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(contextName)
        .focusedSceneValue(\.clusterSession, session)
        .frame(minWidth: 900, minHeight: 500)
        // Runs on every appearance, so a window that was hidden (and disconnected) reconnects when shown again.
        .task {
            let session = session ?? ClusterSession(contextName: contextName, settings: settings)
            self.session = session
            guard session.registry == nil else { return }
            if catalog.contexts.isEmpty { await catalog.reload() }
            if catalog.usesExecPlugin(contextName), !catalog.requestedContexts.contains(contextName) { return }
            await connect(session)
        }
        .onDisappear { session?.disconnect() }
    }

    private func connect(_ session: ClusterSession) async {
        catalog.markRequested(contextName)
        await session.connect(using: catalog)
        applyLaunchArguments(to: session)
    }

    /// Debug-only deep link used by automated UI checks: `-CluviaNamespace ns -CluviaKind pods -CluviaObject name -CluviaAction logs`.
    private func applyLaunchArguments(to session: ClusterSession) {
        #if DEBUG
        let defaults = UserDefaults.standard
        if let namespaces = defaults.string(forKey: "CluviaNamespace") {
            session.selectedNamespaces = Set(namespaces.split(separator: ",").map(String.init))
        }
        if let resource = defaults.string(forKey: "CluviaKind"), let kind = session.kinds.first(where: { $0.gvr.resource == resource }) {
            session.selectedKind = kind
        }
        if let name = defaults.string(forKey: "CluviaObject") {
            session.selectedObject = ObjectKey(namespace: session.selectedNamespaces.first, name: name)
        }
        if let value = defaults.string(forKey: "CluviaAction") {
            if value == "palette" {
                session.showPalette = true
            } else if let action = ResourceAction(rawValue: value), let kind = session.selectedKind, let key = session.selectedObject {
                session.request(action, kind: kind, key: key)
            }
        }
        #endif
    }
}

struct ClusterSessionKey: FocusedValueKey {
    typealias Value = ClusterSession
}

extension FocusedValues {
    var clusterSession: ClusterSession? {
        get { self[ClusterSessionKey.self] }
        set { self[ClusterSessionKey.self] = newValue }
    }
}
