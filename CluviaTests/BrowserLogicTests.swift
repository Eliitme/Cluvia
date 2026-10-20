import Foundation
import KubeKit
import Testing
@testable import Cluvia

struct ResourceKindRegistryTests {
    static func info(_ group: String, _ resource: String, _ kind: String, namespaced: Bool = true, preferred: Bool = true) -> APIResourceInfo {
        APIResourceInfo(
            gvr: GroupVersionResource(group: group, version: "v1", resource: resource), kind: kind,
            namespaced: namespaced, verbs: ["list", "watch", "get"], shortNames: [], preferred: preferred
        )
    }

    @Test func builtInsInFixedOrderAndCustomResourcesSeparately() {
        let catalog = APIResourceCatalog(resources: [
            Self.info("cluvia.test", "widgets", "Widget"),
            Self.info("apps", "deployments", "Deployment"),
            Self.info("", "pods", "Pod"),
            Self.info("", "nodes", "Node", namespaced: false),
            Self.info("gateway.networking.k8s.io", "gateways", "Gateway"),
            Self.info("coordination.k8s.io", "leases", "Lease"),
            Self.info("events.k8s.io", "events", "Event"),
            Self.info("apps", "deployments", "Deployment", preferred: false),
        ])
        let kinds = ResourceKindRegistry.kinds(from: catalog)
        #expect(kinds.map(\.title) == ["Nodes", "Pods", "Deployments", "Widget", "Lease", "Gateway"])
        #expect(kinds.first { $0.kind == "Gateway" }?.category == .customResources)
        #expect(kinds.first { $0.kind == "Lease" }?.category == .other)
        #expect(kinds.first?.namespaced == false)
    }

    @Test func unwatchableResourcesAreSkipped() {
        var info = Self.info("", "pods", "Pod")
        info = APIResourceInfo(gvr: info.gvr, kind: info.kind, namespaced: true, verbs: ["get"], shortNames: [], preferred: true)
        #expect(ResourceKindRegistry.kinds(from: APIResourceCatalog(resources: [info])).isEmpty)
    }
}

struct RowFilterTests {
    static let columns = [
        ResourceTableColumn(name: "Name", type: "string", format: "name", priority: 0),
        ResourceTableColumn(name: "Status", type: "string", format: "", priority: 0),
    ]

    static func row(_ name: String, status: String, labels: [String: String] = [:]) -> ResourceTableRow {
        let metadata: [String: JSONValue] = [
            "name": .string(name), "namespace": .string("prod"),
            "labels": .object(labels.mapValues(JSONValue.string)),
        ]
        return ResourceTableRow(cells: [.string(name), .string(status)], object: Unstructured(.object(["metadata": .object(metadata)])))
    }

    @Test func matchesTermsAcrossNameCellsAndLabels() {
        let web = Self.row("web-1", status: "Running", labels: ["app": "web"])
        let db = Self.row("db-0", status: "CrashLoopBackOff")
        #expect(RowFilter("web").matches(web, columns: Self.columns))
        #expect(RowFilter("app=web").matches(web, columns: Self.columns))
        #expect(!RowFilter("app=web").matches(db, columns: Self.columns))
        #expect(RowFilter("status:crash").matches(db, columns: Self.columns))
        #expect(!RowFilter("status:running db").matches(db, columns: Self.columns))
        #expect(RowFilter("namespace:prod").matches(db, columns: Self.columns))
        #expect(RowFilter("  ").isEmpty)
    }
}

struct FormattingTests {
    @Test(arguments: [(30, "30s"), (150, "2m"), (3 * 3600 + 120, "3h2m"), (20 * 3600, "20h"), (3 * 86400 + 3600, "3d1h"), (400 * 86400, "400d")])
    func ages(seconds: Int, expected: String) {
        let now = Date()
        #expect(AgeFormatter.string(since: now.addingTimeInterval(-Double(seconds)), now: now) == expected)
    }

    @Test func secretValuesAreMaskedUntilRevealed() {
        let secret = JSONValue.object([
            "kind": .string("Secret"), "data": .object(["password": .string("aHVudGVyMg==")]),
            "metadata": .object(["name": .string("db")]),
        ])
        let masked = SecretMasking.masked(secret)
        #expect(masked[path: "data", "password"] == .string(SecretMasking.placeholder))
        #expect(masked[path: "metadata", "name"] == .string("db"))
        #expect(SecretMasking.decoded(.string("aHVudGVyMg==")) == "hunter2")
        #expect(SecretMasking.masked(.object(["kind": .string("ConfigMap"), "data": .object(["a": .string("b")])]))[path: "data", "a"] == .string("b"))

        // Client-side apply copies the whole Secret into an annotation.
        let applied = JSONValue.object([
            "kind": .string("Secret"),
            "metadata": .object(["annotations": .object([
                SecretMasking.lastAppliedAnnotation: .string(#"{"data":{"password":"aHVudGVyMg=="}}"#), "team": .string("db"),
            ])]),
        ])
        let maskedApplied = SecretMasking.masked(applied)
        #expect(maskedApplied[path: "metadata", "annotations", SecretMasking.lastAppliedAnnotation] == .string(SecretMasking.placeholder))
        #expect(maskedApplied[path: "metadata", "annotations", "team"] == .string("db"))
    }

    @Test(arguments: [("Running", "Status", StatusTone.good), ("CrashLoopBackOff", "Status", .bad), ("Pending", "Status", .pending), ("Running", "Name", .neutral)])
    func statusTones(value: String, column: String, tone: StatusTone) {
        #expect(StatusTone.of(value, column: column) == tone)
    }
}

@MainActor
struct AppSettingsStoreTests {
    @Test func persistsFavoritesAndNamespaces() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/settings.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = AppSettingsStore(fileURL: file)
        store.toggleFavorite("prod")
        store.setNamespaces(["a", "b"], for: "prod")
        let reloaded = AppSettingsStore(fileURL: file)
        #expect(reloaded.isFavorite("prod"))
        #expect(reloaded.namespaces(for: "prod") == ["a", "b"])
        reloaded.setNamespaces([], for: "prod")
        #expect(AppSettingsStore(fileURL: file).namespaces(for: "prod").isEmpty)
    }
}
