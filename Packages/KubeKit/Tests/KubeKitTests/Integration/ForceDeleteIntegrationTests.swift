import Foundation
import Testing
@testable import KubeKit

@Suite(.enabled(if: IntegrationCluster.isEnabled, "set CLUVIA_IT_CONTEXT to run against a real cluster"), .serialized)
struct ForceDeleteIntegrationTests {
    static let namespace = WatchCacheIntegrationTests.namespace
    static let configMaps = WatchCacheIntegrationTests.configMaps

    static func removeFinalizers(uid: String) throws -> Data { try DynamicClient.finalizerRemovalPatch(uid: uid) }

    static func createStuckConfigMap(_ client: DynamicClient, name: String) async throws -> Unstructured {
        try? await client.delete(configMaps, name: name, namespace: namespace, propagationPolicy: nil)
        if let old = try? await client.get(configMaps, name: name, namespace: namespace), let uid = old.uid {
            _ = try? await client.patch(configMaps, name: name, namespace: namespace, type: .json, body: removeFinalizers(uid: uid))
        }
        while (try? await client.get(configMaps, name: name, namespace: namespace)) != nil { try await Task.sleep(for: .milliseconds(200)) }
        let manifest = """
        {"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"\(name)","finalizers":["cluvia.dev/test"]}}
        """
        return try await client.create(configMaps, namespace: namespace, object: Unstructured(data: Data(manifest.utf8)))
    }

    @Test func finalizerRemovalPinnedToUIDReleasesStuckObject() async throws {
        let client = try WatchCacheIntegrationTests.client()
        try await WatchCacheIntegrationTests.ensureNamespace(client)
        let name = "cluvia-it-stuck"
        let created = try await Self.createStuckConfigMap(client, name: name)
        let uid = try #require(created.uid)

        try await client.delete(Self.configMaps, name: name, namespace: Self.namespace, preconditionUID: uid)
        let terminating = try await client.get(Self.configMaps, name: name, namespace: Self.namespace)
        #expect(terminating.json[path: "metadata", "deletionTimestamp"] != nil)

        // A stale uid must not touch the object.
        let stale = await #expect(throws: KubeAPIError.self) {
            _ = try await client.patch(Self.configMaps, name: name, namespace: Self.namespace, type: .json,
                                       body: Self.removeFinalizers(uid: "00000000-0000-0000-0000-000000000000"))
        }
        #expect(stale?.statusCode == 422)

        _ = try await client.patch(Self.configMaps, name: name, namespace: Self.namespace, type: .json, body: Self.removeFinalizers(uid: uid))
        let deadline = Date().addingTimeInterval(5)
        while (try? await client.get(Self.configMaps, name: name, namespace: Self.namespace)) != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect((try? await client.get(Self.configMaps, name: name, namespace: Self.namespace)) == nil)
    }

    @Test func deleteWithStaleUIDPreconditionIsRefused() async throws {
        let client = try WatchCacheIntegrationTests.client()
        try await WatchCacheIntegrationTests.ensureNamespace(client)
        let name = "cluvia-it-precondition"
        try? await client.delete(Self.configMaps, name: name, namespace: Self.namespace, propagationPolicy: nil)
        while (try? await client.get(Self.configMaps, name: name, namespace: Self.namespace)) != nil { try await Task.sleep(for: .milliseconds(200)) }
        let manifest = #"{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"\#(name)"}}"#
        _ = try await client.create(Self.configMaps, namespace: Self.namespace, object: Unstructured(data: Data(manifest.utf8)))

        let error = await #expect(throws: KubeAPIError.self) {
            try await client.delete(Self.configMaps, name: name, namespace: Self.namespace,
                                    preconditionUID: "00000000-0000-0000-0000-000000000000")
        }
        #expect(error?.statusCode == 409)
        #expect((try? await client.get(Self.configMaps, name: name, namespace: Self.namespace)) != nil)
        try await client.delete(Self.configMaps, name: name, namespace: Self.namespace)
    }

    @Test func podWithLongGracePeriodGoesAwayWithGraceZero() async throws {
        let client = try WatchCacheIntegrationTests.client()
        try await WatchCacheIntegrationTests.ensureNamespace(client)
        let name = "cluvia-it-grace"
        try? await client.delete(.pods, name: name, namespace: Self.namespace, propagationPolicy: nil, gracePeriodSeconds: 0)
        while (try? await client.get(.pods, name: name, namespace: Self.namespace)) != nil { try await Task.sleep(for: .milliseconds(300)) }
        let pod = """
        {"apiVersion":"v1","kind":"Pod","metadata":{"name":"\(name)"},"spec":{"terminationGracePeriodSeconds":300,
         "containers":[{"name":"main","image":"busybox:1.36","command":["sh","-c","trap '' TERM; sleep 3600"]}]}}
        """
        let created = try await client.create(.pods, namespace: Self.namespace, object: Unstructured(data: Data(pod.utf8)))

        try await client.delete(.pods, name: name, namespace: Self.namespace, gracePeriodSeconds: 0, preconditionUID: created.uid)
        let deadline = Date().addingTimeInterval(15)
        while (try? await client.get(.pods, name: name, namespace: Self.namespace)) != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(300))
        }
        #expect((try? await client.get(.pods, name: name, namespace: Self.namespace)) == nil)
    }
}
