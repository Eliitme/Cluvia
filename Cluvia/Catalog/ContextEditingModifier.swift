import KubeKit
import SwiftUI

/// A kubeconfig change started from the catalog.
enum ContextEditing: Identifiable, Equatable {
    case create
    case edit(String)
    case importFile
    case importPaste
    case delete(String)

    var id: String {
        switch self {
        case .create: "create"
        case let .edit(name): "edit:\(name)"
        case .importFile: "import"
        case .importPaste: "paste"
        case let .delete(name): "delete:\(name)"
        }
    }
}

/// Sheets and the delete confirmation for kubeconfig edits; failures are reported through `failure`.
struct ContextEditingModifier: ViewModifier {
    @Binding var editing: ContextEditing?
    @Binding var failure: String?
    @Environment(ClusterCatalogModel.self) private var catalog
    @Environment(AppSettingsStore.self) private var settings

    private var sheet: Binding<ContextEditing?> {
        Binding(get: { editing.flatMap { if case .delete = $0 { nil } else { $0 } } }, set: { editing = $0 })
    }

    private var deleting: String? {
        if case let .delete(name) = editing { name } else { nil }
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: sheet) { editing in
                switch editing {
                case .create: ContextEditorSheet(contextName: nil)
                case let .edit(name): ContextEditorSheet(contextName: name)
                case .importFile: ContextImportSheet(source: .file)
                case .importPaste: ContextImportSheet(source: .paste)
                case .delete: EmptyView()
                }
            }
            .confirmationDialog(
                "Delete context \"\(deleting ?? "")\"?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { editing = nil } }),
                titleVisibility: .visible
            ) {
                if let name = deleting {
                    Button("Delete Context and Unused Cluster and User", role: .destructive) { delete(name, prune: true) }
                    Button("Delete Context Only", role: .destructive) { delete(name, prune: false) }
                }
            } message: {
                Text("Removes it from \(deleting.flatMap(catalog.file(for:))?.path ?? "the kubeconfig"). A backup of the previous file is kept next to it.")
            }
    }

    private func delete(_ name: String, prune: Bool) {
        Task {
            do {
                try await catalog.deleteContext(name, pruneUnused: prune, settings: settings)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
