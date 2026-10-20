import SwiftUI

extension ResourceAction {
    /// Shortcuts for the selected object, listed in the Object menu.
    var shortcut: KeyboardShortcut? {
        switch self {
        case .logs: KeyboardShortcut("l", modifiers: [.command, .option])
        case .shell: KeyboardShortcut("t", modifiers: [.command, .control])
        case .portForward: KeyboardShortcut("p", modifiers: [.command, .option])
        case .edit: KeyboardShortcut("e", modifiers: [.command, .option])
        case .scale: KeyboardShortcut("s", modifiers: [.command, .option])
        case .restart: KeyboardShortcut("r", modifiers: [.command, .option])
        // Not ⌘⌫: in text fields that deletes to the start of the line.
        case .delete: KeyboardShortcut(.delete, modifiers: [.command, .option])
        case .cordon, .uncordon, .drain, .nodeShell: nil
        }
    }

    /// Button title where space is tight; menus use the full `title`.
    var shortTitle: String {
        switch self {
        case .portForward: "Forward"
        case .edit: "Edit"
        case .nodeShell: "Shell"
        default: title.replacingOccurrences(of: "…", with: "")
        }
    }

    /// Tooltip text naming the shortcut, e.g. "Logs (⌥⌘L)".
    var helpText: String {
        guard let shortcut else { return title }
        var keys = ""
        if shortcut.modifiers.contains(.control) { keys += "⌃" }
        if shortcut.modifiers.contains(.option) { keys += "⌥" }
        if shortcut.modifiers.contains(.shift) { keys += "⇧" }
        if shortcut.modifiers.contains(.command) { keys += "⌘" }
        keys += shortcut.key == .delete ? "⌫" : String(shortcut.key.character).uppercased()
        return "\(title) (\(keys))"
    }
}
