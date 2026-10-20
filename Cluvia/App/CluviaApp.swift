import SwiftUI

@main
struct CluviaApp: App {
    @NSApplicationDelegateAdaptor(CluviaAppDelegate.self) private var appDelegate
    @State private var catalog = ClusterCatalogModel()
    @State private var settings = AppSettingsStore()

    var body: some Scene {
        // One window: clusters in the sidebar, the selected one in the detail area.
        Window("Cluvia", id: "main") {
            MainWindowView()
                .environment(catalog)
                .environment(settings)
                .task { openLaunchContext() }
        }
        .defaultSize(width: 1280, height: 800)
        .commands { BrowserCommands() }
    }

    /// Debug-only: `-CluviaOpenContext <name>` opens a cluster window at launch for automated UI checks.
    private func openLaunchContext() {
        #if DEBUG
        if let context = UserDefaults.standard.string(forKey: "CluviaOpenContext") {
            catalog.open(context, settings: settings)
        }
        #endif
    }
}

struct BrowserCommands: Commands {
    @FocusedValue(\.clusterSession) private var session

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Refresh") { session?.refresh() }
                .keyboardShortcut("r")
                .disabled(session == nil)
            Button("Command Palette…") { session?.showPalette = true }
                .keyboardShortcut("k")
                .disabled(session == nil)
            Button(session?.dock.isVisible == true ? "Hide Bottom Panel" : "Show Bottom Panel") {
                session?.dock.isVisible.toggle()
            }
            .keyboardShortcut("j")
            .disabled(session == nil)
            Button("Port Forwards") { session?.dock.showPortForwards() }
                .disabled(session == nil)
            Divider()
            ForEach(Array(ResourceCategory.allCases.enumerated()), id: \.element) { index, category in
                Button("Show \(category.rawValue)") {
                    guard let session else { return }
                    session.selectedKind = session.kinds.first { $0.category == category }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .disabled(session?.kinds.contains { $0.category == category } != true)
            }
        }
    }
}
