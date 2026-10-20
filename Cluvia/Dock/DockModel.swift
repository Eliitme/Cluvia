import KubeKit
import Observation

/// Bottom panel of a cluster window holding log tabs (and later terminals).
@MainActor @Observable
final class DockModel {
    private(set) var logTabs: [LogViewModel] = []
    var selectedTab: LogViewModel.ID?
    var isVisible = false

    func openLogs(client: DynamicClient, pod: Unstructured, container: String? = nil) {
        if let existing = logTabs.first(where: { $0.pod == pod.name && $0.namespace == pod.namespace && (container == nil || $0.container == container) }) {
            selectedTab = existing.id
        } else {
            let tab = LogViewModel(client: client, pod: pod, container: container)
            logTabs.append(tab)
            selectedTab = tab.id
        }
        isVisible = true
    }

    func close(_ id: LogViewModel.ID) {
        guard let index = logTabs.firstIndex(where: { $0.id == id }) else { return }
        logTabs[index].stop()
        logTabs.remove(at: index)
        if selectedTab == id { selectedTab = logTabs.last?.id }
        if logTabs.isEmpty { isVisible = false }
    }

    func closeAll() {
        logTabs.forEach { $0.stop() }
        logTabs.removeAll()
        isVisible = false
    }
}
