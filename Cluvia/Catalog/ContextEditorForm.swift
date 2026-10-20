import KubeKit
import SwiftUI

/// Fields of the context editor: the context, its cluster and its user. Cluster and user are picked from the ones
/// already defined (edited where they are defined) or created under a new name.
struct ContextEditorForm: View {
    @Binding var draft: KubeContextDraft
    @Binding var auth: AuthFields
    let config: KubeConfigSet
    /// nil while creating.
    let originalName: String?
    @State private var newCluster = false
    @State private var newUser = false

    private static let newTag = "\u{0}new"

    var body: some View {
        Form {
            Section("Context") {
                TextField("Name", text: $draft.name)
                TextField("Default namespace", text: $draft.namespace, prompt: Text("default"))
            }
            Section {
                Picker("Cluster", selection: clusterChoice) {
                    ForEach(config.names(in: .clusters), id: \.self) { Text($0).tag($0) }
                    Divider()
                    Text("New Cluster…").tag(Self.newTag)
                }
                if newCluster { TextField("New cluster name", text: $draft.clusterName) }
                TextField("Server", text: $draft.server, prompt: Text("https://host:6443"))
                LabeledContent("CA certificate (PEM)") { PEMEditor(text: $draft.certificateAuthorityPEM) }
                Toggle("Skip TLS verification (insecure)", isOn: $draft.insecureSkipTLSVerify)
            } header: {
                Text("Cluster")
            } footer: {
                SharedNote(names: others(.clusters, draft.clusterName), file: newCluster ? nil : config.file(of: .clusters, draft.clusterName))
            }
            Section {
                Picker("User", selection: userChoice) {
                    ForEach(config.names(in: .users), id: \.self) { Text($0).tag($0) }
                    Divider()
                    Text("New User…").tag(Self.newTag)
                }
                if newUser { TextField("New user name", text: $draft.userName) }
                Picker("Authentication", selection: $auth.method) {
                    ForEach(AuthFields.Method.allCases.filter { !newUser || $0 != .keep }) { Text($0.rawValue).tag($0) }
                }
                authFields
            } header: {
                Text("User")
            } footer: {
                SharedNote(names: others(.users, draft.userName), file: newUser ? nil : config.file(of: .users, draft.userName))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // Creating (or a context pointing at a missing entry) starts with new names.
            newCluster = !config.names(in: .clusters).contains(draft.clusterName)
            newUser = !config.names(in: .users).contains(draft.userName)
            (draft.createsCluster, draft.createsUser) = (newCluster, newUser)
            if newUser, auth.method == .keep { auth.method = .token }
        }
    }

    private var clusterChoice: Binding<String> {
        Binding { newCluster ? Self.newTag : draft.clusterName } set: { choice in
            newCluster = choice == Self.newTag
            config.loadCluster(newCluster ? "" : choice, into: &draft)
            draft.createsCluster = newCluster
        }
    }

    private var userChoice: Binding<String> {
        Binding { newUser ? Self.newTag : draft.userName } set: { choice in
            newUser = choice == Self.newTag
            draft.userName = newUser ? "" : choice
            draft.createsUser = newUser
            if newUser, auth.method == .keep { auth.method = .token }
            if !newUser { auth.method = .keep }
        }
    }

    @ViewBuilder
    private var authFields: some View {
        switch auth.method {
        case .keep, .none:
            EmptyView()
        case .token:
            SecureField("Token", text: $auth.token)
        case .certificate:
            LabeledContent("Certificate (PEM)") { PEMEditor(text: $auth.certificatePEM) }
            LabeledContent("Private key (PEM)") { PEMEditor(text: $auth.keyPEM) }
        case .plugin:
            TextField("Command", text: $auth.command, prompt: Text("e.g. aws, gke-gcloud-auth-plugin"))
            LabeledContent("Arguments (one per line)") { PEMEditor(text: $auth.arguments, height: 54) }
            TextField("API version", text: $auth.apiVersion)
        }
    }

    /// Other contexts sharing the cluster or user, which an edit here also changes.
    private func others(_ section: KubeConfigSection, _ name: String) -> [String] {
        config.contexts(referencing: section, name).filter { $0 != originalName }
    }
}

struct PEMEditor: View {
    @Binding var text: String
    var height: CGFloat = 72

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.caption, design: .monospaced))
            .autocorrectionDisabled()
            .frame(height: height)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
    }
}

private struct SharedNote: View {
    let names: [String]
    let file: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !names.isEmpty {
                Text("Also used by \(names.joined(separator: ", ")); changes apply there too.")
            }
            if let file { Text("Defined in \(WorkspaceSidebarView.displayPath(file))") }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}
