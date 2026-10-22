import Foundation
import Testing
@testable import KubeKit

struct LogAndApplyParsingTests {
    @Test func logLinesSplitTimestamp() {
        let line = LogLine.parse("2026-10-20T06:00:00.123456789Z hello world")
        #expect(line.timestamp == "2026-10-20T06:00:00.123456789Z")
        #expect(line.text == "hello world")
        #expect(KubeTimestamp.parse(line.timestamp!) != nil)
        #expect(LogLine.parse("plain text line").timestamp == nil)
        #expect(LogLine.parse("").text == "")
    }

    @Test func logQueryUsesTailFirstAndSinceTimeOnResume() {
        let first = LogStreamer.query(LogOptions(container: "app", tailLines: 50), sinceTime: nil)
        #expect(first.contains(URLQueryItem(name: "tailLines", value: "50")))
        #expect(first.contains(URLQueryItem(name: "follow", value: "true")))
        let resumed = LogStreamer.query(LogOptions(tailLines: 50), sinceTime: "2026-10-20T06:00:00Z")
        #expect(resumed.contains(URLQueryItem(name: "sinceTime", value: "2026-10-20T06:00:00Z")))
        #expect(!resumed.contains { $0.name == "tailLines" })
        let windowed = LogStreamer.query(LogOptions(tailLines: 100, sinceSeconds: 300), sinceTime: nil)
        #expect(windowed.contains(URLQueryItem(name: "sinceSeconds", value: "300")))
        #expect(windowed.contains(URLQueryItem(name: "tailLines", value: "100")))
        let resumedWindow = LogStreamer.query(LogOptions(sinceSeconds: 300), sinceTime: "2026-10-20T06:00:00Z")
        #expect(!resumedWindow.contains { $0.name == "sinceSeconds" })
        let previous = LogStreamer.query(LogOptions(previous: true), sinceTime: nil)
        #expect(!previous.contains { $0.name == "follow" })
    }

    @Test func applyBodyDropsServerManagedFields() throws {
        let yaml = """
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: web
          resourceVersion: "42"
          uid: abc
          managedFields: []
          labels: {app: web}
        spec: {replicas: 3}
        status: {readyReplicas: 1}
        """
        let prepared = ResourceApplier.prepared(try ResourceApplier.manifest(fromYAML: yaml))
        #expect(prepared["status"] == nil)
        #expect(prepared[path: "metadata", "resourceVersion"] == nil)
        #expect(prepared[path: "metadata", "uid"] == nil)
        #expect(prepared[path: "metadata", "labels", "app"] == .string("web"))
        #expect(prepared[path: "spec", "replicas"] == .int(3))
        #expect(throws: ApplyError.self) { try ResourceApplier.manifest(fromYAML: "a: [unclosed") }
    }

    @Test func resumeFilterSkipsOnlyRepeatedLines() {
        func line(_ ts: String, _ text: String) -> LogLine { LogLine(timestamp: "2026-10-20T06:00:\(ts)Z", text: text) }
        var filter = LogStreamer.ResumeFilter()
        // Out-of-order stdout/stderr timestamps are kept on a live stream.
        let live = [line("01.5", "a"), line("01.4", "stderr"), line("02.0", "b")].map { filter.accept($0) }
        #expect(live == [true, true, true])
        // After a reconnect the server resends from 06:00:02; already-shown lines are skipped.
        filter.begin()
        let resumed = [line("01.9", "old"), line("02.0", "b"), line("02.0", "c"), line("03.0", "d"), line("02.5", "late")]
            .map { filter.accept($0) }
        #expect(resumed == [false, false, true, true, true])
    }

    @Test func handTypedDatesAndBinaryDoNotCrash() throws {
        let manifest = try ResourceApplier.manifest(fromYAML: "data:\n  release: 2026-10-20\n")
        #expect(manifest[path: "data", "release"] == .string("2026-10-20"))
        #expect(throws: ApplyError.self) { try ResourceApplier.manifest(fromYAML: "a: .nan\n") }
        #expect(throws: ApplyError.self) { try ResourceApplier.manifest(fromYAML: "a: !!binary aGk=\n") }
    }

    @Test func conflictCausesAreDecoded() {
        let body = #"{"kind":"Status","code":409,"reason":"Conflict","message":"Apply failed with 1 conflict","details":{"causes":[{"reason":"FieldManagerConflict","message":"conflict with \"kubectl-create\"","field":".spec.replicas"}]}}"#
        let error = KubeAPIError(statusCode: 409, body: Data(body.utf8))
        #expect(error.causes == [KubeAPIError.Cause(field: ".spec.replicas", message: #"conflict with "kubectl-create""#)])
    }
}
