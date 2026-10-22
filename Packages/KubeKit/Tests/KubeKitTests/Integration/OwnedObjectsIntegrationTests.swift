import Foundation
import Testing
@testable import KubeKit

@Suite(.enabled(if: IntegrationCluster.isEnabled, "set CLUVIA_IT_CONTEXT to run against a real cluster"), .serialized)
struct OwnedObjectsIntegrationTests {
    static let namespace = WatchCacheIntegrationTests.namespace
    static let deployments = GroupVersionResource(group: "apps", version: "v1", resource: "deployments")
    static let replicaSets = GroupVersionResource(group: "apps", version: "v1", resource: "replicasets")

    @Test func deploymentListsItsReplicaSetAndThatItsPods() async throws {
        let client = try WatchCacheIntegrationTests.client()
        try await WatchCacheIntegrationTests.ensureNamespace(client)
        let name = "cluvia-it-owned"
        try? await client.delete(Self.deployments, name: name, namespace: Self.namespace)
        while (try? await client.get(Self.deployments, name: name, namespace: Self.namespace)) != nil {
            try await Task.sleep(for: .milliseconds(300))
        }
        let manifest = """
        {"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"\(name)"},"spec":{"replicas":1,
         "selector":{"matchLabels":{"app":"\(name)"}},"template":{"metadata":{"labels":{"app":"\(name)"}},
         "spec":{"containers":[{"name":"c","image":"busybox:1.36","command":["sleep","86400"]}]}}}}
        """
        let deployment = try await client.create(Self.deployments, namespace: Self.namespace, object: Unstructured(data: Data(manifest.utf8)))

        var replicaSets: [Unstructured] = []
        var pods: [Unstructured] = []
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            replicaSets = try await OwnedObjects.list(client: client, child: Self.replicaSets, parent: deployment)
            if let replicaSet = replicaSets.first {
                let full = try await client.get(Self.replicaSets, name: replicaSet.name, namespace: Self.namespace)
                pods = try await OwnedObjects.list(client: client, child: .pods, parent: full)
                if !pods.isEmpty { break }
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        try? await client.delete(Self.deployments, name: name, namespace: Self.namespace)
        #expect(replicaSets.count == 1)
        #expect(replicaSets.first?.annotations["deployment.kubernetes.io/revision"] == "1")
        #expect(pods.count == 1)
    }
}
