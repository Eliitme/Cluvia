import Foundation
import Yams

public enum KubeConfigSection: String, Sendable, CaseIterable {
    case clusters, users, contexts

    /// Key holding the entry body next to `name`, e.g. `- name: x` / `cluster: {...}`.
    var bodyKey: String {
        switch self {
        case .clusters: "cluster"
        case .users: "user"
        case .contexts: "context"
        }
    }

    var singular: String { String(rawValue.dropLast()) }
}

public enum KubeConfigEditError: Error, LocalizedError, Sendable, Equatable {
    case malformed(path: String)
    case duplicateName(section: String, name: String)
    case notFound(section: String, name: String)
    case missingValue(String)
    case invalidValue(String)
    case changedOnDisk(path: String)
    case nameConflicts([String])
    case locked(path: String)
    case writeFailed(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .malformed(path): "\(path) is not a valid kubeconfig (malformed YAML, or more than one document)"
        case let .duplicateName(section, name): "A \(section) named \"\(name)\" already exists"
        case let .notFound(section, name): "No \(section) named \"\(name)\" in the kubeconfig files. Reload and try again."
        case let .missingValue(what): "\(what) is required"
        case let .invalidValue(what): what
        case let .changedOnDisk(path): "\(path) changed on disk since it was loaded. Reload and try again."
        case let .nameConflicts(names): "Already defined in the kubeconfig: \(names.joined(separator: ", "))"
        case let .locked(path): "Another program is editing the kubeconfig (\(path) exists). Try again shortly."
        case let .writeFailed(path, reason): "Cannot write \(path): \(reason)"
        }
    }
}

/// A kubeconfig file as an editable YAML tree. Edits only touch the keys they set, so fields the app does not
/// model (extensions, preferences, auth-provider settings) survive a save. Comments are not preserved.
public struct KubeConfigDocument {
    public let url: URL
    /// Bytes on disk when loaded (nil: file did not exist). Saving refuses to overwrite a file that changed since.
    public let original: Data?
    var root: Node.Mapping

    public static func load(_ url: URL) throws -> KubeConfigDocument {
        let path = url.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: path.path) else { return try KubeConfigDocument(url: url, text: "", original: nil) }
        let data = try Data(contentsOf: path)
        return try KubeConfigDocument(url: url, text: String(decoding: data, as: UTF8.self), original: data)
    }

    public init(url: URL, text: String, original: Data?) throws {
        self.url = url
        self.original = original
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            root = [Node("apiVersion"): .str("v1"), Node("kind"): .str("Config")]
            return
        }
        // Parser messages quote source lines, which may hold credentials; only the path is reported.
        guard let node = try? Yams.compose(yaml: text), let mapping = node.mapping else {
            throw KubeConfigEditError.malformed(path: url.path)
        }
        root = mapping
    }

    public var exists: Bool { original != nil }

    // MARK: Reading

    public func names(in section: KubeConfigSection) -> [String] {
        entries(section).compactMap { $0.mapping?["name"]?.string }
    }

    public var currentContext: String? {
        get { root["current-context"]?.string.flatMap { $0.isEmpty ? nil : $0 } }
        set { root["current-context"] = newValue.map { .str($0) } }
    }

    /// A scalar field of an entry body, e.g. `field(.clusters, "kind", "server")`.
    public func field(_ section: KubeConfigSection, _ name: String, _ key: String) -> String? {
        body(section, name)?[key]?.string
    }

    func entries(_ section: KubeConfigSection) -> [Node] {
        root[section.rawValue]?.sequence.map(Array.init) ?? []
    }

    func body(_ section: KubeConfigSection, _ name: String) -> Node.Mapping? {
        entries(section).first { $0.mapping?["name"]?.string == name }?.mapping?[section.bodyKey]?.mapping
    }

    // MARK: Writing

    /// Replaces (or appends) the entry's body, keeping its position in the list.
    mutating func setBody(_ section: KubeConfigSection, _ name: String, _ body: Node.Mapping) {
        var list = entries(section)
        if let index = list.firstIndex(where: { $0.mapping?["name"]?.string == name }) {
            var existing = list[index].mapping ?? [:]
            existing[section.bodyKey] = .mapping(body)
            list[index] = .mapping(existing)
        } else {
            list.append(.mapping([Node("name"): .str(name), Node(section.bodyKey): .mapping(body)]))
        }
        root[section.rawValue] = .sequence(Node.Sequence(list))
    }

    mutating func remove(_ section: KubeConfigSection, _ name: String) {
        let list = entries(section).filter { $0.mapping?["name"]?.string != name }
        root[section.rawValue] = .sequence(Node.Sequence(list))
    }

    mutating func rename(_ section: KubeConfigSection, from old: String, to new: String) throws {
        var list = entries(section)
        guard let index = list.firstIndex(where: { $0.mapping?["name"]?.string == old }), var entry = list[index].mapping else {
            throw KubeConfigEditError.notFound(section: section.singular, name: old)
        }
        entry["name"] = .str(new)
        list[index] = .mapping(entry)
        root[section.rawValue] = .sequence(Node.Sequence(list))
    }

    /// The document as YAML. Long base64 values stay on one line.
    public func serialized() throws -> String {
        try Yams.serialize(node: .mapping(root), width: -1, allowUnicode: true)
    }

    /// The file actually written (symlinks resolved).
    var target: URL { url.resolvingSymlinksInPath() }

    /// Serializes and validates the new content without touching the disk.
    func prepared() throws -> Data {
        let data = Data(try serialized().utf8)
        _ = try KubeConfigLoader.decode(data, path: url.path, baseDirectory: target.deletingLastPathComponent())
        return data
    }

    /// Fails unless the file still holds what was loaded. Call while holding the lock.
    func verifyUnchanged() throws {
        guard (try? Data(contentsOf: target)) == original else { throw KubeConfigEditError.changedOnDisk(path: url.path) }
    }

    /// Backs up the current content and replaces it with `data`, keeping the file's permissions. Call while holding
    /// the lock, after `verifyUnchanged`.
    func commit(_ data: Data) throws -> KubeConfigDocument {
        let manager = FileManager.default
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let mode = (try? manager.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int).map { mode_t($0) } ?? 0o600
        if let original { try KubeConfigFileWriter.backUp(original, of: target) }
        try KubeConfigFileWriter.write(data, to: target, mode: mode)
        return try KubeConfigDocument(url: url, text: String(decoding: data, as: UTF8.self), original: data)
    }

    /// Puts back the content this document was loaded from, after a failed multi-file save.
    func restoreOriginal() {
        if let original {
            let mode = (try? FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int).map { mode_t($0) }
            try? KubeConfigFileWriter.write(original, to: target, mode: mode ?? 0o600)
        } else {
            try? FileManager.default.removeItem(at: target)
        }
    }
}

extension Node {
    /// A string scalar. Values such as `true` or `0123` are quoted on output instead of turning into other types.
    static func str(_ value: String) -> Node {
        // The emitter writes the str tag implicitly, so a value that reads as another type must be quoted.
        let plain = Node(value)
        return Node(value, Tag(.str), plain.tag == Tag(.str) ? .any : .singleQuoted)
    }
}
