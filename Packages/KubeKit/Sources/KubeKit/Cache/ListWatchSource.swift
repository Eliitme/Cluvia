import Foundation

/// Full state of a collection at one resource version.
public struct ListSnapshot<Item: Sendable>: Sendable {
    public var items: [(key: ObjectKey, item: Item)]
    public var resourceVersion: String
    public var columns: [TableColumn]

    public init(items: [(key: ObjectKey, item: Item)], resourceVersion: String, columns: [TableColumn] = []) {
        self.items = items
        self.resourceVersion = resourceVersion
        self.columns = columns
    }
}

/// Change to a collection, already reduced to what the reflector needs.
public enum SourceEvent<Item: Sendable>: Sendable {
    case upsert(ObjectKey, Item, resourceVersion: String?)
    case delete(ObjectKey, resourceVersion: String?)
    case bookmark(resourceVersion: String)
    /// The watch resource version is too old (HTTP 410); the collection must be relisted.
    case expired
}

/// Something a `Reflector` can list and watch. Abstracted so the reflector is testable without a cluster.
public protocol ListWatchSource: Sendable {
    associatedtype Item: Sendable
    func list() async throws -> ListSnapshot<Item>
    func watch(from resourceVersion: String) -> AsyncThrowingStream<SourceEvent<Item>, Error>
}

/// Lists and watches one collection as server-printed table rows.
public struct TableListWatchSource: ListWatchSource {
    public let client: DynamicClient
    public let gvr: GroupVersionResource
    public let namespace: String?
    public let options: ListOptions

    public init(client: DynamicClient, gvr: GroupVersionResource, namespace: String? = nil, options: ListOptions = ListOptions()) {
        self.client = client
        self.gvr = gvr
        self.namespace = namespace
        self.options = options
    }

    public func list() async throws -> ListSnapshot<TableRow> {
        let table = try await client.listTable(gvr, namespace: namespace, options: options)
        return ListSnapshot(items: table.rows.map { ($0.id, $0) }, resourceVersion: table.resourceVersion ?? "", columns: table.columns)
    }

    public func watch(from resourceVersion: String) -> AsyncThrowingStream<SourceEvent<TableRow>, Error> {
        let upstream = client.watch(gvr, namespace: namespace, resourceVersion: resourceVersion, options: options, table: true)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in upstream {
                        for converted in try Self.convert(event) { continuation.yield(converted) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Table watch events wrap the changed object in a one-row Table. Bookmarks also carry a placeholder row
    /// without a name, so they must never be treated as data.
    static func convert(_ event: WatchEvent<JSONValue>) throws -> [SourceEvent<TableRow>] {
        switch event {
        case let .added(json), let .modified(json):
            let table = ResourceTable(json)
            return table.rows.map { .upsert($0.id, $0, resourceVersion: table.resourceVersion) }
        case let .deleted(json):
            let table = ResourceTable(json)
            return table.rows.map { .delete($0.id, resourceVersion: table.resourceVersion) }
        case let .bookmark(resourceVersion):
            return [.bookmark(resourceVersion: resourceVersion)]
        case let .error(error):
            if error.statusCode == 410 { return [.expired] }
            throw error
        }
    }
}
