import KubeKit
import SwiftUI

/// Delete confirmation. The object is read first so the delete can be pinned to its uid; a terminating object or a
/// Pod also gets a Force section, and any force option asks for the object's name before the button enables.
struct DeleteSheet: View {
    let session: ClusterSession
    let pending: PendingAction
    @Environment(\.dismiss) private var dismiss
    @State private var object: Unstructured?
    @State private var loadError: String?
    @State private var choice = ClusterSession.DeleteChoice()
    @State private var typedName = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Delete \(pending.kind.kind)?", systemImage: ResourceAction.delete.symbol)
                .font(.title3.weight(.semibold))
            TargetSummary(kind: pending.kind, key: pending.key, contextName: session.contextName)
            Text("This cannot be undone.").foregroundStyle(.secondary)
            Picker("Dependents", selection: $choice.propagation) {
                Text("Delete in background").tag(DynamicClient.PropagationPolicy.background)
                Text("Delete before owner (foreground)").tag(DynamicClient.PropagationPolicy.foreground)
                Text("Keep (orphan)").tag(DynamicClient.PropagationPolicy.orphan)
            }
            if let object {
                if ForceDelete.isOffered(kind: pending.kind, object: object) {
                    ForceDeleteSection(kind: pending.kind, object: object, choice: $choice, typedName: $typedName)
                }
            } else if deleteByNameOnly {
                Label("You may delete but not read this object, so it is deleted by name and cannot be forced.",
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let loadError {
                Label("Cannot read the object: \(loadError)", systemImage: "xmark.octagon")
                    .foregroundStyle(.red).textSelection(.enabled)
            } else {
                ProgressView().controlSize(.small)
            }
            if let error { Label(error, systemImage: "xmark.octagon").foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button(forcing ? "Force Delete" : "Delete", role: .destructive, action: confirm)
                    .disabled(!canConfirm)
                    // Destructive confirmations read as such: macOS draws a destructive role like any other button.
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task { await load() }
    }

    private var forcing: Bool { choice.skipGracePeriod || choice.removeFinalizers }

    /// RBAC can grant `delete` without `get`; such a user still gets a plain delete, as before the object was read.
    @State private var deleteByNameOnly = false

    private var canConfirm: Bool {
        guard !busy else { return false }
        if deleteByNameOnly { return true }
        let typed = typedName.trimmingCharacters(in: .whitespacesAndNewlines)
        return object?.uid != nil && (!forcing || typed == pending.key.name)
    }

    private func load() async {
        guard let client = session.client else { loadError = "Not connected"; return }
        do {
            object = try await client.get(pending.kind.gvr, name: pending.key.name, namespace: pending.key.namespace)
        } catch let error as KubeAPIError where error.statusCode == 403 {
            deleteByNameOnly = true
        } catch let error as KubeAPIError where error.statusCode == 404 {
            loadError = "It no longer exists."
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func confirm() {
        let uid = object?.uid
        guard uid != nil || deleteByNameOnly else { return }
        busy = true
        Task {
            error = await session.delete(pending, uid: uid, choice: choice)
            busy = false
            if error == nil { dismiss() }
        }
    }
}
