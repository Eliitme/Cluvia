import AppKit
import KubeKit

/// Text rendering and saving of the buffered lines.
extension LogViewModel {
    func format(_ line: LogLine) -> String {
        showTimestamps ? "\(line.timestamp ?? "") \(line.text)" : line.text
    }

    func text(from start: Int) -> String? {
        buffer.lines(from: start).map { $0.map(format).joined(separator: "\n") }
    }

    func saveToFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(pod)-\(container).log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = buffer.lines.map(format).joined(separator: "\n")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
