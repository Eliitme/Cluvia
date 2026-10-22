import SwiftUI

/// Go menu: Back, Forward and Go to Owner in the focused cluster window.
struct NavigationCommands: Commands {
    @FocusedValue(\.clusterSession) private var session

    var body: some Commands {
        CommandMenu("Go") {
            // Never under an open sheet: navigating would change what the sheet acts on.
            let usable = session.map { $0.pendingAction == nil && $0.editModel == nil && !$0.showPalette } ?? false
            Button("Back") { session?.goBack() }
                .keyboardShortcut("[")
                .disabled(!usable || session?.canGoBack != true)
            Button("Forward") { session?.goForward() }
                .keyboardShortcut("]")
                .disabled(!usable || session?.canGoForward != true)
            Divider()
            Button("Go to Owner") { session?.goToOwner() }
                .keyboardShortcut(.upArrow)
                // Not `selectedRowOwner`: reading the table's rows here would rebuild the menu on every watch update.
                .disabled(!usable || session?.canGoToOwner != true)
        }
    }
}
