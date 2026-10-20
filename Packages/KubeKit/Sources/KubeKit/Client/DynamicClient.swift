import Foundation

public enum PatchType: String, Sendable {
    case json = "application/json-patch+json"
    case merge = "application/merge-patch+json"
    case strategicMerge = "application/strategic-merge-patch+json"
    case apply = "application/apply-patch+yaml"
}

/// Options shared by list and watch.
public struct ListOptions: Sendable {
    public var labelSelector: String?
    public var fieldSelector: String?

    public init(labelSelector: String? = nil, fieldSelector: String? = nil) {
        self.labelSelector = labelSelector
        self.fieldSelector = fieldSelector
    }

    var queryItems: [URLQueryItem] {
        [labelSelector.map { URLQueryItem(name: "labelSelector", value: $0) },
         fieldSelector.map { URLQueryItem(name: "fieldSelector", value: $0) }].compactMap { $0 }
    }
}

/// Verb-level access to any resource addressed by `GroupVersionResource`. Objects are `Unstructured`.
public struct DynamicClient: Sendable {
    /// Field manager recorded for server-side apply and writes made by this app.
    public static let fieldManager = "cluvia"
    /// Server closes watches after this long; the reflector simply re-watches from the last resource version.
    static let watchTimeoutSeconds = 300
    /// Client-side cap on a watch. A half-open connection (sleep, network change) delivers neither data nor
    /// an error, so the stream is ended locally shortly after the server should have closed it.
    static let watchDeadline: Duration = .seconds(watchTimeoutSeconds + 30)

    public let transport: KubeTransport

    public init(transport: KubeTransport) {
        self.transport = transport
    }

    public func get(_ gvr: GroupVersionResource, name: String, namespace: String? = nil) async throws -> Unstructured {
        try await object(KubeRequest(path: gvr.path(namespace: namespace, name: name)))
    }

    public func list(
        _ gvr: GroupVersionResource, namespace: String? = nil, options: ListOptions = ListOptions()
    ) async throws -> (items: [Unstructured], resourceVersion: String?) {
        let json = try await decode(KubeRequest(path: gvr.path(namespace: namespace), query: options.queryItems))
        let items = (json["items"]?.arrayValue ?? []).map(Unstructured.init)
        return (items, json[path: "metadata", "resourceVersion"]?.stringValue)
    }

    /// Names and namespaces of every object, without specs or status (cheap enough to scan many kinds).
    public func listKeys(_ gvr: GroupVersionResource, namespace: String? = nil) async throws -> [ObjectKey] {
        let json = try await decode(KubeRequest(
            path: gvr.path(namespace: namespace),
            accept: "application/json;as=PartialObjectMetadataList;g=meta.k8s.io;v=v1,application/json"
        ), omittingKeys: ResourceTable.omittedKeys)
        return (json["items"]?.arrayValue ?? []).map { Unstructured($0).key }
    }

    /// Number of objects without transferring them: one metadata-only item plus the server's remaining count.
    public func count(_ gvr: GroupVersionResource, namespace: String? = nil) async throws -> Int {
        let json = try await decode(KubeRequest(
            path: gvr.path(namespace: namespace), query: [URLQueryItem(name: "limit", value: "1")],
            accept: "application/json;as=PartialObjectMetadataList;g=meta.k8s.io;v=v1,application/json"
        ), omittingKeys: ResourceTable.omittedKeys)
        let returned = json["items"]?.arrayValue?.count ?? 0
        return returned + Int(json[path: "metadata", "remainingItemCount"]?.intValue ?? 0)
    }

    /// Server-printed list with object metadata attached to each row.
    public func listTable(
        _ gvr: GroupVersionResource, namespace: String? = nil, options: ListOptions = ListOptions()
    ) async throws -> ResourceTable {
        let json = try await decode(KubeRequest(
            path: gvr.path(namespace: namespace),
            query: options.queryItems + [URLQueryItem(name: "includeObject", value: "Metadata")],
            accept: ResourceTable.accept
        ), omittingKeys: ResourceTable.omittedKeys)
        return ResourceTable(json)
    }

