import Foundation
import Testing
@testable import KubeKit

@Suite(.enabled(if: IntegrationCluster.isEnabled, "set CLUVIA_IT_CONTEXT to run against a real cluster"), .serialized)
struct LogsAndApplyIntegrationTests {
    static let namespace = WatchCacheIntegrationTests.namespace
    static let deployments = GroupVersionResource(group: "apps", version: "v1", resource: "deployments")

    /// A container that prints a unique boot line, a few ticks, then exits so the kubelet restarts it.
    @Test func followedLogsContinueAcrossContainerRestart() async throws {
        let client = try WatchCacheIntegrationTests.client()
        try await WatchCacheIntegrationTests.ensureNamespace(client)
        let name = "cluvia-it-restarter"
        try? await client.delete(.pods, name: name, namespace: Self.namespace, propagationPolicy: nil)
        while (try? await client.get(.pods, name: name, namespace: Self.namespace)) != nil { try await Task.sleep(for: .seconds(1)) }
        let pod = """
        {"apiVersion":"v1","kind":"Pod","metadata":{"name":"\(name)"},"spec":{"restartPolicy":"Always",
         "containers":[{"name":"main","image":"busybox:1.36","command":["sh","-c",
           "echo boot-$(cat /proc/sys/kernel/random/uuid); for i in 1 2 3; do echo tick $i; sleep 1; done"]}]}}
        """
        _ = try await client.create(.pods, namespace: Self.namespace, object: Unstructured(data: Data(pod.utf8)))

        var boots = Set<String>()
        var reconnects = 0
        let deadline = Date().addingTimeInterval(90)
        for try await event in LogStreamer(client: client).stream(pod: name, namespace: Self.namespace, options: LogOptions()) {
            switch event {
            case let .line(line) where line.text.hasPrefix("boot-"):
                boots.insert(line.text)
                #expect(line.timestamp != nil)
            case .reconnecting:
                reconnects += 1
            default:
                break
            }
            if boots.count >= 2 || Date() > deadline { break }
        }
        try? await client.delete(.pods, name: name, namespace: Self.namespace, propagationPolicy: nil)
        #expect(boots.count >= 2, "saw \(boots.count) container instances after \(reconnects) reconnects")
    }

    @Test func dryRunThenApplyChangesReplicasWithConflictHandling() async throws {
        let client = try WatchCacheIntegrationTests.client()
        try await WatchCacheIntegrationTests.ensureNamespace(client)
        // Created by a different field manager (as `kubectl create` would), so it owns spec.replicas.
        let name = "cluvia-it-apply"
        try? await client.delete(Self.deployments, name: name, namespace: Self.namespace, propagationPolicy: nil)
        while (try? await client.get(Self.deployments, name: name, namespace: Self.namespace)) != nil {
            try await Task.sleep(for: .milliseconds(300))
        }
        let deployment = """
        {"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"\(name)"},"spec":{"replicas":1,
         "selector":{"matchLabels":{"app":"\(name)"}},"template":{"metadata":{"labels":{"app":"\(name)"}},
         "spec":{"containers":[{"name":"c","image":"busybox:1.36","command":["sleep","86400"]}]}}}}
        """
        _ = try await client.transport.data(KubeRequest(
            method: "POST", path: Self.deployments.path(namespace: Self.namespace),
            query: [URLQueryItem(name: "fieldManager", value: "kubectl-create")],
            body: Data(deployment.utf8), contentType: "application/json"
        ))
        let live = try await client.get(Self.deployments, name: name, namespace: Self.namespace)
        let target: Int64 = 3
        let edited = try YAMLRenderer.yaml(live.json).replacingOccurrences(
            of: "\n  replicas: \(live.json[path: "spec", "replicas"]?.intValue ?? 0)\n", with: "\n  replicas: \(target)\n"
        )
        let catalog = try await APIDiscovery(transport: client.transport).catalog()
        let applier = ResourceApplier(client: client, catalog: catalog)

        // Dry run reports the conflict or the would-be result, and never persists.
        let dry = try await applier.apply(yaml: edited, defaultNamespace: nil, dryRun: true, force: true)
        guard case let .applied(preview) = dry else { return #expect(Bool(false), "forced dry run must not conflict") }
        #expect(preview.json[path: "spec", "replicas"]?.intValue == target)
        #expect(try await client.get(Self.deployments, name: name, namespace: Self.namespace).json[path: "spec", "replicas"]
            == live.json[path: "spec", "replicas"])

        let first = try await applier.apply(yaml: edited, defaultNamespace: nil, dryRun: false, force: false)
        guard case let .conflicts(causes) = first else { return #expect(Bool(false), "expected an ownership conflict") }
        #expect(causes.contains { $0.field?.contains("replicas") == true })
        _ = try await applier.apply(yaml: edited, defaultNamespace: nil, dryRun: false, force: true)
        let persisted = try await client.get(Self.deployments, name: name, namespace: Self.namespace)
        #expect(persisted.json[path: "spec", "replicas"]?.intValue == target)
    }
}
