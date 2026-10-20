import HelmKit
import SwiftUI

/// Sidebar destination listing Helm releases, with details and release operations.
struct HelmReleasesView: View {
    @Bindable var model: HelmReleasesModel
    let namespaces: Set<String>
    @State private var sheet: HelmSheet?

    private var visible: [HelmRelease] {
        namespaces.isEmpty ? model.releases : model.releases.filter { namespaces.contains($0.namespace) }
    }

    var body: some View {
        Group {
            switch model.availability {
            case .missing:
                ContentUnavailableView("Helm Not Installed", systemImage: "shippingbox",
                                       description: Text("Install helm (for example with Homebrew) to manage Helm releases. Everything else works without it."))
            default:
                Table(visible, selection: $model.selection) {
                    TableColumn("Name", value: \.name)
                    TableColumn("Namespace", value: \.namespace)
                    TableColumn("Revision") { Text(String($0.revision)).monospacedDigit() }.width(70)
                    TableColumn("Status") { release in
                        Text(release.status).foregroundStyle(release.status == "deployed" ? .green : (release.status == "failed" ? .red : .orange))
                    }
                    TableColumn("Chart", value: \.chart)
                    TableColumn("App Version", value: \.appVersion)
                    TableColumn("Updated", value: \.updated)
                }
                .overlay {
                    if let error = model.error, model.releases.isEmpty {
                        ContentUnavailableView("Cannot List Releases", systemImage: "exclamationmark.triangle", description: Text(error))
                    } else if model.loading, model.releases.isEmpty {
                        ProgressView()
                    }
                }
                .inspector(isPresented: .constant(model.selection != nil)) {
                    HelmReleaseDetailView(model: model, sheet: $sheet).inspectorColumnWidth(min: 360, ideal: 460)
                }
            }
        }
        .navigationSubtitle("Helm Releases · \(visible.count)")
        .toolbar {
            ToolbarItem {
                Button { sheet = .install } label: { Label("Install Chart", systemImage: "plus") }
                    .disabled(model.availability != .available)
            }
            ToolbarItem {
                Button { Task { await model.refresh() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
            }
        }
        .sheet(item: $sheet) { HelmSheetView(model: model, sheet: $0) }
        .task { await model.refresh() }
        // Reload details when the selection changes, once helm has been located, and after new revisions.
        .task(id: "\(model.selection ?? "")|\(model.availability)|\(model.selectedRelease?.revision ?? 0)") {
            await model.loadDetail()
        }
    }
}