    public func create(_ gvr: GroupVersionResource, namespace: String? = nil, object: Unstructured) async throws -> Unstructured {
        try await self.object(KubeRequest(
            method: "POST", path: gvr.path(namespace: namespace), query: [fieldManagerItem],
            body: try object.data(), contentType: "application/json"
        ))
    }

    public enum PropagationPolicy: String, Sendable {
        case background = "Background", foreground = "Foreground", orphan = "Orphan"
    }

    public func delete(
        _ gvr: GroupVersionResource, name: String, namespace: String? = nil, propagationPolicy: PropagationPolicy? = .background
    ) async throws {
        let body = propagationPolicy.map { #"{"kind":"DeleteOptions","apiVersion":"v1","propagationPolicy":"\#($0.rawValue)"}"# }
        _ = try await transport.data(KubeRequest(
            method: "DELETE", path: gvr.path(namespace: namespace, name: name),
            body: body.map { Data($0.utf8) }, contentType: body == nil ? nil : "application/json"
        ))
    }

    public func patch(
        _ gvr: GroupVersionResource, name: String, namespace: String? = nil,
        type: PatchType, body: Data, subresource: String? = nil
    ) async throws -> Unstructured {
        try await object(KubeRequest(
            method: "PATCH", path: gvr.path(namespace: namespace, name: name, subresource: subresource),
            query: [fieldManagerItem], body: body, contentType: type.rawValue
        ))
    }

    /// Server-side apply of a full manifest (YAML or JSON). `force` takes ownership of conflicting fields;
    /// `dryRun` runs admission and defaulting and returns the result without persisting it.
    public func apply(
        _ gvr: GroupVersionResource, name: String, namespace: String? = nil, manifest: Data,
        force: Bool = false, dryRun: Bool = false
    ) async throws -> Unstructured {
        var query = [fieldManagerItem]
        if force { query.append(URLQueryItem(name: "force", value: "true")) }
        if dryRun { query.append(URLQueryItem(name: "dryRun", value: "All")) }
        return try await object(KubeRequest(
            method: "PATCH", path: gvr.path(namespace: namespace, name: name),
            query: query, body: manifest, contentType: PatchType.apply.rawValue
        ))
    }

    /// Watch stream of raw JSON events starting after `resourceVersion`. Cancelling the consumer closes the stream.
    public func watch(
        _ gvr: GroupVersionResource, namespace: String? = nil, resourceVersion: String,
        options: ListOptions = ListOptions(), table: Bool = false
    ) -> AsyncThrowingStream<WatchEvent<JSONValue>, Error> {
        var query = options.queryItems + [
            URLQueryItem(name: "watch", value: "1"),
            URLQueryItem(name: "resourceVersion", value: resourceVersion),
            URLQueryItem(name: "allowWatchBookmarks", value: "true"),
            URLQueryItem(name: "timeoutSeconds", value: String(Self.watchTimeoutSeconds)),
        ]
        if table { query.append(URLQueryItem(name: "includeObject", value: "Metadata")) }
        let request = KubeRequest(path: gvr.path(namespace: namespace), query: query, accept: table ? ResourceTable.accept : "application/json")
        let transport = transport
        let omittingKeys = table ? ResourceTable.omittedKeys : []
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            let (bytes, _) = try await transport.bytes(request)
                            for try await line in bytes.lines where !line.isEmpty {
                                continuation.yield(try WatchEventParser.parse(line, omittingKeys: omittingKeys))
                            }
                        }
                        group.addTask { try await Task.sleep(for: Self.watchDeadline) }
                        // Whichever ends first (server close or deadline) ends the watch normally.
                        try await group.next()
                        group.cancelAll()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private var fieldManagerItem: URLQueryItem { URLQueryItem(name: "fieldManager", value: Self.fieldManager) }

    private func decode(_ request: KubeRequest, omittingKeys: Set<String> = []) async throws -> JSONValue {
        let (data, _) = try await transport.data(request)
        return try JSONValue.parse(data, omittingKeys: omittingKeys)
    }

    private func object(_ request: KubeRequest) async throws -> Unstructured {
        Unstructured(try await decode(request))
    }
}
