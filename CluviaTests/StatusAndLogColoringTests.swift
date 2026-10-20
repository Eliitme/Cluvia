import AppKit
import KubeKit
import Testing
@testable import Cluvia

@MainActor
@Suite struct StatusAndLogColoringTests {
    func colored(_ text: String) -> [NSColor?] {
        let storage = NSTextStorage(string: text)
        LogLevelColoring.apply(to: storage, text: text, from: 0)
        var colors: [NSColor?] = []
        (text as NSString).enumerateSubstrings(in: NSRange(location: 0, length: storage.length), options: .byLines) { _, range, _, _ in
            colors.append(storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor)
        }
        return colors
    }

    @Test func logLinesAreColoredBySeverityOnly() {
        let lines = [
            "13:40 level=error request failed",
            #"{"level":"WARN","msg":"slow"}"#,
            "E1020 12:00:00.000 1 controller.go:1] sync failed",
            "pod-a │ W1020 12:00:00.000 1 x.go:1] retrying",
            "level=info msg=\"done\" error=null",
            "completed without error",
            "[warn] disk almost full",
            "ERROR: cannot connect",
        ]
        #expect(colored(lines.joined(separator: "\n")) == [
            .systemRed, .systemOrange, .systemRed, .systemOrange, nil, nil, .systemOrange, .systemRed,
        ])
    }

    @Test func runningPodThatIsNotReadyIsNotGreen() throws {
        let pod = Unstructured(try JSONValue.parse(Data(#"""
        {"kind":"Pod","status":{"phase":"Running","containerStatuses":[{"ready":false,"state":{"running":{}}}]}}
        """#.utf8)))
        let summary = try #require(StatusSummary(pod))
        #expect(summary.text == "Running · 0/1 ready")
        #expect(summary.tone == .pending)
    }

    @Test func stuckInitContainerAndFailedJobReadAsProblems() throws {
        let pod = Unstructured(try JSONValue.parse(Data(#"""
        {"kind":"Pod","status":{"phase":"Pending","initContainerStatuses":[{"state":{"waiting":{"reason":"CrashLoopBackOff"}}}],
         "containerStatuses":[{"ready":false,"state":{"waiting":{"reason":"PodInitializing"}}}]}}
        """#.utf8)))
        #expect(try #require(StatusSummary(pod)).text == "Init:CrashLoopBackOff · 0/1 ready")
        #expect(try #require(StatusSummary(pod)).tone == .bad)
        let job = Unstructured(try JSONValue.parse(Data(#"""
        {"kind":"Job","spec":{"completions":1},"status":{"conditions":[{"type":"Failed","status":"True"}]}}
        """#.utf8)))
        #expect(try #require(StatusSummary(job)).tone == .bad)
    }
}
