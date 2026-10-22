import KubeKit
import SwiftUI

/// Edit or create a resource: YAML editor plus diff, dry run (server-side, nothing persisted) and apply.
struct YamlEditSheet: View {
    @Bindable var model: YamlEditModel
    let contextName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title).font(.headline)
                    Text("Context: \(contextName)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }
            .padding(12)
            Divider()
            VSplitView {
                Group {
                    if model.concealed {
                        ContentUnavailableView {
                            Label("Secret Values Hidden", systemImage: "eye.slash")
                        } description: {
                            Text("Editing a Secret shows its values in plain text.")
                        } actions: {
                            Button("Reveal and Edit") { model.concealed = false }
                        }
                    } else {
                        YamlEditorView(text: $model.text)
                    }
                }
                .frame(minHeight: 320, idealHeight: 480)
                outcomeView.frame(minHeight: 60, idealHeight: 120)
            }
            Divider()
            if let state = model.secretState, !model.concealed {
                SecretEditFooter(state: state, removeLastApplied: $model.removeLastApplied)
                Divider()
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Diff") { model.showDiff() }.disabled(!model.isModified)
                Button("Dry Run") { Task { await model.dryRun() } }.disabled(model.busy || model.concealed)
                // ⌘↩ rather than Return: Return must insert a newline in the editor, never apply to the cluster.
                Button("Apply") { Task { await apply(force: false) } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.busy || model.concealed)
            }
            .padding(12)
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 560, idealHeight: 720)
    }

    private func apply(force: Bool) async {
        if await model.apply(force: force) { dismiss() }
    }

    @ViewBuilder
    private var outcomeView: some View {
        switch model.outcome {
        case .none:
            Text("Diff shows your edits. Dry Run asks the server to validate and default the change without saving it. "
                 + "Changes use server-side apply: a field you delete is only removed if no other manager also owns it.")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).padding()
        case let .diff(lines):
            DiffListView(lines: lines, emptyText: "No changes")
        case let .preview(lines):
            DiffListView(lines: lines, emptyText: "Dry run succeeded: the stored object would not change")
        case let .conflicts(causes):
            VStack(alignment: .leading, spacing: 6) {
                Label("Other field managers own fields this change modifies", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                ForEach(Array(causes.enumerated()), id: \.offset) { _, cause in
                    Text("\(cause.field ?? "?") — \(cause.message)").font(.system(.callout, design: .monospaced))
                }
                Button("Force Apply (take ownership)") { Task { await apply(force: true) } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding()
        case let .failed(message):
            ScrollView {
                Label(message, systemImage: "xmark.octagon").foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
    }
}

/// How Secret values are edited, which keys stay base64, and the offer to drop the annotation holding old values.
private struct SecretEditFooter: View {
    let state: SecretEditState
    @Binding var removeLastApplied: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Values under data are shown decoded and saved as base64. Unchanged values are sent exactly as stored.")
                .foregroundStyle(.secondary)
            if !state.base64Keys.isEmpty {
                Text("Kept as base64 (binary or not plain text): \(state.base64Keys.sorted().joined(separator: ", "))")
                    .foregroundStyle(.secondary)
            }
            if state.hadLastApplied {
                Toggle("Remove last-applied-configuration (it contains the previous values)", isOn: $removeLastApplied)
                    .foregroundStyle(.orange)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct DiffListView: View {
    let lines: [LineDiff.Line?]
    let emptyText: String

    var body: some View {
        if lines.isEmpty {
            Text(emptyText).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        if let line {
                            Text(prefix(line.kind) + line.text)
                                .foregroundStyle(color(line.kind))
                                .background(color(line.kind).opacity(line.kind == .same ? 0 : 0.12))
                        } else {
                            Text("⋯").foregroundStyle(.tertiary)
                        }
                    }
                }
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
            }
        }
    }

    private func prefix(_ kind: LineDiff.Kind) -> String {
        switch kind {
        case .same: "  "
        case .added: "+ "
        case .removed: "- "
        }
    }

    private func color(_ kind: LineDiff.Kind) -> Color {
        switch kind {
        case .same: .primary
        case .added: .green
        case .removed: .red
        }
    }
}
