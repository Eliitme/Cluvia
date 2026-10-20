import Foundation
import KubeKit
import Observation

/// One opened cluster: transport, discovery, shared watches and the user's browsing state.
@MainActor @Observable
final class ClusterSession {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    let contextName: String
    private(set) var state = State.disconnected
    private(set) var kinds: [ResourceKind] = []
    private(set) var counts: [GroupVersionResource: Int] = [:]
    private(set) var serverVersion: String?
    /// metrics.k8s.io is served (metrics-server installed); CPU/memory columns are hidden otherwise.
    private(set) var metricsAvailable = false
    var selectedKind: ResourceKind? {
        didSet {
            showingHelm = false
            if selectedKind != oldValue { selectedObject = nil }
            // Keep the selected kind visible in the sidebar, e.g. after picking it from the palette.
            if let category = selectedKind?.category { expandedCategories.insert(category) }
        }
    }
    /// The Helm releases page is shown instead of a resource table.
    var showingHelm = false
    /// Resource groups opened in the sidebar.
    var expandedCategories: Set<ResourceCategory> = [.cluster, .workloads]
    let helm: HelmReleasesModel
    let prometheus: PrometheusModel
    @ObservationIgnored let searchIndex = GlobalSearchIndex()
    var selectedObject: ObjectKey?
    /// The detail panel next to the resource table.
    var showInspector = false
    let dock = DockModel()
    let portForwards = PortForwardManager()
    /// Sheets driven from menus, the inspector and the command palette.
    var pendingAction: PendingAction?
    var editModel: YamlEditModel?
    var actionError: String?
    var showPalette = false
    /// Command chosen in the palette, run once the palette sheet has closed.
    var paletteCommand: PaletteItem.Command?
    var selectedNamespaces: Set<String> {
        didSet { settings.setNamespaces(selectedNamespaces, for: contextName) }
    }

    @ObservationIgnored private(set) var client: DynamicClient?
    @ObservationIgnored private(set) var registry: ResourceStoreRegistry?
    private(set) var namespaceStore: ResourceStore<ResourceTableRow>?
    @ObservationIgnored private var catalog: APIResourceCatalog?
    @ObservationIgnored private let settings: AppSettingsStore

    init(contextName: String, settings: AppSettingsStore) {
        self.contextName = contextName
        self.settings = settings
        helm = HelmReleasesModel(contextName: contextName)
        prometheus = PrometheusModel(contextName: contextName, settings: settings)
        selectedNamespaces = settings.namespaces(for: contextName)
    }

    var namespaces: [String] {
        (namespaceStore?.items ?? []).map(\.object.name)
    }

    /// Server-side scopes for namespaced kinds: `[nil]` for all namespaces, otherwise one watch per selected
    /// namespace (works for users whose RBAC is limited to those namespaces, and avoids listing the whole cluster).
    var watchNamespaces: [String?] {
        selectedNamespaces.isEmpty ? [nil] : selectedNamespaces.sorted()
    }

    func connect(using contexts: ClusterCatalogModel) async {
        state = .connecting
        do {
            let transport = try KubeTransport(context: try contexts.resolve(contextName))
            let client = DynamicClient(transport: transport)
            let catalog = try await APIDiscovery(transport: transport).catalog()
            let (version, _) = try await transport.data(KubeRequest(path: "/version"))
            serverVersion = try JSONValue.parse(version)["gitVersion"]?.stringValue
            self.client = client
            self.catalog = catalog
            let registry = ResourceStoreRegistry(client: client)
            self.registry = registry
            namespaceStore = registry.acquire(.namespaces)
            kinds = ResourceKindRegistry.kinds(from: catalog)
            metricsAvailable = MetricsService.isAvailable(in: catalog)
            if selectedKind == nil { selectedKind = kinds.first { $0.gvr == .pods } ?? kinds.first }
            state = .connected
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Server-side apply against this cluster; nil until connected.
    var applier: ResourceApplier? {
        guard let client, let catalog else { return nil }
        return ResourceApplier(client: client, catalog: catalog)
    }

    func disconnect() {
        dock.closeAll()
        portForwards.stopAll()
        registry?.releaseAll()
        registry = nil
        namespaceStore = nil
        client = nil
        state = .disconnected
    }

    /// Relists every open collection and recounts.
    func refresh() {
        registry?.restartAll()
        Task { await refreshCounts() }
    }

    /// Object counts for the sidebar, summed over the selected namespaces for namespaced kinds.
    func refreshCounts() async {
        guard let client else { return }
        let scopes = watchNamespaces
        let snapshot = kinds
        let results = await withTaskGroup(of: (GroupVersionResource, Int?).self) { group in
            for kind in snapshot {
                group.addTask {
                    var total = 0
                    for scope in kind.namespaced ? scopes : [nil] {
                        guard let count = try? await client.count(kind.gvr, namespace: scope) else { return (kind.gvr, nil) }
                        total += count
                    }
                    return (kind.gvr, total)
                }
            }
            var counts: [GroupVersionResource: Int] = [:]
            for await (gvr, count) in group { counts[gvr] = count }
            return counts
        }
        counts = results
    }

    /// Jumps to another object, e.g. from an owner reference.
    func reveal(_ kind: ResourceKind, _ key: ObjectKey) {
        selectedKind = kind
        selectedObject = key
    }

    /// Kind serving `ownerKind` (e.g. ReplicaSet) for navigation from owner references.
    func kind(named ownerKind: String, apiVersion: String) -> ResourceKind? {
        let group = apiVersion.contains("/") ? String(apiVersion.split(separator: "/")[0]) : ""
        return kinds.first { $0.kind == ownerKind && $0.gvr.group == group }
    }

    func kind(for gvr: GroupVersionResource) -> ResourceKind? {
        kinds.first { $0.gvr == gvr }
    }
}
