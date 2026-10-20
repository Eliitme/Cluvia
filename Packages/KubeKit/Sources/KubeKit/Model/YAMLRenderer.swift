import Foundation
import Yams

/// Renders objects as YAML in the conventional manifest order (apiVersion, kind, metadata, spec, ..., status)
/// rather than JSON dictionary order, and with types preserved: strings that look like numbers, booleans or
/// timestamps are quoted so the YAML parses back to the same JSON.
public enum YAMLRenderer {
    static let topLevelOrder = ["apiVersion", "kind", "metadata", "spec", "data", "stringData", "type", "status"]
    static let metadataOrder = [
        "name", "generateName", "namespace", "uid", "resourceVersion", "generation", "creationTimestamp",
        "deletionTimestamp", "labels", "annotations", "ownerReferences", "finalizers", "managedFields",
    ]

    public static func yaml(_ value: JSONValue) throws -> String {
        try Yams.serialize(node: node(value, path: []), width: -1)
    }

    static func node(_ value: JSONValue, path: [String]) -> Node {
        switch value {
        case .null:
            return Node("null", Tag(.null))
        case let .bool(flag):
            return Node(flag ? "true" : "false", Tag(.bool))
        case let .int(number):
            return Node(String(number), Tag(.int))
        case let .double(number):
            return number.box()
        case let .string(text):
            if text.contains("\n") { return .scalar(Node.Scalar(text, Tag(.str), .literal)) }
            return .scalar(text.represented())
        case let .array(items):
            return .sequence(Node.Sequence(items.map { node($0, path: path) }))
        case let .object(fields):
            let pairs = orderedKeys(fields.keys, path: path).map { key in
                // Keys like "on", "123" or "null" must stay strings when parsed back.
                (Node.scalar(key.represented()), node(fields[key]!, path: path + [key]))
            }
            return .mapping(Node.Mapping(pairs))
        }
    }

    static func orderedKeys(_ keys: Dictionary<String, JSONValue>.Keys, path: [String]) -> [String] {
        let preferred = path.isEmpty ? topLevelOrder : (path == ["metadata"] ? metadataOrder : [])
        let first = preferred.filter(keys.contains)
        return first + keys.filter { !preferred.contains($0) }.sorted()
    }
}
