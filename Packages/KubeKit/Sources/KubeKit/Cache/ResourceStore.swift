import Foundation
import Observation

/// Main-actor view of a reflector's collection for SwiftUI.
@MainActor @Observable
public final class ResourceStore<Item: Sendable> {
    public private(set) var items: [Item] = []
    public private(set) var columns: [ResourceTableColumn] = []
    public private(set) var phase = ReflectorPhase.connecting

    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var stopSource: (@Sendable () async -> Void)?
    @ObservationIgnored private var startSource: (() -> Void)?

    public init<Source: ListWatchSource>(source: Source, coalesceInterval: Duration = .milliseconds(150)) where Source.Item == Item {
        startSource = { [weak self] in
            guard let self else { return }
            let reflector = Reflector(source: source, coalesceInterval: coalesceInterval)
            stopSource = { await reflector.stop() }
            consumer = Task { [weak self] in
                await reflector.start()
                for await snapshot in reflector.updates {
                    guard let self else { return }
                    self.items = snapshot.items
                    self.columns = snapshot.columns
                    self.phase = snapshot.phase
                }
            }
        }
        startSource?()
    }

    /// Relists from scratch with a new reflector; current items stay visible until the new list arrives.
    public func restart() {
        stop()
        phase = .connecting
        startSource?()
    }

    public func stop() {
        consumer?.cancel()
        consumer = nil
        if let stopSource { Task { await stopSource() } }
        stopSource = nil
    }

    /// A store dropped without `stop()` must not leave its watch running.
    deinit {
        consumer?.cancel()
        if let stopSource { Task { await stopSource() } }
    }
}

/// Shares one watch per (resource, namespace) across views and stops it when the last view lets go,
/// so only collections that are on screen consume memory and API server watches.
@MainActor
public final class ResourceStoreRegistry {
    struct Key: Hashable {
        let gvr: GroupVersionResource
        let namespace: String?

        /// `""` and `nil` both mean all namespaces.
        init(gvr: GroupVersionResource, namespace: String?) {
            self.gvr = gvr
            self.namespace = namespace?.isEmpty == true ? nil : namespace
        }
    }

    private let client: DynamicClient
    private var entries: [Key: (store: ResourceStore<ResourceTableRow>, references: Int)] = [:]

    public init(client: DynamicClient) {
        self.client = client
    }

    /// Returns the shared table store, starting its watch on first use. Balance with `release`.
    public func acquire(_ gvr: GroupVersionResource, namespace: String? = nil) -> ResourceStore<ResourceTableRow> {
        let key = Key(gvr: gvr, namespace: namespace)
        let namespace = key.namespace
        if let entry = entries[key] {
            entries[key]?.references = entry.references + 1
            return entry.store
        }
        let store = ResourceStore(source: TableListWatchSource(client: client, gvr: gvr, namespace: namespace))
        entries[key] = (store, 1)
        return store
    }

    public func release(_ gvr: GroupVersionResource, namespace: String? = nil) {
        let key = Key(gvr: gvr, namespace: namespace)
        guard let entry = entries[key] else { return }
        if entry.references > 1 {
            entries[key]?.references = entry.references - 1
        } else {
            entry.store.stop()
            entries[key] = nil
        }
    }

    /// Relists every active collection (user-requested refresh).
    public func restartAll() {
        entries.values.forEach { $0.store.restart() }
    }

    /// Stops every watch, e.g. when switching away from the cluster.
    public func releaseAll() {
        entries.values.forEach { $0.store.stop() }
        entries.removeAll()
    }

    var activeCount: Int { entries.count }
}
