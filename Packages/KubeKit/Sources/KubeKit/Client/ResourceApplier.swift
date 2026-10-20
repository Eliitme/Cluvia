import Foundation
import Yams

public enum ApplyError: Error, LocalizedError, Sendable {
    case invalidYAML(String)
    case missingField(String)
    case unknownKind(apiVersion: String, kind: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidYAML(reason): "Invalid YAML: \(reason)"
        case let .missingField(field): "Manifest is missing \(field)"
        case let .unknownKind(apiVersion, kind): "The cluster does not serve \(kind) in \(apiVersion)"
        }
    }
}

public enum ApplyOutcome: Sendable {
    case applied(Unstructured)
    /// Another field manager owns fields this manifest changes; re-apply with `force` to take them over.
    case conflicts([KubeAPIError.Cause])
}

/// Server-side apply of user-edited manifests, with dry-run and conflict reporting.
public struct ResourceApplier: Sendable {
    public let client: DynamicClient
    public let catalog: APIResourceCatalog

    public init(client: DynamicClient, catalog: APIResourceCatalog) {
        self.client = client
        self.catalog = catalog
    }

    /// Kubernetes converts YAML to JSON without YAML timestamps, so `2026-10-20` stays a string.
    static let resolver = Resolver.default.removing(.timestamp)

    public static func manifest(fromYAML yaml: String) throws -> JSONValue {
        do {
            guard let object = try Yams.load(yaml: yaml, resolver) else { throw ApplyError.invalidYAML("document is empty") }
            // Binary, NaN or infinity would raise an Objective-C exception in JSONSerialization; reject them first.
            guard JSONSerialization.isValidJSONObject(object) else {
                throw ApplyError.invalidYAML("unsupported value (binary data, NaN or infinity)")
            }
            return try JSONValue.parse(JSONSerialization.data(withJSONObject: object))
        } catch let error as ApplyError {
            throw error
        } catch {
            throw ApplyError.invalidYAML(KubeConfigLoader.safeDescription(of: error))
        }
    }

    /// Removes server-managed fields an apply body must not carry: status is owned by controllers, and
    /// resourceVersion would turn the apply into an optimistic-concurrency check against a stale version.
    public static func prepared(_ manifest: JSONValue) -> JSONValue {
        guard case var .object(fields) = manifest else { return manifest }
        fields["status"] = nil
        if case var .object(metadata)? = fields["metadata"] {
            for key in ["managedFields", "resourceVersion", "uid", "creationTimestamp", "generation", "selfLink"] {
                metadata[key] = nil
            }
            fields["metadata"] = .object(metadata)
        }
        return .object(fields)
    }

    public func apply(yaml: String, defaultNamespace: String?, dryRun: Bool, force: Bool) async throws -> ApplyOutcome {
        let manifest = Self.prepared(try Self.manifest(fromYAML: yaml))
        guard let apiVersion = manifest["apiVersion"]?.stringValue else { throw ApplyError.missingField("apiVersion") }
        guard let kind = manifest["kind"]?.stringValue else { throw ApplyError.missingField("kind") }
        guard let name = manifest[path: "metadata", "name"]?.stringValue, !name.isEmpty else {
            throw ApplyError.missingField("metadata.name")
        }
        let info = try resource(apiVersion: apiVersion, kind: kind)
        let namespace = info.namespaced ? (manifest[path: "metadata", "namespace"]?.stringValue ?? defaultNamespace) : nil
        if info.namespaced, namespace == nil { throw ApplyError.missingField("metadata.namespace") }
        do {
            return .applied(try await client.apply(
                info.gvr, name: name, namespace: namespace, manifest: try Unstructured(manifest).data(), force: force, dryRun: dryRun
            ))
        } catch let error as KubeAPIError where error.statusCode == 409 && !error.causes.isEmpty {
            return .conflicts(error.causes)
        }
    }

    /// The exact group/version from the manifest; falls back to the group's preferred version for the kind.
    func resource(apiVersion: String, kind: String) throws -> APIResourceInfo {
        let parts = apiVersion.split(separator: "/").map(String.init)
        let group = parts.count == 2 ? parts[0] : ""
        let version = parts.last ?? ""
        if let exact = catalog.resources.first(where: { $0.kind == kind && $0.gvr.group == group && $0.gvr.version == version }) {
            return exact
        }
        if let preferred = catalog.resource(forKind: kind, group: group) { return preferred }
        throw ApplyError.unknownKind(apiVersion: apiVersion, kind: kind)
    }
}
