import Foundation
import Testing
@testable import KubeKit

@Suite(.enabled(if: IntegrationCluster.isEnabled, "set CLUVIA_IT_CONTEXT to run against a real cluster"), .serialized)
struct RolloutIntegrationTests {
    static let namespace = WatchCacheIntegrationTests.namespace
    static let deployments = DeploymentRollout.deployments
    static let cronJobs = GroupVersionResource(group: "batch", version: "v1", resource: "cronjobs")

    static func waitForRevisions(_ client: DynamicClient, _ name: String, count: Int) async throws -> [DeploymentRevision] {
        let deadline = Date().addingTimeInterval(30)
        while true {
            let deployment = try await client.get(deployments, name: name, namespace: namespace)
            let revisions = try await DeploymentRollout.revisions(client: client, deployment: deployment)
            if revisions.count >= count || Date() > deadline { return revisions }
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    static func image(_ client: DynamicClient, _ name: String) async throws -> String? {
        try await client.get(deployments, name: name, namespace: namespace)
            .json[path: "spec", "template", "spec", "containers"]?.arrayValue?.first?["image"]?.stringValue
    }

    @Test func historyAndRollbackLikeKubectl() async throws {
        let client = try WatchCacheIntegrationTests.client()
        try await WatchCacheIntegrationTests.ensureNamespace(client)
        let name = "cluvia-it-rollout"
        try? await client.delete(Self.deployments, name: name, namespace: Self.namespace)
        while (try? await client.get(Self.deployments, name: name, namespace: Self.namespace)) != nil { try await Task.sleep(for: .milliseconds(300)) }
        let manifest = """
        {"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"\(name)"},"spec":{"replicas":0,
         "selector":{"matchLabels":{"app":"\(name)"}},"template":{"metadata":{"labels":{"app":"\(name)"}},
         "spec":{"containers":[{"name":"c","image":"busybox:1.36","command":["sleep","86400"]}]}}}}
        """
        _ = try await client.create(Self.deployments, namespace: Self.namespace, object: Unstructured(data: Data(manifest.utf8)))
        defer { Task { try? await client.delete(Self.deployments, name: name, namespace: Self.namespace) } }
        _ = try await Self.waitForRevisions(client, name, count: 1)
        let bump = #"{"metadata":{"annotations":{"kubernetes.io/change-cause":"to 1.37"}},"spec":{"template":{"spec":{"containers":[{"name":"c","image":"busybox:1.37"}]}}}}"#
        _ = try await client.patch(Self.deployments, name: name, namespace: Self.namespace, type: .strategicMerge, body: Data(bump.utf8))

        let history = try await Self.waitForRevisions(client, name, count: 2)
        #expect(history.map(\.revision) == [2, 1])
        #expect(history.first?.images == ["busybox:1.37"])
        let first = try #require(history.last)
        let shown = try #require(DeploymentRollout.generation(of: try await client.get(Self.deployments, name: name, namespace: Self.namespace)))

        // Someone deploys while the history is open: rolling back from that history must not undo their change.
        let other = #"{"spec":{"template":{"spec":{"containers":[{"name":"c","image":"busybox:1.35"}]}}}}"#
        _ = try await client.patch(Self.deployments, name: name, namespace: Self.namespace, type: .strategicMerge, body: Data(other.utf8))
        await #expect(throws: RolloutError.changed) {
            try await DeploymentRollout.rollback(client: client, namespace: Self.namespace, name: name, toReplicaSet: first.replicaSet,
                                                 expectedGeneration: shown)
        }
        #expect(try await Self.image(client, name) == "busybox:1.35")

        // A patch built from a stale read is refused by its generation test.
        let stale = try await client.get(Self.deployments, name: name, namespace: Self.namespace)
        _ = try await client.patch(Self.deployments, name: name, namespace: Self.namespace, type: .strategicMerge, body: Data(bump.utf8))
        let source = try await client.get(DeploymentRollout.replicaSets, name: first.replicaSet, namespace: Self.namespace)
        let stalePatch = try #require(try DeploymentRollout.rollbackPatch(deployment: stale, to: source))
        let conflict = await #expect(throws: KubeAPIError.self) {
            _ = try await client.patch(Self.deployments, name: name, namespace: Self.namespace, type: .json, body: stalePatch)
        }
        #expect(conflict.map(DeploymentRollout.isFailedTest) == true)
        #expect(try await Self.image(client, name) == "busybox:1.37")

        let current = try #require(DeploymentRollout.generation(of: try await client.get(Self.deployments, name: name, namespace: Self.namespace)))
        try await DeploymentRollout.rollback(client: client, namespace: Self.namespace, name: name, toReplicaSet: first.replicaSet,
                                             expectedGeneration: current)
        #expect(try await Self.image(client, name) == "busybox:1.36")
        let after = try await Self.waitForRevisions(client, name, count: 3)
        #expect(after.first?.images == ["busybox:1.36"])

        _ = try await client.patch(Self.deployments, name: name, namespace: Self.namespace, type: .merge, body: Data(#"{"spec":{"paused":true}}"#.utf8))
        let paused = try #require(DeploymentRollout.generation(of: try await client.get(Self.deployments, name: name, namespace: Self.namespace)))
        let other1 = try #require(after.last)
        await #expect(throws: RolloutError.paused) {
            try await DeploymentRollout.rollback(client: client, namespace: Self.namespace, name: name, toReplicaSet: other1.replicaSet,
                                                 expectedGeneration: paused)
        }
    }

    @Test func triggeredJobIsOwnedByTheCronJob() async throws {
        let client = try WatchCacheIntegrationTests.client()
        try await WatchCacheIntegrationTests.ensureNamespace(client)
        let name = "cluvia-it-cron"
        try? await client.delete(Self.cronJobs, name: name, namespace: Self.namespace)
        while (try? await client.get(Self.cronJobs, name: name, namespace: Self.namespace)) != nil { try await Task.sleep(for: .milliseconds(300)) }
        let manifest = """
        {"apiVersion":"batch/v1","kind":"CronJob","metadata":{"name":"\(name)"},"spec":{"schedule":"0 0 1 1 *","suspend":true,
         "jobTemplate":{"spec":{"template":{"spec":{"restartPolicy":"Never","containers":[{"name":"c","image":"busybox:1.36","command":["true"]}]}}}}}}
        """
        let cronJob = try await client.create(Self.cronJobs, namespace: Self.namespace, object: Unstructured(data: Data(manifest.utf8)))
        defer { Task { try? await client.delete(Self.cronJobs, name: name, namespace: Self.namespace, propagationPolicy: .background) } }

        let job = try await CronJobTrigger.trigger(client: client, cronJob: cronJob)
        #expect(job.ownerReferences.first?.uid == cronJob.uid)
        #expect(job.annotations["cronjob.kubernetes.io/instantiate"] == "manual")
        let owned = try await OwnedObjects.list(client: client, child: CronJobTrigger.jobs, parent: cronJob)
        #expect(owned.map(\.name) == [job.name])
    }
}
