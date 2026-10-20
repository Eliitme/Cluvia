import AppKit
import STTextView
import SwiftUI

/// Editable YAML backed by STTextView: line numbers, current-line highlight, no wrapping, syntax colors.
struct YamlEditorView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = STTextView.scrollableTextView()
        guard let textView = scroll.documentView as? STTextView else { return scroll }
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.showsLineNumbers = true
        textView.highlightSelectedLine = true
        textView.isHorizontallyResizable = true
        textView.text = text
        textView.textDelegate = context.coordinator
        context.coordinator.textView = textView
        context.coordinator.rehighlight()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scroll.documentView as? STTextView, textView.text != text else { return }
        textView.text = text
        context.coordinator.rehighlight()
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency STTextViewDelegate {
        var text: Binding<String>
        weak var textView: STTextView?
        private var pending: Task<Void, Never>?

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChangeText(_ notification: Notification) {
            guard let textView else { return }
            text.wrappedValue = textView.text ?? ""
            // Re-coloring the whole document on every keystroke is wasteful; wait for a typing pause.
            pending?.cancel()
            pending = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                self?.rehighlight()
            }
        }

        func rehighlight() {
            guard let textView, let string = textView.text else { return }
            let full = NSRange(location: 0, length: (string as NSString).length)
            textView.setAttributes([.foregroundColor: NSColor.textColor, .font: textView.font], range: full)
            for (range, color) in YamlHighlighter.spans(in: string) {
                textView.addAttributes([.foregroundColor: color], range: range)
            }
        }
    }
}
