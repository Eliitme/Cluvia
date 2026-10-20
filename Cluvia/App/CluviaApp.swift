import SwiftUI

@main
struct CluviaApp: App {
    @State private var catalog = ClusterCatalogModel()
    @State private var settings = AppSettingsStore()

    var body: some Scene {
        Window("Clusters", id: "catalog") {
            ClusterCatalogView()
                .environment(catalog)
                .environment(settings)
                .frame(minWidth: 760, minHeight: 360)
                .task { openLaunchContext() }
        }
        .defaultSize(width: 960, height: 520)

        WindowGroup("Cluster", for: String.self) { $contextName in
            if let contextName {
                ClusterWindow(contextName: contextName)
                    .environment(catalog)
                    .environment(settings)
            }
        }
        .defaultSize(width: 1280, height: 800)
        .commands { BrowserCommands() }
    }

    @Environment(\.openWindow) private var openWindow

    /// Debug-only: `-CluviaOpenContext <name>` opens a cluster window at launch for automated UI checks.
    private func openLaunchContext() {
        #if DEBUG
        if let context = UserDefaults.standard.string(forKey: "CluviaOpenContext") {
            catalog.markRequested(context)
            openWindow(value: context)
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
