import Darwin
import Foundation
import Testing
@testable import KubeKit

/// Budget check against a namespace holding ~5k pods. Opt-in: `CLUVIA_IT_SCALE_NAMESPACE=<namespace>`.
/// Footprint is process-wide, so run it on its own (`--filter WatchCacheScale`) for a meaningful number.
@Suite(.enabled(if: IntegrationCluster.isEnabled && IntegrationCluster.environment["CLUVIA_IT_SCALE_NAMESPACE"] != nil))
struct WatchCacheScaleIntegrationTests {
    static var namespace: String { IntegrationCluster.environment["CLUVIA_IT_SCALE_NAMESPACE"] ?? "" }

    /// Physical footprint of this process (what Activity Monitor reports as Memory).
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    @MainActor
    @Test func fiveThousandPodsStayWithinBudget() async throws {
        let client = DynamicClient(transport: try IntegrationCluster.transport())
        let registry = ResourceStoreRegistry(client: client)
        defer { registry.releaseAll() }
        let baseline = Self.footprintMB()

        let clock = ContinuousClock()
        let start = clock.now
        let store = registry.acquire(.pods, namespace: Self.namespace)
        let listed = try await WatchCacheIntegrationTests.elapsed(until: { store.items.count >= 5000 }, timeout: .seconds(60))
        let footprint = Self.footprintMB() - baseline

        // Churn: label 200 pods while a probe pod change is timed end-to-end.
        let patch = Data(#"{"metadata":{"labels":{"churn":"1"}}}"#.utf8)
        let targets = store.items.prefix(200).map(\.object.name)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for name in targets {
                group.addTask { _ = try await client.patch(.pods, name: name, namespace: Self.namespace, type: .merge, body: patch) }
            }
            try await group.waitForAll()
        }
        let probe = try #require(store.items.last?.object.name)
        let probeStart = clock.now
        _ = try await client.patch(.pods, name: probe, namespace: Self.namespace, type: .merge, body: Data(#"{"metadata":{"labels":{"probe":"1"}}}"#.utf8))
        let propagated = try await WatchCacheIntegrationTests.elapsed(until: {
            store.items.last?.object.labels["probe"] == "1"
        })
        print("scale: \(store.items.count) rows, list+first snapshot \(listed), footprint +\(Int(footprint))MB, probe \(clock.now - probeStart) (\(propagated))")
        #expect(clock.now - start < .seconds(30))
        #expect(listed < .seconds(2))
        #expect(footprint < 60, "store footprint \(footprint)MB")
        #expect(propagated < .seconds(1))
    }
}
