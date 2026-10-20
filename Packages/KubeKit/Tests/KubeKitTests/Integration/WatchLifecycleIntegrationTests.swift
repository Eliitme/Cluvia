import Foundation
import Testing
@testable import KubeKit

/// Verifies on the API server itself (long-running request metrics) that releasing a store closes its watch.
@Suite(.enabled(if: IntegrationCluster.isEnabled, "set CLUVIA_IT_CONTEXT to run against a real cluster"), .serialized)
struct WatchLifecycleIntegrationTests {
    /// A resource no other suite watches, so parallel suites cannot skew the server-side counts.
    static let limitRanges = GroupVersionResource(group: "", version: "v1", resource: "limitranges")

    /// Open WATCH requests for core `resource`, keyed by scope (`cluster` / `namespace`).
    static func openWatches(_ transport: KubeTransport, resource: String) async throws -> [String: Int] {
        let (data, _) = try await transport.data(KubeRequest(path: "/metrics", accept: "text/plain"))
        var result: [String: Int] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n")
        where line.hasPrefix("apiserver_longrunning_requests{") && line.contains(#"verb="WATCH""#)
            && line.contains(#"group="""#) && line.contains(#"resource="\#(resource)""#) && line.contains(#"subresource="""#) {
            guard let scope = line.range(of: #"scope=""#).map({ line[$0.upperBound...].prefix { $0 != "\"" } }),
                  let value = line.split(separator: " ").last.flatMap({ Double($0) }) else { continue }
            result[String(scope), default: 0] += Int(value)
        }
        return result
    }

    @MainActor
    @Test func releasingStoresClosesServerWatches() async throws {
        let client = DynamicClient(transport: try IntegrationCluster.transport())
        try await WatchCacheIntegrationTests.ensureNamespace(client)
        let registry = ResourceStoreRegistry(client: client)
        let baseline = try await Self.openWatches(client.transport, resource: "limitranges")

        let namespaced = registry.acquire(Self.limitRanges, namespace: WatchCacheIntegrationTests.namespace)
        let clusterWide = registry.acquire(Self.limitRanges)
        _ = try await WatchCacheIntegrationTests.elapsed { namespaced.phase == .live && clusterWide.phase == .live }
        // Watches open right after the list; give the server a moment to register them.
        try await Task.sleep(for: .milliseconds(500))
        let open = try await Self.openWatches(client.transport, resource: "limitranges")
        #expect(open["namespace", default: 0] == baseline["namespace", default: 0] + 1, "open \(open) baseline \(baseline)")
        #expect(open["cluster", default: 0] == baseline["cluster", default: 0] + 1, "open \(open) baseline \(baseline)")

        registry.release(Self.limitRanges, namespace: WatchCacheIntegrationTests.namespace)
        registry.release(Self.limitRanges)
        try await Task.sleep(for: .seconds(1))
        let after = try await Self.openWatches(client.transport, resource: "limitranges")
        #expect(after == baseline, "after \(after) baseline \(baseline)")
        #expect(registry.activeCount == 0)
    }
}
