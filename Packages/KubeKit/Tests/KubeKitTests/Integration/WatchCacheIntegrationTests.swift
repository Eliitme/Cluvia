import Foundation
import Testing
@testable import KubeKit

@Suite(.enabled(if: IntegrationCluster.isEnabled, "set CLUVIA_IT_CONTEXT to run against a real cluster"), .serialized)
struct WatchCacheIntegrationTests {
    static let namespace = "cluvia-it"
    static let configMaps = GroupVersionResource(group: "", version: "v1", resource: "configmaps")

    static func client() throws -> DynamicClient {
        DynamicClient(transport: try IntegrationCluster.transport())
    }

    static func ensureNamespace(_ client: DynamicClient) async throws {
        do {
            _ = try await client.get(.namespaces, name: namespace)
        } catch let error as KubeAPIError where error.statusCode == 404 {
            _ = try await client.create(.namespaces, object: Unstructured(.object([
                "apiVersion": .string("v1"), "kind": .string("Namespace"),
                "metadata": .object(["name": .string(namespace)]),
            ])))
        }
    }

    static func configMap(_ name: String) -> Unstructured {
        Unstructured(.object([
            "apiVersion": .string("v1"), "kind": .string("ConfigMap"),
            "metadata": .object(["name": .string(name)]), "data": .object(["k": .string("v")]),
        ]))
    }

    /// Polls `condition` on the main actor; returns the elapsed time once it holds.
    @MainActor
    static func elapsed(until condition: @MainActor () -> Bool, timeout: Duration = .seconds(10)) async throws -> Duration {
        let clock = ContinuousClock()
        let start = clock.now
        while !condition() {
            guard clock.now - start < timeout else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
        return clock.now - start
    }

    @Test func aggregatedDiscoveryMatchesLegacyWalk() async throws {
        let transport = try IntegrationCluster.transport()
        let aggregated = try await APIDiscovery.discover(transport: transport, allowAggregated: true)
        let legacy = try await APIDiscovery.discover(transport: transport, allowAggregated: false)
        #expect(Set(aggregated.preferred.map(\.gvr)) == Set(legacy.preferred.map(\.gvr)))
        #expect(aggregated.resource(matching: "deploy")?.kind == "Deployment")
    }

    @MainActor
    @Test func storeReflectsCreateAndDeleteWithinOneSecond() async throws {
        let client = try Self.client()
        try await Self.ensureNamespace(client)
        let registry = ResourceStoreRegistry(client: client)
        let store = registry.acquire(Self.configMaps, namespace: Self.namespace)
        defer { registry.release(Self.configMaps, namespace: Self.namespace) }
        _ = try await Self.elapsed { store.phase == .live }

        let name = "cluvia-it-\(UUID().uuidString.prefix(8).lowercased())"
        let has: @MainActor () -> Bool = { store.items.contains { $0.object.name == name } }
        _ = try await client.create(Self.configMaps, namespace: Self.namespace, object: Self.configMap(name))
        let appeared = try await Self.elapsed(until: has)
        try await client.delete(Self.configMaps, name: name, namespace: Self.namespace)
        let disappeared = try await Self.elapsed { !has() }

        #expect(appeared < .seconds(1), "create took \(appeared)")
        #expect(disappeared < .seconds(1), "delete took \(disappeared)")
        #expect(store.columns.first?.name == "Name")
        #expect(registry.activeCount == 1)
    }

    @Test func customResourcesUseServerPrinterColumns() async throws {
        let client = try Self.client()
        try await Self.ensureNamespace(client)
        let crdName = "widgets.cluvia.test"
        let crd = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"apiVersion":"apiextensions.k8s.io/v1","kind":"CustomResourceDefinition","metadata":{"name":"\(crdName)"},
         "spec":{"group":"cluvia.test","scope":"Namespaced",
          "names":{"plural":"widgets","singular":"widget","kind":"Widget","shortNames":["wdg"]},
          "versions":[{"name":"v1","served":true,"storage":true,
            "schema":{"openAPIV3Schema":{"type":"object","properties":{"spec":{"type":"object",
              "properties":{"color":{"type":"string"}}}}}},
            "additionalPrinterColumns":[{"name":"Color","type":"string","jsonPath":".spec.color"}]}]}}
        """.utf8))
        _ = try await client.apply(.customResourceDefinitions, name: crdName, manifest: try Unstructured(crd).data(), force: true)

        let discovery = APIDiscovery(transport: client.transport)
        var widgets: APIResourceInfo?
        for _ in 0..<30 where widgets == nil {
            widgets = try await discovery.refresh().resource(matching: "wdg")
            if widgets == nil { try await Task.sleep(for: .seconds(1)) }
        }
        let gvr = try #require(widgets).gvr
        let instance = #"{"apiVersion":"cluvia.test/v1","kind":"Widget","metadata":{"name":"blue-one"},"spec":{"color":"blue"}}"#
        _ = try await client.apply(gvr, name: "blue-one", namespace: Self.namespace, manifest: Data(instance.utf8), force: true)

        let table = try await client.listTable(gvr, namespace: Self.namespace)
        let colorColumn = try #require(table.columns.firstIndex { $0.name == "Color" })
        let row = try #require(table.rows.first { $0.object.name == "blue-one" })
        #expect(row.cells[colorColumn].stringValue == "blue")
    }

    /// Restarts the API server container (opt-in: `CLUVIA_IT_DISRUPT=1`, kind only) and checks the store recovers.
    @MainActor
    @Test(.enabled(if: IntegrationCluster.environment["CLUVIA_IT_DISRUPT"] == "1"))
    func recoversAfterApiServerRestart() async throws {
        let client = try Self.client()
        try await Self.ensureNamespace(client)
        let registry = ResourceStoreRegistry(client: client)
        let store = registry.acquire(Self.configMaps, namespace: Self.namespace)
        defer { registry.release(Self.configMaps, namespace: Self.namespace) }
        _ = try await Self.elapsed { store.phase == .live }
        let before = store.items.count

        let docker = try #require(await LoginShellEnvironment.shared.resolveExecutable("docker"))
        let node = (IntegrationCluster.contextName ?? "").replacingOccurrences(of: "kind-", with: "") + "-control-plane"
        _ = try await ProcessRunner.run(docker, arguments: ["restart", node], timeout: .seconds(120))
        _ = try await Self.elapsed(until: { if case .reconnecting = store.phase { true } else { false } }, timeout: .seconds(60))

        let name = "cluvia-it-after-restart"
        var created = false
        for _ in 0..<60 where !created {
            created = (try? await client.create(Self.configMaps, namespace: Self.namespace, object: Self.configMap(name))) != nil
            if !created { try await Task.sleep(for: .seconds(2)) }
        }
        let recovered = try await Self.elapsed(until: { store.items.contains { $0.object.name == name } }, timeout: .seconds(90))
        #expect(store.phase == .live)
        #expect(Set(store.items.map(\.id)).count == store.items.count)
        #expect(store.items.count == before + 1)
        print("recovered \(recovered) after restart")
        try await client.delete(Self.configMaps, name: name, namespace: Self.namespace)
    }
}
