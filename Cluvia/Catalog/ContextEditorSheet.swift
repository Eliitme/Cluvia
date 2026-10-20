import KubeKit
import SwiftUI

/// Create or edit a context together with its cluster and user, written straight to the kubeconfig file.
struct ContextEditorSheet: View {
    /// nil creates a new context.
    let contextName: String?
    @Environment(ClusterCatalogModel.self) private var catalog
    @Environment(AppSettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    /// Snapshot for filling the form and the cluster/user pickers; saving starts again from the files on disk.
    @State private var config: KubeConfigSet?
    @State private var draft = KubeContextDraft()
    @State private var auth = AuthFields()
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            Text(contextName.map { "Edit \($0)" } ?? "New Context").font(.headline).padding(12)
            Divider()
            if let config {
                ContextEditorForm(draft: $draft, auth: $auth, config: config, originalName: contextName)
            } else if let error {
                ContentUnavailableView("Cannot Open Kubeconfig", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text("Comments in the file are not kept; a backup of the previous version is saved next to it.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(config == nil || saving)
            }
            .padding(12)
            if let error, config != nil {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .bottom], 12)
            }
        }
        .frame(width: 640, height: 680)
        .task { load() }
    }

    private func load() {
        do {
            let config = try catalog.loadConfigSet()
            if let contextName {
                draft = try config.draft(forContext: contextName)
                auth.method = .keep
            }
            self.config = config
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            var draft = draft
            draft.credentials = try auth.credentials()
            try await catalog.change { try $0.apply(draft, originalName: contextName) }
            // The reload already closed the old name's session; its preferences follow the new name.
            let newName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let contextName, newName != contextName { settings.moveContext(contextName, to: newName) }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Authentication inputs. Secrets are typed in, never read back from the file.
struct AuthFields {
    enum Method: String, CaseIterable, Identifiable {
        case keep = "Keep Current"
        case token = "Token"
        case certificate = "Client Certificate"
        case plugin = "Credential Plugin"
        case none = "None"
        var id: String { rawValue }
    }

    var method: Method = .token
    var token = ""
    var certificatePEM = ""
    var keyPEM = ""
    var command = ""
    /// One argument per line, so arguments may contain spaces.
    var arguments = ""
    var apiVersion = "client.authentication.k8s.io/v1"

    func credentials() throws -> KubeContextDraft.Credentials {
        switch method {
        case .keep: return .unchanged
        case .none: return .none
        case .token:
            guard !token.isEmpty else { throw KubeConfigEditError.missingValue("A token") }
            return .token(token)
        case .certificate:
            guard !certificatePEM.isEmpty, !keyPEM.isEmpty else { throw KubeConfigEditError.missingValue("A client certificate and key") }
            return .clientCertificate(certificatePEM: certificatePEM, keyPEM: keyPEM)
        case .plugin:
            let command = command.trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { throw KubeConfigEditError.missingValue("A plugin command") }
            let arguments = arguments.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return .exec(command: command, arguments: arguments, apiVersion: apiVersion)
        }
    }
}
