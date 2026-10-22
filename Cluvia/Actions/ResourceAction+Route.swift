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
        case .portForward, .scale, .drain, .delete, .rolloutHistory: .sheet
        case .restart, .pause, .resume, .trigger, .cordon, .uncordon, .nodeShell: .confirm
        }
    }
}

extension ResourceAction {
    /// Title naming what the action does to this kind, where the kind is known (menus, palette, confirmations).
    func title(for kind: ResourceKind) -> String {
        switch (self, kind.kind) {
        case (.pause, "Deployment"): "Pause Rollout"
        case (.resume, "Deployment"): "Resume Rollout"
        case (.pause, "CronJob"): "Suspend"
        case (.resume, "CronJob"): "Resume Schedule"
        default: title
        }
    }
}
