import Foundation

/// One line of a watch stream.
public enum WatchEvent<Object: Sendable>: Sendable {
    case added(Object)
    case modified(Object)
    case deleted(Object)
    /// Progress marker: nothing changed up to this resource version.
    case bookmark(resourceVersion: String)
    /// The server ended the watch with a Status; 410 means the resource version is too old and a relist is needed.
    case error(KubeAPIError)
}

public enum WatchEventError: Error, LocalizedError, Sendable {
    case malformed(String)

    public var errorDescription: String? {
        if case let .malformed(reason) = self { return "Malformed watch event: \(reason)" }
        return nil
    }
}

enum WatchEventParser {
    /// Parses a `{"type": ..., "object": ...}` line into raw JSON events.
    static func parse(_ line: String, omittingKeys: Set<String> = []) throws -> WatchEvent<JSONValue> {
        let json: JSONValue
        do {
            json = try JSONValue.parse(Data(line.utf8), omittingKeys: omittingKeys)
        } catch {
            throw WatchEventError.malformed("not JSON")
        }
        guard let type = json["type"]?.stringValue, let object = json["object"] else {
            throw WatchEventError.malformed("missing type or object")
        }
        switch type {
        case "ADDED": return .added(object)
        case "MODIFIED": return .modified(object)
        case "DELETED": return .deleted(object)
        case "BOOKMARK":
            return .bookmark(resourceVersion: object[path: "metadata", "resourceVersion"]?.stringValue ?? "")
        case "ERROR":
            let code = Int(object["code"]?.intValue ?? 500)
            return .error(KubeAPIError(statusCode: code, body: (try? JSONValue.encoder().encode(object)) ?? Data()))
        default:
            throw WatchEventError.malformed("unknown type \(type)")
        }
    }
}
