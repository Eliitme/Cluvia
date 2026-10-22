import Foundation
import KubeKit
import Testing
@testable import Cluvia

struct LogFilterAndFormatTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let saigon = TimeZone(identifier: "Asia/Saigon")!

    static func entry(_ text: String, at timestamp: String? = "2026-10-20T06:00:00.123456789Z", source: Int = 0) -> LogEntry {
        LogEntry(LogLine(timestamp: timestamp, text: text), source: source)
    }

    static func lines(_ render: LogRender) -> [String] {
        render.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    @Test func localTimeKeepsTheLevelOfKlogErrors() {
        var options = LogDisplayOptions(showTimestamps: true, localTime: true, minimumLevel: .error)
        let render = LogRenderer.render([Self.entry("E1020 06:00:00.000 1 x.go:1] sync failed"), Self.entry("all good")],
                                        pods: nil, options: options, timeZone: Self.saigon)
        #expect(Self.lines(render) == ["2026-10-20 13:00:00.123 E1020 06:00:00.000 1 x.go:1] sync failed"])
        #expect(render.lines.map(\.level) == [.error])
        options.localTime = false
        #expect(LogRenderer.render([Self.entry("x")], pods: nil, options: options).lines.isEmpty)
    }

    @Test func prettyJSONRepeatsPodPrefixAndSharesTheLevel() {
        let options = LogDisplayOptions(prettyJSON: true)
        let render = LogRenderer.render([Self.entry(#"{"level" : "error","msg":"boom"}"#, source: 1)], pods: ["web-a", "web-b"], options: options)
        let shown = Self.lines(render)
        #expect(shown.count == 4)
        #expect(shown.allSatisfy { $0.hasPrefix("web-b │ ") })
        #expect(shown[1] == #"web-b │   "level" : "error","#)
        #expect(render.lines.allSatisfy { $0.level == .error && $0.source == 1 })
        #expect(render.lines.map(\.startsEntry) == [true, false, false, false])
        let pod = (render.text as NSString).substring(with: render.lines[2].podRange!)
        #expect(pod == "web-b")
    }

    @Test func localTimeAlwaysShowsMilliseconds() {
        var clock = LocalClock(timeZone: Self.utc)
        #expect(clock.format("2026-10-20T06:00:00Z") == "2026-10-20 06:00:00.000")
        #expect(clock.format("2026-10-20T06:00:00.5Z") == "2026-10-20 06:00:00.500")
        #expect(clock.format("2026-10-20T06:00:01.123456789Z") == "2026-10-20 06:00:01.123")
        #expect(clock.format("2026-10-20T06:00:00+07:00") == nil)
    }

    @Test func nonJSONIsLeftAlone() {
        #expect(LogRenderer.bodies(of: "{oops", pretty: true) == ["{oops"])
        #expect(LogRenderer.bodies(of: #"["array"]"#, pretty: true) == [#"["array"]"#])
        #expect(LogRenderer.bodies(of: #"  {"a":1}"#, pretty: true).count == 3)
    }

    @Test func filterBySubstringRegexAndLevel() {
        let entries = ["Connection REFUSED", "request timeout", "ok", "level=warn slow"].map { Self.entry($0) }
        func shown(_ options: LogDisplayOptions) -> [String] { Self.lines(LogRenderer.render(entries, pods: nil, options: options)) }
        #expect(shown(LogDisplayOptions(filter: "refused")) == ["Connection REFUSED"])
        #expect(shown(LogDisplayOptions(filter: "timeout|refused", filterIsRegex: true)) == ["Connection REFUSED", "request timeout"])
        #expect(shown(LogDisplayOptions(minimumLevel: .warning)) == ["level=warn slow"])
        let invalid = LogDisplayOptions(filter: "(", filterIsRegex: true)
        #expect(!invalid.lineFilter.isValid)
        #expect(shown(invalid).count == 4)
    }

    @Test func filterMatchesThePodName() {
        let render = LogRenderer.render([Self.entry("a", source: 0), Self.entry("b", source: 1)], pods: ["api", "worker"],
                                        options: LogDisplayOptions(filter: "work"))
        #expect(Self.lines(render) == ["worker │ b"])
    }

    @Test func appendedChunkStartsOnANewLine() {
        let render = LogRenderer.render([Self.entry("next")], pods: nil, options: LogDisplayOptions(), leadingNewline: true)
        #expect(render.text == "\nnext")
        #expect(render.lines.first?.range == NSRange(location: 1, length: 4))
    }

    /// Choosing a time window lifts the line limit with a single restart.
    @MainActor @Test func sinceClearsTheLineLimit() throws {
        let client = DynamicClient(transport: try KubeTransport(
            serverURL: URL(string: "https://127.0.0.1:1")!, trust: TrustPolicy(), credentials: StaticCredentialProvider(user: AuthInfo())
        ))
        let pod = Unstructured(.object(["metadata": .object(["name": .string("p"), "namespace": .string("d")]),
                                        "spec": .object(["containers": .array([.object(["name": .string("c")])])])]))
        let model = LogViewModel(client: client, pod: pod)
        defer { model.stop() }
        let before = model.resetToken
        model.sinceSeconds = 300
        #expect(model.tailLines == nil)
        #expect(model.resetToken == before + 1)
        model.sinceSeconds = nil
        #expect(model.tailLines == 1000)
        #expect(model.resetToken == before + 2)
    }
}
