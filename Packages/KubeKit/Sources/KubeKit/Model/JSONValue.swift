import Foundation

/// Arbitrary JSON as a Sendable value. Integers and doubles are kept apart so numbers round-trip unchanged.
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Encoder for request bodies. Slashes stay unescaped: server-side apply parses bodies as YAML, which
    /// rejects JSON's optional `\/` escape.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case let .object(object) = self { return object[key] }
        return nil
    }

    /// Follows a path of object keys, e.g. `value[path: "metadata", "name"]`.
    public subscript(path keys: String...) -> JSONValue? {
        keys.reduce(Optional(self)) { $0?[$1] }
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var intValue: Int64? {
        switch self {
        case let .int(value): value
        case let .double(value) where value.rounded() == value: Int64(exactly: value)
        default: nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    /// Display text for table cells: strings as-is, numbers without trailing `.0`, null as empty.
    public var displayText: String {
        switch self {
        case .null: ""
        case let .bool(value): value ? "true" : "false"
        case let .int(value): String(value)
        case let .double(value): value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        case let .string(value): value
        case .array, .object: (try? String(decoding: Self.encoder().encode(self), as: UTF8.self)) ?? ""
        }
    }
}
