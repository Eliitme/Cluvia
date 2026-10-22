import KubeKit
import SwiftUI

/// A Deployment's revisions, newest first, with rolling back to one of them (like `kubectl rollout undo --to-revision`).
struct RolloutHistorySheet: View {
    let session: ClusterSession
    let pending: PendingAction
    @Environment(\.dismiss) private var dismiss
    @State private var revisions: [DeploymentRevision]?
    /// The Deployment's spec generation when the history was read; a rollback refuses if it moved on since.
    @State private var generation: Int64?
    @State private var selection: DeploymentRevision.ID?
    @State private var confirming: DeploymentRevision?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Rollout History", systemImage: ResourceAction.rolloutHistory.symbol).font(.title3.weight(.semibold))
            TargetSummary(kind: pending.kind, key: pending.key, contextName: session.contextName)
            if let revisions, revisions.isEmpty {
                ContentUnavailableView("No Revisions", systemImage: "clock",
                                       description: Text("No ReplicaSets owned by this Deployment were found."))
                    .frame(minHeight: 200)
            } else if let revisions {
                Table(revisions, selection: $selection) {
                    TableColumn("Revision") { revision in
                        Text(revision.id == revisions.first?.id ? "\(revision.revision) (current)" : "\(revision.revision)")
                            .fontWeight(revision.id == revisions.first?.id ? .semibold : .regular)
                    }
                    .width(110)
                    TableColumn("Change Cause") { Text($0.changeCause ?? "—").help($0.changeCause ?? "") }
                    TableColumn("Images") { Text($0.images.joined(separator: ", ")).help($0.images.joined(separator: "\n")) }
                    TableColumn("Age") { revision in
                        Text(revision.created.map { AgeFormatter.string(since: $0) } ?? "—")
                    }
                    .width(60)
                }
                .frame(minHeight: 200)
            } else if error == nil {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
            if let error { Label(error, systemImage: "xmark.octagon").foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Reload") { Task { await load() } }.disabled(busy)
                Spacer()
                Button("Close", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Roll Back to Revision \(selected.map { "\($0.revision)" } ?? "")") { confirming = selected }
                    .disabled(busy || selected == nil || selected?.id == revisions?.first?.id)
            }
        }
        .padding(20)
        .frame(width: 720)
        .task { await load() }
        .confirmationDialog("Roll back \(pending.key.name) to revision \(confirming?.revision ?? 0)?",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("Roll Back") { if let confirming { Task { await rollBack(to: confirming) } } }
        } message: {
            Text("Context \(session.contextName). The pod template returns to that revision and rolls out as a new revision.")
        }
    }

    private var selected: DeploymentRevision? { revisions?.first { $0.id == selection } }

    private func load() async {
        guard let client = session.client else { error = "Not connected"; return }
        do {
            let deployment = try await client.get(pending.kind.gvr, name: pending.key.name, namespace: pending.key.namespace)
            revisions = try await DeploymentRollout.revisions(client: client, deployment: deployment)
            generation = DeploymentRollout.generation(of: deployment)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func rollBack(to revision: DeploymentRevision) async {
        guard let client = session.client, let generation else { return }
        busy = true
        defer { busy = false }
        do {
            try await DeploymentRollout.rollback(client: client, namespace: pending.key.namespace ?? "default",
                                                 name: pending.key.name, toReplicaSet: revision.replicaSet, expectedGeneration: generation)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
