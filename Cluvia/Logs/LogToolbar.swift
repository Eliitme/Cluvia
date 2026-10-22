import SwiftUI

/// Second toolbar row of a log tab: which lines to show, how to format them, and moving between errors.
struct LogToolbar: View {
    @Bindable var model: LogViewModel
    /// Typed text; applied to the view after a short pause so each keystroke does not redraw 100k lines.
    @State private var filterText = ""

    var body: some View {
        HStack(spacing: 10) {
            TextField("Filter lines", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .task(id: filterText) {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled, model.display.filter != filterText else { return }
                    model.display.filter = filterText
                }
            Toggle(".*", isOn: $model.display.filterIsRegex).help("Filter is a regular expression")
            if !model.display.lineFilter.isValid {
                Text("Invalid regex").foregroundStyle(.red)
            }
            Picker("Level", selection: $model.display.minimumLevel) {
                Text("All Levels").tag(LogLevel.other)
                Text("Warnings and Errors").tag(LogLevel.warning)
                Text("Errors").tag(LogLevel.error)
            }
            .labelsHidden()
            .frame(width: 160)
            Picker("Since", selection: $model.sinceSeconds) {
                Text("Any Time").tag(Int?.none)
                Text("Last 5 min").tag(Int?.some(300))
                Text("Last 15 min").tag(Int?.some(900))
                Text("Last hour").tag(Int?.some(3600))
                Text("Last 6 hours").tag(Int?.some(21_600))
                Text("Last 24 hours").tag(Int?.some(86_400))
            }
            .labelsHidden()
            .frame(width: 120)
            Toggle("JSON", isOn: $model.display.prettyJSON).help("Show JSON lines indented")
            Toggle("Local Time", isOn: $model.display.localTime)
                .disabled(!model.display.showTimestamps)
                .help("Show timestamps in this Mac's time zone")
            Spacer()
            Button { model.jump(forward: false) } label: { Image(systemName: "chevron.up") }
                .keyboardShortcut(.upArrow, modifiers: [.option, .command])
                .help("Previous Error (⌥⌘↑)")
            Button { model.jump(forward: true) } label: { Image(systemName: "chevron.down") }
                .keyboardShortcut(.downArrow, modifiers: [.option, .command])
                .help("Next Error (⌥⌘↓)")
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.bottom, 5)
        .onAppear { filterText = model.display.filter }
    }
}
