import Foundation
import Testing
@testable import KubeKit

struct WatchEventParsingTests {
    @Test func tableWatchSequenceFromRealCluster() throws {
        let events = try KindFixture.lines("watch-table-configmaps.jsonl").map { try WatchEventParser.parse($0, omittingKeys: ResourceTable.omittedKeys) }
        let converted = try events.flatMap(TableListWatchSource.convert)

        var upserts = 0, deletes = 0, bookmarks = 0
        for event in converted {
            switch event {
            case let .upsert(key, row, version):
                upserts += 1
                #expect(key == ObjectKey(namespace: "default", name: "cluvia-fixture"))
                #expect(row.cells.first?.stringValue == "cluvia-fixture")
                #expect(version != nil)
            case let .delete(key, _):
                deletes += 1
                #expect(key.name == "cluvia-fixture")
            case let .bookmark(version):
                bookmarks += 1
                #expect(!version.isEmpty)
            case .expired:
                Issue.record("unexpected expiry")
            }
        }
        #expect(upserts == 2)
        #expect(deletes == 1)
        // Bookmarks carry a placeholder row; they must never surface as data.
        #expect(bookmarks >= 1)
    }

    @Test func expiredStatusBecomesRelistSignal() throws {
        let event = try WatchEventParser.parse(try #require(KindFixture.lines("watch-expired.jsonl").first))
        guard case let .error(error) = event else {
            Issue.record("expected error event")
            return
        }
        #expect(error.statusCode == 410)
        #expect(error.reason == "Expired")
        let converted = try TableListWatchSource.convert(event)
        guard case .expired = converted.first else {
            Issue.record("expected expired")
            return
        }
    }

    @Test func otherErrorStatusesThrow() throws {
        let line = #"{"type":"ERROR","object":{"kind":"Status","code":500,"message":"boom"}}"#
        #expect(throws: KubeAPIError.self) { try TableListWatchSource.convert(try WatchEventParser.parse(line)) }
    }

    @Test(arguments: ["not json", #"{"object":{}}"#, #"{"type":"WHAT","object":{}}"#])
    func malformedLinesAreRejected(line: String) {
        #expect(throws: WatchEventError.self) { try WatchEventParser.parse(line) }
    }
}

struct DiscoveryDecodingTests {
    @Test func aggregatedDiscoveryFromRealCluster() throws {
        let resources = DiscoveryDecoding.aggregated(try KindFixture.json("aggregated-core.json"))
            + DiscoveryDecoding.aggregated(try KindFixture.json("aggregated-groups.json"))
        let catalog = APIResourceCatalog(resources: resources)

        let pods = try #require(catalog.resource(matching: "po"))
        #expect(pods.gvr == .pods)
        #expect(pods.kind == "Pod" && pods.namespaced && pods.isWatchable)
        #expect(catalog.resource(forKind: "Deployment")?.gvr == GroupVersionResource(group: "apps", version: "v1", resource: "deployments"))
        #expect(catalog.resource(matching: "nodes")?.namespaced == false)
        #expect(!resources.contains { $0.gvr.resource.contains("/") })
        #expect(catalog.resource(matching: "deploy")?.kind == "Deployment")
    }

    @Test func legacyDiscoverySkipsSubresources() throws {
        let resources = DiscoveryDecoding.legacy(try KindFixture.json("legacy-core-v1.json"), group: "", version: "v1", preferred: true)
        #expect(resources.contains { $0.gvr == .pods && $0.shortNames == ["po"] })
        #expect(!resources.contains { $0.gvr.resource.contains("/") })
        #expect(resources.allSatisfy { $0.preferred })
    }
}
