import Foundation
import KubeKit
import Testing
@testable import Cluvia

struct SecretDataCodecTests {
    static func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    static func secret(_ data: [String: String], annotations: [String: String] = [:]) -> JSONValue {
        var metadata: [String: JSONValue] = ["name": .string("s"), "namespace": .string("default")]
        if !annotations.isEmpty { metadata["annotations"] = .object(annotations.mapValues(JSONValue.string)) }
        return .object([
            "apiVersion": .string("v1"), "kind": .string("Secret"), "metadata": .object(metadata),
            "type": .string("Opaque"), "data": .object(data.mapValues(JSONValue.string)),
        ])
    }

    /// Decode, render to editor text, parse it back unchanged and encode: what Apply does with no edits.
    static func roundTrip(_ json: JSONValue) throws -> (JSONValue, SecretEditState) {
        let (editable, state) = try #require(try SecretDataCodec.decode(json))
        let text = try YAMLRenderer.yaml(editable)
        return (try SecretDataCodec.encode(ResourceApplier.manifest(fromYAML: text), state: state), state)
    }

    @Test func textIsDecodedAndUnchangedValuesComeBackAsStored() throws {
        let tricky = ["plain": "hello", "crlf": "a\r\nb", "trailing": "a\n\n", "lead": "  lead", "tab": "\tx",
                      "control": "x\u{1}y", "number": "123", "yes": "yes", "multi": "line1\nline2\n"]
        var data = tricky.mapValues(Self.b64)
        data["binary"] = "/w=="
        let (encoded, state) = try Self.roundTrip(Self.secret(data))
        #expect(encoded["data"] == .object(data.mapValues(JSONValue.string)))
        #expect(state.base64Keys.contains("binary"))
        #expect(!state.base64Keys.contains("plain"))
        #expect(!state.base64Keys.contains("number"))
    }

    @Test func editingOneKeyLeavesOthersByteIdentical() throws {
        let data = ["a": Self.b64("one"), "crlf": Self.b64("x\r\ny"), "bin": "/w=="]
        let (editable, state) = try #require(try SecretDataCodec.decode(Self.secret(data)))
        #expect(editable[path: "data", "a"] == .string("one"))
        let text = try YAMLRenderer.yaml(editable).replacingOccurrences(of: "a: one", with: "a: two")
        let encoded = try SecretDataCodec.encode(ResourceApplier.manifest(fromYAML: text), state: state)
        #expect(encoded[path: "data", "a"] == .string(Self.b64("two")))
        #expect(encoded[path: "data", "crlf"] == .string(data["crlf"]!))
        #expect(encoded[path: "data", "bin"] == .string("/w=="))
    }

    @Test func newRemovedAndStringDataKeys() throws {
        var json = Self.secret(["keep": Self.b64("k"), "drop": Self.b64("d")])
        if case var .object(fields) = json { fields["stringData"] = .object(["plain": .string("as-is")]); json = .object(fields) }
        let (editable, state) = try #require(try SecretDataCodec.decode(json))
        var text = try YAMLRenderer.yaml(editable)
        text = text.replacingOccurrences(of: "  drop: d\n", with: "  added: new\n")
        #expect(text.contains("added: new"))
        let encoded = try SecretDataCodec.encode(ResourceApplier.manifest(fromYAML: text), state: state)
        #expect(encoded["data"] == .object(["keep": .string(Self.b64("k")), "added": .string(Self.b64("new"))]))
        #expect(encoded[path: "stringData", "plain"] == .string("as-is"))
    }

    @Test func emptyOrNullDataPassesThrough() throws {
        for data in [JSONValue.object([:]), .null] {
            let json = JSONValue.object(["apiVersion": .string("v1"), "kind": .string("Secret"),
                                         "metadata": .object(["name": .string("s")]), "data": data])
            let (editable, state) = try #require(try SecretDataCodec.decode(json))
            #expect(try SecretDataCodec.encode(editable, state: state)["data"] == data)
        }
    }

    /// A dry run that changes nothing must show no difference: the server result, displayed like the editor text,
    /// renders exactly as the text the user started from.
    @Test func displayedServerResultMatchesTheEditorText() throws {
        let json = Self.secret(["a": Self.b64("x\r\ny"), "bin": "/w=="],
                               annotations: [SecretMasking.lastAppliedAnnotation: "{}", "team": "web"])
        let (editable, state) = try #require(try SecretDataCodec.decode(json))
        let original = try YAMLRenderer.yaml(editable)
        let server = try SecretDataCodec.encode(ResourceApplier.manifest(fromYAML: original), state: state)
        let withAnnotation = json[path: "metadata"].map { metadata -> JSONValue in
            guard case var .object(fields) = server else { return server }
            fields["metadata"] = metadata
            return .object(fields)
        } ?? server
        #expect(try YAMLRenderer.yaml(SecretDataCodec.displayed(withAnnotation, state: state)) == original)
    }

    @Test func unquotedNonStringIsRejectedWithItsKey() throws {
        let (editable, state) = try #require(try SecretDataCodec.decode(Self.secret(["port": Self.b64("8080")])))
        let text = try YAMLRenderer.yaml(editable).replacingOccurrences(of: "port: '8080'", with: "port: 9090")
            .replacingOccurrences(of: "port: \"8080\"", with: "port: 9090")
        #expect(text.contains("port: 9090"))
        #expect(throws: ApplyError.self) { try SecretDataCodec.encode(ResourceApplier.manifest(fromYAML: text), state: state) }
    }

    @Test func lastAppliedAnnotationIsLeftOutOfTheEditor() throws {
        let json = Self.secret(["a": Self.b64("x")], annotations: [SecretMasking.lastAppliedAnnotation: #"{"data":{"a":"b2xk"}}"#])
        let (editable, state) = try #require(try SecretDataCodec.decode(json))
        #expect(state.hadLastApplied)
        #expect(editable[path: "metadata", "annotations"] == nil)
        #expect(!(try YAMLRenderer.yaml(editable)).contains("b2xk"))
    }

    @Test func nonSecretsAndDisplayHelpers() throws {
        #expect(try SecretDataCodec.decode(.object(["apiVersion": .string("v1"), "kind": .string("ConfigMap")])) == nil)
        #expect(SecretMasking.decodedUTF8(.string("not base64!")) == nil)
        #expect(SecretMasking.decodedUTF8(.string("/w==")) == nil)
        #expect(SecretMasking.decoded(.string("/w==")) == "<1 bytes binary>")
        #expect(SecretMasking.decoded(.string(Self.b64("hi"))) == "hi")
    }
}
