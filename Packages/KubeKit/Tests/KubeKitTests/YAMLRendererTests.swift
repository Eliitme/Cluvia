import Foundation
import Testing
import Yams
@testable import KubeKit

struct YAMLRendererTests {
    @Test func manifestOrderAndRoundTrip() throws {
        let pod = try KindFixture.json("pod.json")
        let yaml = try YAMLRenderer.yaml(pod)
        let lines = yaml.split(separator: "\n").filter { !$0.hasPrefix(" ") }.map { String($0.prefix { $0 != ":" }) }
        #expect(Array(lines.prefix(4)) == ["apiVersion", "kind", "metadata", "spec"])
        #expect(lines.last == "status")
        #expect(yaml.contains("\n  name: "))

        // Parsing the YAML back yields the same JSON (types preserved).
        let reparsed = try #require(try Yams.load(yaml: yaml))
        let json = try JSONSerialization.data(withJSONObject: reparsed)
        #expect(try JSONValue.parse(json) == pod)
    }

    @Test func ambiguousStringsStayStrings() throws {
        let value = JSONValue.object([
            "on": .string("x"), "123": .string("y"), "null": .string("z"),
            "a": .string("true"), "b": .string("1"), "c": .string("null"), "d": .string("line1\nline2"),
            "e": .int(1), "f": .bool(true), "g": .null, "h": .double(1.5),
        ])
        let yaml = try YAMLRenderer.yaml(value)
        #expect(yaml.contains("a: 'true'"))
        #expect(yaml.contains("b: '1'"))
        #expect(yaml.contains("d: |-"))
        let reparsed = try JSONValue.parse(try JSONSerialization.data(withJSONObject: try #require(try Yams.load(yaml: yaml))))
        #expect(reparsed == value)
    }
}
