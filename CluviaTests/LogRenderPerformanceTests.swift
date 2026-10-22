import AppKit
import KubeKit
import Testing
@testable import Cluvia

/// A full redraw of a full buffer, built off the main thread, with every display option on.
struct LogRenderPerformanceTests {
    @Test func fullBufferRedrawStaysWithinBudget() {
        let entries = (0..<LogBuffer.defaultCapacity).map { index in
            let text = index % 10 == 0
                ? #"{"level":"error","msg":"request \#(index) failed","path":"/api/v1/items"}"#
                : "level=info msg=\"request \(index) served\" status=200 duration=12ms"
            return LogEntry(LogLine(timestamp: "2026-10-20T06:00:00.123456789Z", text: text), source: index % 3)
        }
        let options = LogDisplayOptions(showTimestamps: true, localTime: true, prettyJSON: true, filter: "request \\d+ (failed|served)",
                                        filterIsRegex: true)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let clock = ContinuousClock()
        var render = LogRender()
        let renderTime = clock.measure { render = LogRenderer.render(entries, pods: ["a", "b", "c"], options: options) }
        let attributeTime = clock.measure { _ = LogRenderer.attributed(render, font: font) }
        // Debug build, unoptimized: a generous ceiling that still catches an accidental quadratic step.
        #expect(renderTime + attributeTime < .seconds(3), "render \(renderTime), attributes \(attributeTime)")
    }

    /// The part of a redraw that stays on the main thread: handing the prebuilt text to the view.
    @MainActor @Test func applyingAPrebuiltRedrawIsQuick() {
        let entries = (0..<LogBuffer.defaultCapacity).map { index in
            LogEntry(LogLine(timestamp: nil, text: index % 10 == 0 ? "level=error request \(index) failed" : "request \(index) served"),
                     source: index % 3)
        }
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let built = LogRenderer.attributed(LogRenderer.render(entries, pods: ["a", "b", "c"], options: LogDisplayOptions()), font: font)
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.layoutManager?.allowsNonContiguousLayout = true
        let time = ContinuousClock().measure {
            textView.textStorage?.setAttributedString(built)
            textView.scrollToEndOfDocument(nil)
        }
        #expect(time < .milliseconds(500), "main-thread apply \(time)")
    }
}
