import Foundation
import KubeKit
import Observation

enum ClusterHealth: Equatable {
    case unknown
    case checking
    case reachable(version: String, nodes: Int)
    case unreachable(String)
}

/// Every context from the user's kubeconfig files, plus on-demand reachability checks.
@MainActor @Observable
final class ClusterCatalogModel {
    private(set) var contexts: [ContextSummary] = []
    private(set) var loadErrors: [String] = []
    private(set) var health: [String: ClusterHealth] = [:]
    private(set) var isLoading = false
    /// Context shown in the main window's detail area.
    var selectedContext: String?
    /// Clusters opened this run. They stay connected (watches, shells, port forwards) until disconnected.
    var sessions: [String: ClusterSession] = [:]
    @ObservationIgnored var didAutoConnect = false
    /// Kubeconfig files in precedence order (the first is where new contexts go), and the file defining each context.
    private(set) var files: [URL] = []
    private(set) var contextSources: [String: URL] = [:]
    @ObservationIgnored private var config = MergedKubeConfig([])

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        // GUI launches have no KUBECONFIG; the login shell environment does.
        let environment = await LoginShellEnvironment.shared.environment()
        var seen = Set<String>()
        let files = KubeConfigLoader.defaultFileURLs(environment: environment).filter { seen.insert($0.standardizedFileURL.path).inserted }
        let result = await Task.detached { KubeConfigLoader.loadAll(files) }.value
        let previous = config
        self.files = files
        contextSources = result.contextSources
        config = MergedKubeConfig(result.configs)
        contexts = config.contextSummaries
        loadErrors = result.errors.map(\.localizedDescription)
        retireChangedContexts(since: previous, loadedCleanly: result.errors.isEmpty)
    }

    /// Sessions and health results describe a context's settings at the time; when the kubeconfig changes them
    /// (server, CA, credentials) or removes the context, they are dropped. A file that failed to load, e.g. while
    /// another tool is rewriting it, does not count as removing its contexts.
    private func retireChangedContexts(since previous: MergedKubeConfig, loadedCleanly: Bool) {
        let names = Set(sessions.keys).union(health.keys)
        for name in names {
            // Not known before (e.g. opened at launch, ahead of the first load): nothing to compare against.
            guard let before = try? previous.resolve(contextNamed: name) else { continue }
            let after = try? config.resolve(contextNamed: name)
            if after == nil, !loadedCleanly { continue }
            guard before != after else { continue }
            health[name] = nil
            disconnect(name)
        }
        if let selected = selectedContext, config.contexts[selected] == nil, loadedCleanly { selectedContext = nil }
    }

    func resolve(_ name: String) throws -> ResolvedContext {
        try config.resolve(contextNamed: name)
    }

    /// Exec plugins may open a browser login or call cloud CLIs, so such contexts are only checked on request.
    func usesExecPlugin(_ name: String) -> Bool {
        (try? resolve(name))?.user.exec != nil
    }

    func checkAutomatically() async {
        await withTaskGroup(of: Void.self) { group in
            for context in contexts where !usesExecPlugin(context.name) && health[context.name] == nil {
                group.addTask { await self.check(context.name) }
            }
        }
    }

    func check(_ name: String) async {
        health[name] = .checking
        do {
            let transport = try KubeTransport(context: try resolve(name))
            let probe = try await Self.withTimeout(.seconds(10)) {
                let client = DynamicClient(transport: transport)
                let (data, _) = try await transport.data(KubeRequest(path: "/version"))
                let version = try JSONValue.parse(data)["gitVersion"]?.stringValue ?? "?"
                return (version, try await client.count(GroupVersionResource(group: "", version: "v1", resource: "nodes")))
            }
            health[name] = .reachable(version: probe.0, nodes: probe.1)
        } catch let error as URLError where error.code == .timedOut {
            health[name] = .unreachable("No response within 10 seconds")
        } catch {
            health[name] = .unreachable(error.localizedDescription)
        }
    }

    static func withTimeout<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
