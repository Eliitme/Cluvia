import AppKit
import KubeKit
import SwiftUI

/// Copies contexts (with their clusters and users) from another kubeconfig, a file or pasted text, into the main one.
struct ContextImportSheet: View {
    enum Source { case file, paste }

    let source: Source
    @Environment(ClusterCatalogModel.self) private var catalog
    @Environment(\.dismiss) private var dismiss
    @State private var document: KubeConfigDocument?
    @State private var pasted = ""
    @State private var selected: Set<String> = []
    @State private var replaceExisting = false
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            Text(source == .file ? "Import from File" : "Import from Clipboard").font(.headline).padding(12)
            Divider()
            Form {
                if source == .file {
                    LabeledContent("From") {
                        HStack {
                            Text(document?.url.path ?? "No file chosen").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Button("Choose…", action: choose)
                        }
                    }
                } else {
                    Section("Kubeconfig YAML") {
                        PEMEditor(text: $pasted, height: 160)
                        HStack {
                            Button("Paste from Clipboard") { pasted = NSPasteboard.general.string(forType: .string) ?? ""
                                read() }
                            Spacer()
                            Button("Read", action: read).disabled(pasted.isEmpty)
                        }
                    }
                }
                if let document {
                    Section("Contexts") {
                        ForEach(document.names(in: .contexts), id: \.self) { name in
                            Toggle(name, isOn: Binding(
                                get: { selected.contains(name) },
                                set: { if $0 { selected.insert(name) } else { selected.remove(name) } }
                            ))
                        }
                    }
                    Toggle("Replace contexts, clusters and users with the same names", isOn: $replaceExisting)
                }
                if let target = catalog.primaryFile { LabeledContent("Into", value: target.path) }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") { Task { await importSelected() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(selected.isEmpty || saving)
            }
            .padding(12)
        }
        .frame(width: 580, height: source == .file ? 480 : 600)
        .onAppear { if source == .file, document == nil { choose() } }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.message = "Choose a kubeconfig file to import from"
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kube")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        use { try KubeConfigDocument.load(url) }
    }

    /// Pasted configs have no file of their own; relative paths in them resolve against the target's folder.
    private func read() {
        let base = (catalog.primaryFile ?? FileManager.default.homeDirectoryForCurrentUser).deletingLastPathComponent()
        use { try KubeConfigDocument(url: base.appendingPathComponent("pasted"), text: pasted, original: nil) }
    }

    private func use(_ load: () throws -> KubeConfigDocument) {
        do {
            let document = try load()
            self.document = document
            selected = Set(document.names(in: .contexts))
            error = selected.isEmpty ? "No contexts found." : nil
        } catch {
            document = nil
            // The pasted text has no file path the user would recognise.
            self.error = source == .paste ? "The pasted text is not a valid kubeconfig." : error.localizedDescription
        }
    }

    private func importSelected() async {
        guard let document else { return }
        saving = true
        defer { saving = false }
        do {
            try await catalog.change { try $0.importContexts(selected.sorted(), from: document, replaceExisting: replaceExisting) }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
