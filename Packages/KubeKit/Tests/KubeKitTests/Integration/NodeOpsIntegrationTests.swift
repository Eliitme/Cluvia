import Foundation
import Testing
@testable import KubeKit

@Suite(.enabled(if: IntegrationCluster.isEnabled, "set CLUVIA_IT_CONTEXT to run against a real cluster"), .serialized)
struct NodeOpsIntegrationTests {
    static let namespace = WatchCacheIntegrationTests.namespace

    static func nodeName(_ client: DynamicClient) async throws -> String {
        try #require(try await client.list(ResourceActionsCore.nodes).items.first?.name)
    }

    /// The shell runs in the host's namespaces: its hostname is the node's.
    @Test func nodeShellEntersHostNamespaces() async throws {
        let client = try WatchCacheIntegrationTests.client()
        try await WatchCacheIntegrationTests.ensureNamespace(client)
        let node = try await Self.nodeName(client)
        let pod = try await NodeShellPod.create(client: client, node: node, namespace: Self.namespace)
        let session = ExecSession(transport: client.transport, namespace: Self.namespace, pod: pod, container: nil,
                                  command: ["nsenter", "-t", "1", "-u", "--", "hostname"], tty: false)
        try await session.start()
        let (text, code) = await ExecAndPortForwardIntegrationTests.output(of: session)
        try? await client.delete(.pods, name: pod, namespace: Self.namespace, propagationPolicy: nil)
        #expect(code == 0)
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == node)
    }

    /// Opt-in (`CLUVIA_IT_DRAIN=1`, run alone): cordons the node while it runs.
    @Test(.enabled(if: IntegrationCluster.environment["CLUVIA_IT_DRAIN"] == "1"))
    func drainRespectsDisruptionBudgetsAndReportsRefusals() async throws {
        let client = try WatchCacheIntegrationTests.client()
        try await WatchCacheIntegrationTests.ensureNamespace(client)
        let node = try await Self.nodeName(client)
        let deployments = GroupVersionResource(group: "apps", version: "v1", resource: "deployments")
        let pdbs = GroupVersionResource(group: "policy", version: "v1", resource: "poddisruptionbudgets")
        let deployment = """
        {"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"cluvia-it-drain"},"spec":{"replicas":1,
         "selector":{"matchLabels":{"app":"cluvia-it-drain"}},"template":{"metadata":{"labels":{"app":"cluvia-it-drain","cluvia-drain":"yes"}},
         "spec":{"terminationGracePeriodSeconds":0,"containers":[{"name":"c","image":"busybox:1.36","command":["sleep","86400"]}]}}}}
        """
        let pdb = """
        {"apiVersion":"policy/v1","kind":"PodDisruptionBudget","metadata":{"name":"cluvia-it-drain"},
         "spec":{"minAvailable":1,"selector":{"matchLabels":{"app":"cluvia-it-drain"}}}}
        """
        let loose = """
        {"apiVersion":"v1","kind":"Pod","metadata":{"name":"cluvia-it-drain-loose","labels":{"cluvia-drain":"yes"}},
         "spec":{"terminationGracePeriodSeconds":0,"containers":[{"name":"c","image":"busybox:1.36","command":["sleep","86400"]}]}}
        """
        _ = try await client.apply(deployments, name: "cluvia-it-drain", namespace: Self.namespace, manifest: Data(deployment.utf8), force: true)
        _ = try await client.apply(pdbs, name: "cluvia-it-drain", namespace: Self.namespace, manifest: Data(pdb.utf8), force: true)
        _ = try await client.apply(.pods, name: "cluvia-it-drain-loose", namespace: Self.namespace, manifest: Data(loose.utf8), force: true)
        for _ in 0..<60 {
            let ready = try await client.list(.pods, namespace: Self.namespace, options: ListOptions(labelSelector: "app=cluvia-it-drain"))
                .items.contains { $0.json[path: "status", "phase"]?.stringValue == "Running" }
            if ready { break }
            try await Task.sleep(for: .seconds(1))
        }

        var options = DrainOptions()
        options.podSelector = "cluvia-drain=yes"
        options.timeout = .seconds(12)
        var events: [DrainEvent] = []
        do {
            for try await event in NodeDrainer(client: client).drain(node: node, options: options) { events.append(event) }
        } catch {
            Issue.record("drain failed: \(error)")
        }
        // Awaited cleanup: a detached Task in `defer` would not finish before the test process exits.
        try? await ResourceActionsCore.setUnschedulable(client, node: node, false)
        try? await client.delete(deployments, name: "cluvia-it-drain", namespace: Self.namespace)
        try? await client.delete(pdbs, name: "cluvia-it-drain", namespace: Self.namespace)
        try? await client.delete(.pods, name: "cluvia-it-drain-loose", namespace: Self.namespace, propagationPolicy: nil)

        #expect(events.first == .cordoned)
        #expect(events.contains { if case let .refused(key, _) = $0 { key.name == "cluvia-it-drain-loose" } else { false } })
        #expect(events.contains { if case .blocked = $0 { true } else { false } }, "PDB should block eviction: \(events)")
        guard case let .finished(remaining) = events.last else {
            Issue.record("no finish event")
            return
        }
        #expect(remaining.count == 1 && remaining.first?.name.hasPrefix("cluvia-it-drain-") == true)
    }
}
