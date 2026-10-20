import Foundation

/// Opening, switching between and closing cluster connections in the main window.
extension ClusterCatalogModel {
    var selectedSession: ClusterSession? {
        selectedContext.flatMap { sessions[$0] }
    }

    /// Shows a cluster, connecting on first open. Always a user action, so exec-plugin contexts may run their
    /// plugin (which can open a browser sign-in).
    func open(_ name: String, settings: AppSettingsStore) {
        selectedContext = name
        guard sessions[name] == nil else { return }
        let session = ClusterSession(contextName: name, settings: settings)
        sessions[name] = session
        Task { await connect(session) }
    }

    func connect(_ session: ClusterSession) async {
        // A context opened at launch may be resolved before the first kubeconfig load has finished.
        if contexts.isEmpty { await reload() }
        await session.connect(using: self)
        // Disconnected (or replaced) while connecting: drop what the connection set up so no watch outlives it.
        guard sessions[session.contextName] === session else {
            session.disconnect()
            return
        }
        #if DEBUG
        session.applyLaunchArguments()
        #endif
    }

    /// Stops a cluster's watches, shells and port forwards and forgets its session.
    func disconnect(_ name: String) {
        sessions.removeValue(forKey: name)?.disconnect()
    }
}
