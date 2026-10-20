import SwiftUI

/// Root of the single main window: clusters and their resource kinds in the sidebar, the selected cluster on the right.
struct MainWindowView: View {
    @Environment(ClusterCatalogModel.self) private var catalog
    @Environment(AppSettingsStore.self) private var settings
    @State private var whatsNew: ReleaseNotes.Release?

    var body: some View {
        NavigationSplitView {
            WorkspaceSidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        } detail: {
            if let session = catalog.selectedSession {
                ClusterDetailPane(session: session).id(session.contextName)
            } else if let name = catalog.selectedContext, let context = catalog.contexts.first(where: { $0.name == name }) {
                ContextConnectPane(context: context)
            } else {
                WelcomeView()
            }
        }
        .frame(minWidth: 960, minHeight: 540)
        .sheet(item: $whatsNew) { WhatsNewSheet(release: $0) }
        .task {
            whatsNew = WhatsNew.releaseToShow()
            await catalog.reload()
            catalog.connectAutomatically(settings: settings)
            await catalog.checkAutomatically()
        }
    }
}

private struct WelcomeView: View {
    @Environment(ClusterCatalogModel.self) private var catalog

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(catalog.contexts.isEmpty && !catalog.isLoading ? "No Kubernetes Contexts" : "Select a Cluster")
            } icon: {
                Image("BrandMark").resizable().scaledToFit().frame(width: 72)
            }
        } description: {
            if catalog.contexts.isEmpty, !catalog.isLoading {
                Text(catalog.loadErrors.first ?? "Add one with the + button, or from ~/.kube/config or KUBECONFIG.")
            } else {
                Text("Pick a cluster in the sidebar to connect.")
            }
        }
        .navigationTitle("Cluvia")
    }
}
