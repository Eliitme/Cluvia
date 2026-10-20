import KubeKit
import SwiftUI

/// Drain a node with kubectl-equivalent options and a live log of what happens to each pod.
struct DrainSheet: View {
    let pending: PendingAction
    let contextName: String
    let client: DynamicClient?
    @Environment(\.dismiss) private var dismiss
    @State private var options = DrainOptions()
    @State private var events: [DrainEvent] = []
    @State private var running = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Drain Node", systemImage: "arrow.down.to.line").font(.title3.weight(.semibold))
            TargetSummary(kind: pending.kind, key: pending.key, contextName: contextName)
            Text("Cordons the node, then evicts its pods. PodDisruptionBudgets are respected; blocked pods are retried until the timeout.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Ignore DaemonSet pods", isOn: $options.ignoreDaemonSets)
            Toggle("Delete emptyDir data", isOn: $options.deleteEmptyDirData)
            Toggle("Force: evict pods without a controller (they are not recreated)", isOn: $options.force)
            if !events.isEmpty || running {
                List(Array(events.enumerated()), id: \.offset) { _, event in DrainEventRow(event: event) }
                    .frame(minHeight: 160)
            }
            if let error { Label(error, systemImage: "xmark.octagon").foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if running { ProgressView().controlSize(.small) }
                Spacer()
                Button(running ? "Stop" : "Close", role: .cancel) {
                    task?.cancel()
                    if !running { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                Button("Drain") { start() }.disabled(running || client == nil || isFinished)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var isFinished: Bool { if case .finished = events.last { true } else { false } }

    private func start() {
        guard let client else { return }
        running = true
        events = []
        error = nil
        let stream = NodeDrainer(client: client).drain(node: pending.key.name, options: options)
        task = Task {
            do {
                for try await event in stream { events.append(event) }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            running = false
        }
    }
}

private struct DrainEventRow: View {
    let event: DrainEvent

    var body: some View {
        switch event {
        case .cordoned: Label("Node cordoned", systemImage: "nosign")
        case let .skipped(key, reason): Label("\(key.description) skipped — \(reason)", systemImage: "arrow.uturn.right").foregroundStyle(.secondary)
        case let .refused(key, reason): Label("\(key.description) not evicted — \(reason)", systemImage: "hand.raised").foregroundStyle(.orange)
        case let .blocked(key, reason): Label("\(key.description) blocked — \(reason)", systemImage: "pause.circle").foregroundStyle(.orange)
        case let .evicted(key): Label("\(key.description) evicted", systemImage: "checkmark.circle").foregroundStyle(.green)
        case let .finished(remaining):
            Label(remaining.isEmpty ? "Drain complete" : "Timed out with \(remaining.count) pod(s) remaining",
                  systemImage: remaining.isEmpty ? "checkmark.seal" : "exclamationmark.triangle")
                .fontWeight(.semibold)
        }
    }
}
