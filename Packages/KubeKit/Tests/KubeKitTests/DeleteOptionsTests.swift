import Foundation
import Testing
@testable import KubeKit

struct DeleteOptionsTests {
    @Test func plainDeleteKeepsItsBody() throws {
        #expect(try DynamicClient.deleteOptionsBody(propagation: nil, gracePeriod: nil, uid: nil) == nil)
        let body = try #require(try DynamicClient.deleteOptionsBody(propagation: .background, gracePeriod: nil, uid: nil))
        #expect(String(decoding: body, as: UTF8.self) == #"{"kind":"DeleteOptions","apiVersion":"v1","propagationPolicy":"Background"}"#)
    }

    @Test func forceDeleteCarriesGraceAndUIDPrecondition() throws {
        let body = try #require(try DynamicClient.deleteOptionsBody(propagation: .background, gracePeriod: 0, uid: "u1"))
        let expected = #"""
        {"kind":"DeleteOptions","apiVersion":"v1","propagationPolicy":"Background","gracePeriodSeconds":0,"preconditions":{"uid":"u1"}}
        """#
        #expect(try Unstructured(data: body) == Unstructured(data: Data(expected.utf8)))
    }

    @Test func finalizerRemovalIsPinnedToUID() throws {
        let patch = try JSONDecoder().decode(JSONValue.self, from: DynamicClient.finalizerRemovalPatch(uid: "u1"))
        #expect(patch == .array([
            .object(["op": .string("test"), "path": .string("/metadata/uid"), "value": .string("u1")]),
            .object(["op": .string("remove"), "path": .string("/metadata/finalizers")]),
        ]))
    }

    @Test func preconditionWithoutPropagationOmitsPolicy() throws {
        let body = try #require(try DynamicClient.deleteOptionsBody(propagation: nil, gracePeriod: nil, uid: "u1"))
        let options = try Unstructured(data: body).json
        #expect(options["propagationPolicy"] == nil)
        #expect(options[path: "preconditions", "uid"] == .string("u1"))
    }
}
