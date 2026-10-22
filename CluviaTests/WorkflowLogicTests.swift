import Foundation
import KubeKit
import Testing
@testable import Cluvia

struct FuzzyMatcherTests {
    @Test func subsequenceWithWordStartPreference() {
        #expect(FuzzyMatcher.score("dpl", in: "Deployments") != nil)
        #expect(FuzzyMatcher.score("xyz", in: "Deployments") == nil)
        let deployments = FuzzyMatcher.score("dep", in: "Deployments")!
        let endpoints = FuzzyMatcher.score("dep", in: "Endpoint Slices") ?? Int.min
        #expect(deployments > endpoints)
        #expect(FuzzyMatcher.score("cm", in: "ConfigMaps") != nil)
    }
}

struct LineDiffTests {
    @Test func reportsChangedLinesWithContext() {
        let old = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let new = old.replacingOccurrences(of: "line 10\n", with: "line ten\n")
        let lines = LineDiff.lines(from: old, to: new)
        #expect(lines.filter { $0.kind == .removed }.map(\.text) == ["line 10"])
        #expect(lines.filter { $0.kind == .added }.map(\.text) == ["line ten"])
        let hunks = LineDiff.hunks(lines)
        #expect(hunks.first == .some(nil))
        #expect(hunks.compactMap { $0 }.count == 8)
        #expect(LineDiff.hunks(LineDiff.lines(from: old, to: old)).isEmpty)
    }
}

struct LogBufferTests {
    static func lines(_ range: Range<Int>) -> [LogEntry] {
        range.map { LogEntry(LogLine(timestamp: nil, text: "line \($0)")) }
    }

    @Test func dropsOldestInChunksWithStableNumbers() {
        var buffer = LogBuffer(capacity: 100)
        buffer.append(Self.lines(0..<100))
        #expect(buffer.dropped == 0)
        buffer.append(Self.lines(100..<101))
        #expect(buffer.entries.count == 90)
        #expect(buffer.dropped == 11)
        #expect(buffer.endIndex == 101)
        #expect(buffer.entries(from: 5) == nil)
        #expect(buffer.entries(from: 100)?.first?.line.text == "line 100")
    }
}

struct ResourceActionTests {
    static func kind(_ name: String, namespaced: Bool = true) -> ResourceKind {
        ResourceKind(gvr: GroupVersionResource(group: ["Pod", "Node"].contains(name) ? "" : "apps", version: "v1", resource: name.lowercased() + "s"),
                     kind: name, title: name, namespaced: namespaced, category: .workloads)
    }

    @Test func actionsMatchKinds() {
        #expect(ResourceAction.available(for: Self.kind("Pod")) == [.logs, .shell, .portForward, .edit, .delete])
        #expect(ResourceAction.available(for: Self.kind("Deployment")) == [.logs, .edit, .scale, .restart, .delete])
        let service = Unstructured(.object(["spec": .object(["selector": .object(["app": .string("web"), "tier": .string("fe")])])]))
        #expect(ResourceActions.podSelector(of: service) == "app=web,tier=fe")
        let deployment = Unstructured(.object(["spec": .object(["selector": .object(["matchLabels": .object(["app": .string("web")])])])]))
        #expect(ResourceActions.podSelector(of: deployment) == "app=web")
        #expect(ResourceAction.available(for: Self.kind("Node", namespaced: false)) == [.edit, .cordon, .uncordon, .drain, .nodeShell, .delete])
        #expect(ResourceAction.allCases.filter { $0.route == .confirm } == [.restart, .cordon, .uncordon, .nodeShell])
        #expect(ResourceAction.allCases.filter { $0.route == .sheet } == [.portForward, .scale, .drain, .delete])
    }

    @Test func conflictAfterDeleteIsResolvedFromAFreshRead() {
        func object(uid: String, finalizers: [String]) -> Unstructured {
            Unstructured(.object(["metadata": .object(["uid": .string(uid), "finalizers": .array(finalizers.map(JSONValue.string))])]))
        }
        let outcome = ClusterSession.conflictOutcome
        #expect(outcome(nil, "u1", true, true) == .gone)
        #expect(outcome(object(uid: "u2", finalizers: []), "u1", true, true) == .replaced)
        #expect(outcome(object(uid: "u1", finalizers: []), "u1", true, true) == .finalizersAlreadyRemoved)
        // A conflict on the delete itself never counts as done, even with no finalizers left.
        #expect(outcome(object(uid: "u1", finalizers: []), "u1", true, false) == .unresolved)
        #expect(outcome(object(uid: "u1", finalizers: ["x"]), "u1", true, true) == .unresolved)
        #expect(outcome(object(uid: "u2", finalizers: []), nil, false, false) == .unresolved)
    }

    @Test func forceIsOfferedOnlyForPodsAndTerminatingObjects() {
        let configMap = ResourceKind(gvr: GroupVersionResource(group: "", version: "v1", resource: "configmaps"),
                                     kind: "ConfigMap", title: "ConfigMaps", namespaced: true, category: .config)
        let healthy = Unstructured(.object(["metadata": .object(["name": .string("a")])]))
        let terminating = Unstructured(.object(["metadata": .object([
            "name": .string("a"), "deletionTimestamp": .string("2026-10-21T00:00:00Z"),
            "finalizers": .array([.string("kubernetes.io/pvc-protection"), .string("example.com/cleanup")]),
        ])]))
        #expect(!ForceDelete.isOffered(kind: configMap, object: healthy))
        #expect(ForceDelete.isOffered(kind: configMap, object: terminating))
        #expect(ForceDelete.isOffered(kind: Self.kind("Pod"), object: healthy))
        #expect(ClusterSession.finalizers(of: terminating) == ["kubernetes.io/pvc-protection", "example.com/cleanup"])
        #expect(ForceDelete.consequence(of: "kubernetes.io/pvc-protection").severe)
        #expect(!ForceDelete.consequence(of: "example.com/cleanup").severe)
    }

    @Test func templatesParseAsManifests() throws {
        let yaml = YamlEditModel.template(for: Self.kind("Deployment"), namespace: "team")
        let manifest = try ResourceApplier.manifest(fromYAML: yaml.replacingOccurrences(of: "name: \n", with: "name: x\n"))
        #expect(manifest["kind"] == .string("Deployment"))
        #expect(manifest[path: "metadata", "namespace"] == .string("team"))
    }
}
