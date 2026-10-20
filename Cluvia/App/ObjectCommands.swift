import SwiftUI

/// Object menu: actions for the object selected in the focused cluster, with their keyboard shortcuts.
struct ObjectCommands: Commands {
    @FocusedValue(\.clusterSession) private var session

    var body: some Commands {
        CommandMenu("Object") {
            let kind = session?.selectedKind
            let key = session?.selectedObject
            let available = kind.map(ResourceAction.available(for:)) ?? []
            ForEach(ResourceAction.allCases) { action in
                if available.contains(action) || available.isEmpty {
                    Button(action.title) {
                        if let session, let kind, let key { session.request(action, kind: kind, key: key) }
                    }
                    .keyboardShortcut(action.shortcut)
                    .disabled(key == nil || !available.contains(action))
                }
            }
        }
    }
}
