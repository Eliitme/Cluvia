import AppKit
import SwiftUI

/// Append-only log text. New lines are rendered and appended on the main thread (a few at a time); a full redraw
/// (old lines dropped, display options changed) is built off the main thread and the newest one wins. Search
/// highlighting is incremental: only appended text is scanned, and everything when the query or text changes.
struct LogTextView: NSViewRepresentable {
    let model: LogViewModel
    @Binding var matchCount: Int

    @MainActor final class Coordinator {
        weak var textView: NSTextView?
        var renderedEnd = 0
        var resetToken = -1
        var display: LogDisplayOptions?
        var wrap: Bool?
        var search = ""
        var matches = 0
        var jumpID = 0
        /// Rendered lines with ranges in the text storage, for jumping between errors.
        var lines: [RenderedLine] = []
        var redrawGeneration = 0
        var redrawing = false
        /// Another redraw was asked for while one was being built; one more runs when it lands.
        var needsRedraw = false
        /// Compiled once per display change; appends reuse it ten times a second.
        var filter = LogLineFilter(text: "", isRegex: false, minimumLevel: .other)

        init(jumpID: Int) { self.jumpID = jumpID }
    }

    /// Hands values built off the main thread back to it; each is created there and only read afterwards.
    struct Handoff<Value>: @unchecked Sendable { let value: Value }

    /// A tab shown again gets a new coordinator; a jump asked for earlier must not run again then.
    func makeCoordinator() -> Coordinator { Coordinator(jumpID: model.jumpRequest?.id ?? 0) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.isRichText = false
            textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular)
            textView.textContainerInset = NSSize(width: 6, height: 6)
            // TextKit 1 for temporary-attribute highlighting; lay out only what is visible.
            textView.layoutManager?.allowsNonContiguousLayout = true
            context.coordinator.textView = textView
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        let state = context.coordinator
        // Read on every pass: SwiftUI only calls back for properties the last pass read, and while a redraw is
        // pending nothing below reads them, so new lines and searches would stop updating the view.
        _ = (model.buffer.endIndex, model.search)
        if state.wrap != model.wrapLines {
            applyWrap(model.wrapLines, to: textView, scroll: scroll)
            state.wrap = model.wrapLines
        }
        if state.resetToken != model.resetToken || state.display != model.display {
            state.resetToken = model.resetToken
            if state.display != model.display { state.filter = model.display.lineFilter }
            state.display = model.display
            redraw(state)
        } else if !state.redrawing {
            let atBottom = isAtBottom(scroll, textView)
            appendNew(state)
            refreshSearch(state)
            if atBottom { textView.scrollToEndOfDocument(nil) }
        }
        if let request = model.jumpRequest, request.id != state.jumpID {
            state.jumpID = request.id
            jump(state, forward: request.forward)
        }
    }

    private func isAtBottom(_ scroll: NSScrollView, _ textView: NSTextView) -> Bool {
        scroll.contentView.bounds.maxY >= textView.bounds.maxY - 40
    }

    /// Rebuilds all text off the main thread. Requests arriving meanwhile collapse into one more redraw, so a fast
    /// stream that keeps dropping old lines cannot pile up renders that would all be thrown away.
    private func redraw(_ state: Coordinator) {
        guard !state.redrawing else { return state.needsRedraw = true }
        guard let textView = state.textView, let font = textView.font, let scroll = textView.enclosingScrollView else { return }
        state.redrawGeneration += 1
        state.redrawing = true
        let generation = state.redrawGeneration
        let atBottom = isAtBottom(scroll, textView)
        let entries = model.buffer.entries, end = model.buffer.endIndex
        let pods = model.podNames, display = model.display, filter = state.filter, fontHandoff = Handoff(value: font)
        Task { @MainActor in
            let built = await Task.detached(priority: .userInitiated) {
                let render = LogRenderer.render(entries, pods: pods, options: display, filter: filter)
                return Handoff(value: (render.lines, LogRenderer.attributed(render, font: fontHandoff.value)))
            }.value
            guard generation == state.redrawGeneration, let textView = state.textView else { return }
            if state.needsRedraw {
                state.needsRedraw = false
                state.redrawing = false
                return redraw(state)
            }
            textView.textStorage?.setAttributedString(built.value.1)
            state.lines = built.value.0
            state.renderedEnd = end
            state.redrawing = false
            state.matches = 0
            state.search = ""
            appendNew(state)
            refreshSearch(state)
            if atBottom { textView.scrollToEndOfDocument(nil) }
        }
    }

    /// Renders and appends lines received since the last update.
    private func appendNew(_ state: Coordinator) {
        guard let storage = state.textView?.textStorage, model.buffer.endIndex > state.renderedEnd,
              let entries = model.buffer.entries(from: state.renderedEnd), let font = state.textView?.font else { return }
        state.renderedEnd = model.buffer.endIndex
        let seam = storage.length
        let render = LogRenderer.render(entries, pods: model.podNames, options: model.display, filter: state.filter, leadingNewline: seam > 0)
        guard !render.text.isEmpty else { return }
        storage.append(LogRenderer.attributed(render, font: font))
        state.lines += render.lines.map { line in
            RenderedLine(range: NSRange(location: line.range.location + seam, length: line.range.length), level: line.level,
                         source: line.source, podRange: line.podRange.map { NSRange(location: $0.location + seam, length: $0.length) },
                         startsEntry: line.startsEntry)
        }
        // Back up by the query length so a match spanning the seam is found.
        if !model.search.isEmpty, state.search == model.search {
            state.matches += highlight(model.search, in: state, from: max(0, seam - model.search.utf16.count), countingAfter: seam)
            publishMatchCount(state)
        }
    }

    /// Highlights everything again when the query changed (or after a redraw).
    private func refreshSearch(_ state: Coordinator) {
        guard state.search != model.search, let textView = state.textView, let storage = textView.textStorage else { return }
        state.search = model.search
        state.matches = 0
        textView.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
        if !model.search.isEmpty { state.matches = highlight(model.search, in: state, from: 0, countingAfter: 0) }
        publishMatchCount(state)
    }

    private func publishMatchCount(_ state: Coordinator) {
        if matchCount != state.matches { DispatchQueue.main.async { matchCount = state.matches } }
    }

    /// Selects the next (or previous) error line after (before) the selection, wrapping around; beeps if none.
    private func jump(_ state: Coordinator, forward: Bool) {
        guard let textView = state.textView else { return }
        let errors = state.lines.filter { $0.level == .error && $0.startsEntry }
        let selection = textView.selectedRange()
        let target: RenderedLine?
        if forward {
            let after = NSMaxRange(selection)
            target = errors.first { $0.range.location >= after } ?? errors.first
        } else {
            target = errors.last { $0.range.location < selection.location } ?? errors.last
        }
        guard let target else { return NSSound.beep() }
        textView.setSelectedRange(target.range)
        textView.scrollRangeToVisible(target.range)
        textView.showFindIndicator(for: target.range)
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
    private func highlight(_ search: String, in state: Coordinator, from start: Int, countingAfter countedUpTo: Int) -> Int {
        guard let layout = state.textView?.layoutManager, let storage = state.textView?.textStorage else { return 0 }
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
