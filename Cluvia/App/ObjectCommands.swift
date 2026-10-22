import SwiftUI

/// Object menu: actions for the object selected in the focused cluster, with their keyboard shortcuts.
struct ObjectCommands: Commands {
    @FocusedValue(\.clusterSession) private var session

    var body: some Commands {
        CommandMenu("Object") {
            let kind = session?.selectedKind
            // Only an object the user can see, and never under an open sheet (it would replace the sheet's work).
            let usable = session.map { $0.selectionVisible && !$0.showingHelm && $0.pendingAction == nil && $0.editModel == nil && !$0.showPalette } ?? false
            let key = usable ? session?.selectedObject : nil
            let available = kind.map(ResourceAction.available(for:)) ?? []
            ForEach(ResourceAction.allCases) { action in
                if available.contains(action) || available.isEmpty {
                    Button(kind.map(action.title(for:)) ?? action.title) {
                        if let session, let kind, let key { session.request(action, kind: kind, key: key) }
                    }
                    .keyboardShortcut(action.shortcut)
                    .disabled(key == nil || !available.contains(action))
                }
            }
        }
    }
}
