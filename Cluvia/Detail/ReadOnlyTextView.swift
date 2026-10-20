import AppKit
import SwiftUI

/// Selectable, non-editable monospaced text backed by `NSTextView`, which lays out large documents lazily
/// (a SwiftUI `Text` measures the whole string up front).
struct ReadOnlyTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        // No wrapping: YAML indentation must stay readable; scroll horizontally instead.
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.hasHorizontalScroller = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }
}
