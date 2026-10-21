/// How a picked action reaches the code that runs it. Sheet routing, `perform` and the tests switch over every case
/// without a `default`, so a new action cannot fall through to a confirmation that silently does nothing.
extension ResourceAction {
    enum Route: Equatable {
        /// Runs straight from `ClusterSession.request` (opens a tab or the editor).
        case immediate
        /// Has its own sheet.
        case sheet
        /// Generic confirmation, then `ClusterSession.perform`.
        case confirm
    }

    var route: Route {
        switch self {
        case .logs, .shell, .edit: .immediate
        case .portForward, .scale, .drain, .delete: .sheet
        case .restart, .cordon, .uncordon, .nodeShell: .confirm
        }
    }
}
