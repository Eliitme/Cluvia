import Foundation
import KubeKit

/// What a Secret edit session needs to turn decoded text back into the exact stored base64.
struct SecretEditState: Equatable, Sendable {
    /// `data` as stored (base64), by key.
    var originalData: [String: String]
    /// Keys edited as base64: binary values, and text that would not survive the editor's YAML round trip unchanged
    /// (CRLF line breaks, some trailing newlines).
    var base64Keys: Set<String>
    /// The object carries client-side apply's annotation, which embeds every previous value in plain JSON.
    var hadLastApplied: Bool
}

/// Converts a Secret's `data` between stored base64 and editable text without changing any value the user did not edit.
enum SecretDataCodec {
    /// JSON patch removing the client-side apply annotation; apply alone would not drop a field another manager owns.
    static let lastAppliedRemovalPatch = Data(
        #"[{"op":"remove","path":"/metadata/annotations/kubectl.kubernetes.io~1last-applied-configuration"}]"#.utf8
    )

    static func isSecret(_ json: JSONValue) -> Bool {
        json["kind"]?.stringValue == "Secret" && json["apiVersion"]?.stringValue == "v1"
    }

    /// Editor JSON with text values decoded and the last-applied annotation left out; nil when `json` is not a Secret.
    static func decode(_ json: JSONValue) throws -> (json: JSONValue, state: SecretEditState)? {
        guard isSecret(json), case var .object(fields) = json else { return nil }
        let stored = fields["data"]?.objectValue ?? [:]
        var original: [String: String] = [:]
        var base64Keys = Set<String>()
        var editable: [String: JSONValue] = [:]
        for (key, value) in stored {
            if let encoded = value.stringValue { original[key] = encoded }
            if let text = SecretMasking.decodedUTF8(value) {
                editable[key] = .string(text)
            } else {
                base64Keys.insert(key)
                editable[key] = value
            }
        }
        if !editable.isEmpty {
            // Keep only values the editor's own render-and-parse reproduces exactly; the rest stay base64.
            fields["data"] = .object(editable)
            let reparsed = try ResourceApplier.manifest(fromYAML: YAMLRenderer.yaml(.object(fields)))
            for (key, value) in editable where !base64Keys.contains(key) && reparsed[path: "data", key] != value {
                base64Keys.insert(key)
                editable[key] = stored[key]
            }
            fields["data"] = .object(editable)
        }
        let hadLastApplied = removeLastApplied(from: &fields)
        return (.object(fields), SecretEditState(originalData: original, base64Keys: base64Keys, hadLastApplied: hadLastApplied))
    }

    /// Manifest to apply: unchanged values are sent exactly as stored, changed and new text values are re-encoded.
    static func encode(_ json: JSONValue, state: SecretEditState) throws -> JSONValue {
        guard case var .object(fields) = json, let data = fields["data"]?.objectValue else { return json }
        var encoded: [String: JSONValue] = [:]
        for (key, value) in data {
            guard let text = value.stringValue else {
                throw ApplyError.invalidYAML("data.\(key) must be a string; put it in quotes")
            }
            if state.base64Keys.contains(key) {
                encoded[key] = value
            } else if let stored = state.originalData[key], SecretMasking.decodedUTF8(.string(stored)) == text {
                encoded[key] = .string(stored)
            } else {
                encoded[key] = .string(Data(text.utf8).base64EncodedString())
            }
        }
        fields["data"] = .object(encoded)
        return .object(fields)
    }

    /// A server result shown the way the editor shows it, so a dry-run diff only lists real changes.
    static func displayed(_ json: JSONValue, state: SecretEditState) -> JSONValue {
        guard case var .object(fields) = json else { return json }
        if let data = fields["data"]?.objectValue {
            fields["data"] = .object(data.reduce(into: [:]) { result, entry in
                let text = state.base64Keys.contains(entry.key) ? nil : SecretMasking.decodedUTF8(entry.value)
                result[entry.key] = text.map(JSONValue.string) ?? entry.value
            })
        }
        removeLastApplied(from: &fields)
        return .object(fields)
    }

    @discardableResult
    private static func removeLastApplied(from fields: inout [String: JSONValue]) -> Bool {
        guard case var .object(metadata)? = fields["metadata"], case var .object(annotations)? = metadata["annotations"],
              annotations.removeValue(forKey: SecretMasking.lastAppliedAnnotation) != nil else { return false }
        metadata["annotations"] = annotations.isEmpty ? nil : .object(annotations)
        fields["metadata"] = .object(metadata)
        return true
    }
}
