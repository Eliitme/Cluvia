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
    /// Contexts the user explicitly opened this run. Windows restored at launch for exec-plugin contexts
    /// wait for a click instead of silently running the plugin (which may open a browser login).
    private(set) var requestedContexts: Set<String> = []
    @ObservationIgnored private var config = MergedKubeConfig([])

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        // GUI launches have no KUBECONFIG; the login shell environment does.
        let environment = await LoginShellEnvironment.shared.environment()
        let result = await Task.detached {
            KubeConfigLoader.loadAll(KubeConfigLoader.defaultFileURLs(environment: environment))
        }.value
        config = MergedKubeConfig(result.configs)
        contexts = config.contextSummaries
        loadErrors = result.errors.map(\.localizedDescription)
    }

    func markRequested(_ name: String) {
        requestedContexts.insert(name)
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
