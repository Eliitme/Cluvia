import HelmKit
import SwiftUI

enum HelmSheet: Identifiable {
    case install
    case upgrade(HelmRelease, values: String)
    case rollback(HelmRelease, revision: Int)
    case uninstall(HelmRelease)

    var id: String {
        switch self {
        case .install: "install"
        case let .upgrade(release, _): "upgrade:\(release.id)"
        case let .rollback(release, revision): "rollback:\(release.id):\(revision)"
        case let .uninstall(release): "uninstall:\(release.id)"
        }
    }
}

struct HelmReleaseDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case values = "Values", manifest = "Manifest", notes = "Notes", history = "History"
        var id: String { rawValue }
    }

    let model: HelmReleasesModel
    @Binding var sheet: HelmSheet?
    @State private var tab = Tab.values

    var body: some View {
        if let release = model.selectedRelease {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(release.name).font(.title3.weight(.semibold))
                    Text("\(release.chart) · \(release.namespace) · revision \(release.revision)").foregroundStyle(.secondary)
                    HStack {
                        Button("Upgrade…") { sheet = .upgrade(release, values: model.detail?.values ?? "") }
                        Button("Uninstall…", role: .destructive) { sheet = .uninstall(release) }
                    }
                    .controlSize(.small)
                    Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                }
                .padding(12)
                Divider()
                if let detail = model.detail {
                    switch tab {
                    case .values: ReadOnlyTextView(text: detail.values)
                    case .manifest: ReadOnlyTextView(text: detail.manifest)
                    case .notes: ReadOnlyTextView(text: detail.notes.isEmpty ? "This chart has no notes." : detail.notes)
                    case .history: history(detail.history, release: release)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            ContentUnavailableView("No Selection", systemImage: "sidebar.right")
        }
    }

    private func history(_ revisions: [HelmRevision], release: HelmRelease) -> some View {
        List(revisions) { revision in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Revision \(revision.revision) · \(revision.status)").fontWeight(revision.revision == release.revision ? .semibold : .regular)
                    Text("\(revision.chart) · \(revision.description)").font(.caption).foregroundStyle(.secondary)
                    Text(revision.updated).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                if revision.revision != release.revision {
                    Button("Roll Back…") { sheet = .rollback(release, revision: revision.revision) }.controlSize(.small)
                }
            }
        }
    }
}
