import KubeKit
import SwiftUI

/// Confirmation for disruptive actions, always naming the object, namespace and cluster context.
struct ConfirmActionSheet: View {
    let pending: PendingAction
    let contextName: String
    /// Returns an error message, or nil on success.
    let perform: (DynamicClient.PropagationPolicy) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var propagation = DynamicClient.PropagationPolicy.background
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("\(pending.action.title.replacingOccurrences(of: "…", with: "")) \(pending.kind.kind)?", systemImage: pending.action.symbol)
                .font(.title3.weight(.semibold))
            TargetSummary(kind: pending.kind, key: pending.key, contextName: contextName)
            Text(explanation).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if pending.action == .delete {
                Picker("Dependents", selection: $propagation) {
                    Text("Delete in background").tag(DynamicClient.PropagationPolicy.background)
                    Text("Delete before owner (foreground)").tag(DynamicClient.PropagationPolicy.foreground)
                    Text("Keep (orphan)").tag(DynamicClient.PropagationPolicy.orphan)
                }
            }
            if let error { Label(error, systemImage: "xmark.octagon").foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(pending.action.title.replacingOccurrences(of: "…", with: ""), role: pending.action == .delete ? .destructive : nil) {
                    busy = true
                    Task {
                        error = await perform(propagation)
                        busy = false
                        if error == nil { dismiss() }
                    }
                }
                .disabled(busy)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var explanation: String {
        switch pending.action {
        case .delete: "This cannot be undone."
        case .restart: "Pods are replaced according to the rollout strategy."
        case .cordon: "New pods will not be scheduled on this node. Running pods are not evicted."
        case .uncordon: "The node will accept new pods again."
        default: ""
        }
    }
}

struct ScaleSheet: View {
    let pending: PendingAction
    let contextName: String
    let current: Int
    /// Returns an error message, or nil on success.
    let perform: (Int) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var replicas = 0
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Scale \(pending.kind.kind)", systemImage: "arrow.up.and.down").font(.title3.weight(.semibold))
            TargetSummary(kind: pending.kind, key: pending.key, contextName: contextName)
            Stepper("Replicas: \(replicas)", value: $replicas, in: 0...10_000)
            if replicas == 0 { Text("Scaling to 0 stops all pods.").foregroundStyle(.orange) }
            if let error { Label(error, systemImage: "xmark.octagon").foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Scale") {
                    busy = true
                    Task {
                        error = await perform(replicas)
                        busy = false
                        if error == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(replicas == current || busy)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { replicas = current }
    }
}

struct TargetSummary: View {
    let kind: ResourceKind
    let key: ObjectKey
    let contextName: String

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            GridRow { Text("Name").foregroundStyle(.secondary); Text(key.name).fontWeight(.medium) }
            if let namespace = key.namespace { GridRow { Text("Namespace").foregroundStyle(.secondary); Text(namespace) } }
            GridRow { Text("Context").foregroundStyle(.secondary); Text(contextName).fontWeight(.medium) }
        }
        .textSelection(.enabled)
    }
}
