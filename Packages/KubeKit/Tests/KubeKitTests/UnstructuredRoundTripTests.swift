import Foundation
import Testing
@testable import KubeKit

enum KindFixture {
    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/kind/\(name)"))
    }

    static func json(_ name: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data(name))
    }

    static func lines(_ name: String) throws -> [String] {
        String(decoding: try data(name), as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

struct UnstructuredRoundTripTests {
    @Test func realPodRoundTripsWithoutLoss() throws {
        let original = try KindFixture.data("pod.json")
        let pod = try Unstructured(data: original)
        let reencoded = try Unstructured(data: try pod.data())
        #expect(reencoded == pod)
        // Same content as Foundation's own parse (numbers, nesting, booleans all preserved).
        let expected = try JSONSerialization.jsonObject(with: original) as? NSDictionary
        let actual = try JSONSerialization.jsonObject(with: try pod.data()) as? NSDictionary
        #expect(expected == actual)
    }

    @Test func metadataAccessors() throws {
        let pod = try Unstructured(data: try KindFixture.data("pod.json"))
        #expect(pod.kind == "Pod")
        #expect(pod.apiVersion == "v1")
        #expect(pod.namespace == "kube-system")
        #expect(!pod.name.isEmpty)
        #expect(pod.key == ObjectKey(namespace: "kube-system", name: pod.name))
        #expect(pod.uid != nil && pod.resourceVersion != nil)
        #expect(pod.creationTimestamp != nil)
        #expect(!pod.labels.isEmpty || !pod.ownerReferences.isEmpty)
    }

    @Test func numbersKeepIntegerVersusDouble() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"a":3,"b":2.5,"c":9007199254740993,"d":true}"#.utf8))
        #expect(value["a"] == .int(3))
        #expect(value["b"] == .double(2.5))
        #expect(value["c"] == .int(9_007_199_254_740_993))
        #expect(value["d"] == .bool(true))
        #expect(JSONValue.int(3).displayText == "3")
        #expect(JSONValue.double(3).displayText == "3")
        #expect(JSONValue.null.displayText == "")
    }

    @Test func plainListFallsBackToNameAndAgeColumns() throws {
        let pod = try KindFixture.json("pod.json")
        let table = ResourceTable(.object(["kind": .string("PodList"), "items": .array([pod]),
                                           "metadata": .object(["resourceVersion": .string("42")])]))
        #expect(table.columns.map(\.name) == ["Name", "Age"])
        #expect(table.rows.count == 1)
        #expect(table.rows.first?.cells.first?.stringValue == pod[path: "metadata", "name"]?.stringValue)
        #expect(table.rows.first?.object.json[path: "metadata", "managedFields"] == nil)
        #expect(table.resourceVersion == "42")
        // A plain object in a watch event becomes a single row.
        #expect(ResourceTable(pod).rows.first?.id.name == pod[path: "metadata", "name"]?.stringValue)
    }

    @Test func unsignedAboveInt64KeepsSign() throws {
        let value = try JSONValue.parse(Data("[18446744073709551615]".utf8))
        guard case let .double(number)? = value.arrayValue?.first else { return #expect(Bool(false)) }
        #expect(number > 0)
    }

    @Test func encodedBodiesKeepSlashesUnescaped() throws {
        let object = Unstructured(.object(["apiVersion": .string("apps/v1")]))
        #expect(String(decoding: try object.data(), as: UTF8.self) == #"{"apiVersion":"apps/v1"}"#)
    }

    @Test func gvrPaths() {
        #expect(GroupVersionResource.pods.path(namespace: "ns", name: "p", subresource: "log") == "/api/v1/namespaces/ns/pods/p/log")
        let deployments = GroupVersionResource(group: "apps", version: "v1", resource: "deployments")
        #expect(deployments.path() == "/apis/apps/v1/deployments")
        #expect(deployments.path(namespace: "") == "/apis/apps/v1/deployments")
        #expect(deployments.groupVersion == "apps/v1")
    }

    @Test func tableRowsCarryCellsAndMetadata() throws {
        let table = ResourceTable(try KindFixture.json("table-pods.json"))
        #expect(table.columns.first?.name == "Name")
        #expect(table.columns.contains { $0.name == "Status" })
        #expect(table.columns.contains { $0.priority > 0 })
        #expect(!table.rows.isEmpty)
        let row = try #require(table.rows.first)
        #expect(row.cells.count == table.columns.count)
        #expect(row.cells.first?.stringValue == row.object.name)
        #expect(row.object.namespace == "kube-system")
        #expect(table.resourceVersion != nil)
        #expect(table.rows.allSatisfy { $0.object.json[path: "metadata", "managedFields"] == nil })
    }
}
