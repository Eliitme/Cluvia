import Foundation
import Testing
@testable import KubeKit

struct OwnedObjectsTests {
    static func object(_ json: String) throws -> Unstructured { try Unstructured(data: Data(json.utf8)) }

    @Test func selectorUsesMatchLabelsOnly() throws {
        let labels = try Self.object(#"{"spec":{"selector":{"matchLabels":{"tier":"fe","app":"web"}}}}"#)
        #expect(OwnedObjects.labelSelector(of: labels) == "app=web,tier=fe")
        let expressions = try Self.object(#"""
        {"spec":{"selector":{"matchLabels":{"app":"web"},"matchExpressions":[{"key":"env","operator":"In","values":["a"]}]}}}
        """#)
        #expect(OwnedObjects.labelSelector(of: expressions) == nil)
        #expect(OwnedObjects.labelSelector(of: try Self.object(#"{"spec":{}}"#)) == nil)
    }

    @Test func ownedMatchesUIDNotName() throws {
        let mine = try Self.object(#"{"metadata":{"name":"b","ownerReferences":[{"kind":"Deployment","name":"web","uid":"u1"}]}}"#)
        let older = try Self.object(#"{"metadata":{"name":"a","ownerReferences":[{"kind":"Deployment","name":"web","uid":"u0"}]}}"#)
        let first = try Self.object(#"{"metadata":{"name":"a2","ownerReferences":[{"kind":"Deployment","name":"web","uid":"u1"}]}}"#)
        #expect(OwnedObjects.owned([mine, older, first], by: "u1").map(\.name) == ["a2", "b"])
    }
}
