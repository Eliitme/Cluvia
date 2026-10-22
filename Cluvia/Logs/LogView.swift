import KubeKit
import SwiftUI

struct LogView: View {
    @Bindable var model: LogViewModel
    @State private var matchCount = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if model.containers.count > 1 {
                    Picker("Container", selection: $model.container) {
                        ForEach(model.containers, id: \.name) { choice in
                            Text(choice.role.map { "\(choice.name) (\($0))" } ?? choice.name).tag(choice.name)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                Picker("Tail", selection: $model.tailLines) {
                    Text("Last 100").tag(Int?.some(100))
                    Text("Last 1,000").tag(Int?.some(1000))
                    Text("Last 10,000").tag(Int?.some(10000))
                    Text("All").tag(Int?.none)
                }
                .labelsHidden()
                .frame(width: 110)
                // A time window replaces the line limit (see `LogViewModel.sinceSeconds`).
                .disabled(model.sinceSeconds != nil)
                .help(model.sinceSeconds != nil ? "All lines in the chosen time window" : "Lines loaded before following")
                Toggle("Follow", isOn: $model.follow)
                Toggle("Previous", isOn: $model.previous)
                Toggle("Timestamps", isOn: $model.display.showTimestamps)
                Toggle("Wrap", isOn: $model.wrapLines)
                Spacer()
                statusLabel
                TextField("Search", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                if !model.search.isEmpty { Text("\(matchCount) matches").foregroundStyle(.secondary).monospacedDigit() }
                Button { model.clear() } label: { Image(systemName: "trash") }.help("Clear")
                Button { model.saveToFile() } label: { Image(systemName: "square.and.arrow.down") }.help("Save Logs…")
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            LogToolbar(model: model)
            Divider()
            LogTextView(model: model, matchCount: $matchCount)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch model.status {
        case .streaming:
            EmptyView()
        case let .reconnecting(reason):
            Label("Reconnecting", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.orange).help(reason)
        case let .ended(reason):
            Label("Ended", systemImage: "stop.circle").foregroundStyle(.secondary).help(reason)
        case let .failed(reason):
            Label("Failed", systemImage: "exclamationmark.triangle").foregroundStyle(.red).help(reason)
        }
    }
}
