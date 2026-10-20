import Foundation
import KubeKit
import Observation

/// Bottom panel of a cluster window: log tabs, shell tabs and the port-forward list.
@MainActor @Observable
final class DockModel {
    enum Content {
        case logs(LogViewModel)
        case terminal(TerminalSessionModel)
        case portForwards
    }

    struct Tab: Identifiable {
        let id: UUID
        let content: Content

        @MainActor var title: String {
            switch content {
            case let .logs(model): model.title
            case let .terminal(model): model.title
            case .portForwards: "Port Forwards"
            }
        }

        var symbol: String {
            switch content {
            case .logs: "text.alignleft"
            case .terminal: "terminal"
            case .portForwards: "arrow.left.arrow.right"
            }
        }
    }

    private(set) var tabs: [Tab] = []
    var selectedTab: Tab.ID?
    var isVisible = false

    func openLogs(client: DynamicClient, pod: Unstructured, container: String? = nil) {
        let existing = tabs.first { tab in
            guard case let .logs(model) = tab.content else { return false }
            return model.pod == pod.name && model.namespace == pod.namespace && (container == nil || model.container == container)
        }
        if let existing { return show(existing.id) }
        let model = LogViewModel(client: client, pod: pod, container: container)
        add(Tab(id: model.id, content: .logs(model)))
    }

    func openShell(transport: KubeTransport, pod: Unstructured, container: String?) {
        let model = TerminalSessionModel(transport: transport, pod: pod, container: container)
        // A clean `exit` closes the tab; failures stay visible with their message.
        let id = model.id
        model.onCleanExit = { [weak self] in self?.close(id) }
        add(Tab(id: model.id, content: .terminal(model)))
    }

    func showPortForwards() {
        if let existing = tabs.first(where: { if case .portForwards = $0.content { true } else { false } }) {
            return show(existing.id)
        }
        add(Tab(id: UUID(), content: .portForwards))
    }

    func close(_ id: Tab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        stop(tabs.remove(at: index))
        if selectedTab == id { selectedTab = tabs.last?.id }
        if tabs.isEmpty { isVisible = false }
    }

    func closeAll() {
        tabs.forEach(stop)
        tabs.removeAll()
        isVisible = false
    }

    private func add(_ tab: Tab) {
        tabs.append(tab)
        show(tab.id)
    }

    private func show(_ id: Tab.ID) {
        selectedTab = id
        isVisible = true
    }

    private func stop(_ tab: Tab) {
        switch tab.content {
        case let .logs(model): model.stop()
        case let .terminal(model): model.stop()
        case .portForwards: break
        }
    }
}
