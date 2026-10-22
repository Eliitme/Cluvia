import AppKit
import KubeKit

/// Saving what the view shows.
extension LogViewModel {
    /// The visible lines as shown: filtered, formatted and with pod prefixes.
    var visibleText: String {
        LogRenderer.render(buffer.entries, pods: podNames, options: display).text
    }

    func saveToFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(pod)-\(container).log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try visibleText.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
