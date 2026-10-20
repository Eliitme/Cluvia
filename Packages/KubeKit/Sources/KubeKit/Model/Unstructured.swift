import Foundation

/// Identity of an object inside one resource collection.
public struct ObjectKey: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let namespace: String?
    public let name: String

    public init(namespace: String?, name: String) {
        self.namespace = namespace.flatMap { $0.isEmpty ? nil : $0 }
        self.name = name
    }

    public var description: String { namespace.map { "\($0)/\(name)" } ?? name }

    public static func < (lhs: ObjectKey, rhs: ObjectKey) -> Bool {
        (lhs.namespace ?? "", lhs.name) < (rhs.namespace ?? "", rhs.name)
    }
}

/// Any Kubernetes object as JSON, with typed accessors for the common metadata fields.
public struct Unstructured: Sendable, Hashable, Codable {
    public var json: JSONValue

    public init(_ json: JSONValue) {
        self.json = json
    }

    public init(from decoder: Decoder) throws {
        json = try JSONValue(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try json.encode(to: encoder)
    }

    public init(data: Data) throws {
        json = try JSONValue.parse(data)
    }

    public func data() throws -> Data {
        try JSONValue.encoder().encode(json)
    }

    public var apiVersion: String? { json["apiVersion"]?.stringValue }
    public var kind: String? { json["kind"]?.stringValue }
    public var name: String { json[path: "metadata", "name"]?.stringValue ?? "" }
    public var namespace: String? { json[path: "metadata", "namespace"]?.stringValue }
    public var uid: String? { json[path: "metadata", "uid"]?.stringValue }
    public var resourceVersion: String? { json[path: "metadata", "resourceVersion"]?.stringValue }
    public var key: ObjectKey { ObjectKey(namespace: namespace, name: name) }

    public var labels: [String: String] { stringMap(json[path: "metadata", "labels"]) }
    public var annotations: [String: String] { stringMap(json[path: "metadata", "annotations"]) }

    public var creationTimestamp: Date? {
        json[path: "metadata", "creationTimestamp"]?.stringValue.flatMap(KubeTimestamp.parse)
    }

    public var ownerReferences: [OwnerReference] {
        (json[path: "metadata", "ownerReferences"]?.arrayValue ?? []).compactMap { ref in
            guard let kind = ref["kind"]?.stringValue, let name = ref["name"]?.stringValue else { return nil }
            return OwnerReference(
                apiVersion: ref["apiVersion"]?.stringValue ?? "", kind: kind, name: name,
                uid: ref["uid"]?.stringValue ?? "", controller: ref["controller"] == .bool(true)
            )
        }
    }

    private func stringMap(_ value: JSONValue?) -> [String: String] {
        (value?.objectValue ?? [:]).compactMapValues(\.stringValue)
    }
}

public struct OwnerReference: Sendable, Hashable {
    public let apiVersion: String
    public let kind: String
    public let name: String
    public let uid: String
    public let controller: Bool
}
