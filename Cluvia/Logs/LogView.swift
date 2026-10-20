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
                Toggle("Follow", isOn: $model.follow)
                Toggle("Previous", isOn: $model.previous)
                Toggle("Timestamps", isOn: $model.showTimestamps)
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

/// Append-only log text. New lines are appended to the text storage; a full rebuild only happens when the
/// buffer drops old lines or the timestamp option changes. Search highlighting is incremental: only appended
/// text is scanned, and the whole document only when the query changes or the text is rebuilt.
struct LogTextView: NSViewRepresentable {
    let model: LogViewModel
    @Binding var matchCount: Int

    final class Coordinator {
        var renderedEnd = 0
        var resetToken = -1
        var showTimestamps: Bool?
        var wrap: Bool?
        var search = ""
        var matches = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.isRichText = false
            textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular)
            textView.textContainerInset = NSSize(width: 6, height: 6)
            // TextKit 1 for temporary-attribute highlighting; lay out only what is visible.
            textView.layoutManager?.allowsNonContiguousLayout = true
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView, let storage = textView.textStorage else { return }
        let state = context.coordinator
        if state.wrap != model.wrapLines {
            applyWrap(model.wrapLines, to: textView, scroll: scroll)
            state.wrap = model.wrapLines
        }
        let atBottom = scroll.contentView.bounds.maxY >= textView.bounds.maxY - 40
        let attributes: [NSAttributedString.Key: Any] = [.font: textView.font as Any, .foregroundColor: NSColor.textColor]
        var rescanFrom: Int?
        /// Where pod-name coloring must run: rebuilt or appended text only (colors survive search changes).
        var recolorFrom: Int?
        /// Matches ending at or before this offset were already counted.
        var countedUpTo = 0

        if state.resetToken != model.resetToken || state.showTimestamps != model.showTimestamps {
            storage.setAttributedString(NSAttributedString(string: model.text(from: model.buffer.dropped) ?? "", attributes: attributes))
            state.resetToken = model.resetToken
            state.showTimestamps = model.showTimestamps
            state.matches = 0
            rescanFrom = 0
            recolorFrom = 0
        } else if model.buffer.endIndex > state.renderedEnd, let text = model.text(from: state.renderedEnd) {
            let seam = storage.length
            storage.append(NSAttributedString(string: (seam > 0 ? "\n" : "") + text, attributes: attributes))
            // Back up by the query length so a match spanning the seam is found.
            rescanFrom = max(0, seam - model.search.utf16.count)
            countedUpTo = seam
            recolorFrom = seam
        }
        state.renderedEnd = model.buffer.endIndex
        if state.search != model.search {
            state.search = model.search
            state.matches = 0
            textView.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
            rescanFrom = 0
            countedUpTo = 0
        }
        if let recolorFrom { LogLevelColoring.apply(to: storage, from: recolorFrom) }
        if model.isMultiPod, let recolorFrom {
            let order = Dictionary(model.sources.enumerated().map { ($1.pod, $0) }, uniquingKeysWith: { first, _ in first })
            Self.colorPodPrefixes(in: storage, from: recolorFrom, order: order)
        }
        if let rescanFrom, !model.search.isEmpty {
            state.matches += highlight(model.search, in: textView, from: rescanFrom, countingAfter: countedUpTo)
        }
        if matchCount != state.matches { DispatchQueue.main.async { matchCount = state.matches } }
        if atBottom { textView.scrollToEndOfDocument(nil) }
    }

    /// Pod name at the start of a line, optionally after a timestamp.
    static let prefixPattern = try! NSRegularExpression(pattern: #"^(?:\S+ )?([A-Za-z0-9.\-]+) │ "#, options: .anchorsMatchLines)
    static let prefixColors: [NSColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemPink, .systemTeal, .systemYellow, .systemIndigo]

    /// Colors each line's pod-name prefix; pods get distinct colors in the order they were opened.
    static func colorPodPrefixes(in storage: NSTextStorage, from start: Int, order: [String: Int]) {
        let range = NSRange(location: start, length: storage.length - start)
        for match in prefixPattern.matches(in: storage.string, range: range) {
            let name = (storage.string as NSString).substring(with: match.range(at: 1))
            let color = prefixColors[(order[name] ?? 0) % prefixColors.count]
            storage.addAttribute(.foregroundColor, value: color, range: match.range(at: 1))
        }
    }

    private func applyWrap(_ wrap: Bool, to textView: NSTextView, scroll: NSScrollView) {
        textView.isHorizontallyResizable = !wrap
        textView.textContainer?.widthTracksTextView = wrap
        scroll.hasHorizontalScroller = !wrap
        let width = wrap ? scroll.contentSize.width : CGFloat.greatestFiniteMagnitude
        textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        if wrap { textView.frame.size.width = scroll.contentSize.width }
    }

    /// Highlights matches from `start`; returns how many end after `countedUpTo` (earlier ones were counted).
    private func highlight(_ search: String, in textView: NSTextView, from start: Int, countingAfter countedUpTo: Int) -> Int {
        guard let layout = textView.layoutManager, let storage = textView.textStorage else { return 0 }
        let string = storage.mutableString
        var range = NSRange(location: start, length: string.length - start)
        var count = 0
        while range.length > 0 {
            let found = string.range(of: search, options: .caseInsensitive, range: range)
            guard found.location != NSNotFound else { break }
            layout.addTemporaryAttribute(.backgroundColor, value: NSColor.findHighlightColor, forCharacterRange: found)
            if NSMaxRange(found) > countedUpTo { count += 1 }
            let next = found.location + max(found.length, 1)
            range = NSRange(location: next, length: string.length - next)
        }
        return count
    }
}
