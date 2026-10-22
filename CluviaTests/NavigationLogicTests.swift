import Foundation
import KubeKit
import Testing
@testable import Cluvia

/// Back/Forward driven through a real session, so the order of its didSets is what gets tested.
@MainActor
struct NavigationLogicTests {
    static func kind(_ name: String, group: String = "apps") -> ResourceKind {
        ResourceKind(gvr: GroupVersionResource(group: group, version: "v1", resource: name.lowercased() + "s"),
                     kind: name, title: name, namespaced: true, category: .workloads)
    }

    static let pods = kind("Pod", group: "")
    static let replicaSets = kind("ReplicaSet")
    static let deployments = kind("Deployment")

    static func session() -> ClusterSession {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/settings.json")
        return ClusterSession(contextName: "test", settings: AppSettingsStore(fileURL: file))
    }

    static func key(_ name: String) -> ObjectKey { ObjectKey(namespace: "default", name: name) }

    @Test func backRestoresTheObjectSelectedBeforeFollowingAnOwner() {
        let session = Self.session()
        session.selectedKind = Self.pods
        session.selectedObject = Self.key("web-1")
        session.reveal(Self.replicaSets, Self.key("web-rs"))
        session.reveal(Self.deployments, Self.key("web"))
        session.goBack()
        #expect(session.selectedKind == Self.replicaSets && session.selectedObject == Self.key("web-rs"))
        session.goBack()
        #expect(session.selectedKind == Self.pods && session.selectedObject == Self.key("web-1"))
        #expect(!session.canGoBack)
        session.goForward()
        #expect(session.selectedKind == Self.replicaSets && session.selectedObject == Self.key("web-rs"))
    }

    @Test func movingWithinATableIsOneEntry() {
        let session = Self.session()
        session.selectedKind = Self.deployments
        session.selectedKind = Self.pods
        for index in 0..<50 { session.selectedObject = Self.key("pod-\(index)") }
        session.goBack()
        #expect(session.selectedKind == Self.deployments)
        session.goForward()
        #expect(session.selectedObject == Self.key("pod-49"))
    }

    @Test func leavingHelmByClickingTheSameKindIsRecorded() {
        let session = Self.session()
        session.selectedKind = Self.pods
        session.showingHelm = true
        session.selectedKind = Self.pods
        #expect(!session.showingHelm)
        session.goBack()
        #expect(session.showingHelm)
        session.goBack()
        #expect(!session.showingHelm && session.selectedKind == Self.pods)
    }

    @Test func helmThenAnotherKindGoesBackToHelm() {
        let session = Self.session()
        session.selectedKind = Self.pods
        session.showingHelm = true
        session.selectedKind = Self.deployments
        session.goBack()
        #expect(session.showingHelm)
    }

    @Test func revealInTheSameTableAddsAnEntry() {
        let session = Self.session()
        session.selectedKind = Self.pods
        session.selectedObject = Self.key("a")
        session.reveal(Self.pods, Self.key("b"))
        session.goBack()
        #expect(session.selectedObject == Self.key("a"))
    }

    @Test func childKindsAreGroupChecked() {
        #expect(OwnedObjectsRow.childKind(ofKind: "Deployment", apiVersion: "apps/v1")?.kind == "ReplicaSet")
        #expect(OwnedObjectsRow.childKind(ofKind: "CronJob", apiVersion: "batch/v1")?.kind == "Job")
        #expect(OwnedObjectsRow.childKind(ofKind: "Job", apiVersion: "batch/v1")?.kind == "Pod")
        #expect(OwnedObjectsRow.childKind(ofKind: "Deployment", apiVersion: "example.com/v1") == nil)
        #expect(OwnedObjectsRow.childKind(ofKind: "Pod", apiVersion: "v1") == nil)
    }

    @Test func childrenReloadOnReplicaChangesButNotOnEveryStatusUpdate() {
        func replicaSet(replicas: Int, observed: Int) -> Unstructured {
            Unstructured(.object([
                "metadata": .object(["uid": .string("u1"), "generation": .int(3)]),
                "status": .object(["replicas": .int(Int64(replicas)), "observedGeneration": .int(Int64(observed))]),
            ]))
        }
        let base = OwnedObjectsRow.reloadKey(of: replicaSet(replicas: 2, observed: 2))
        #expect(OwnedObjectsRow.reloadKey(of: replicaSet(replicas: 2, observed: 3)) == base)
        #expect(OwnedObjectsRow.reloadKey(of: replicaSet(replicas: 3, observed: 2)) != base)
    }

    @Test func historyIsCappedAndDropsForwardOnVisit() {
        var history = NavigationHistory()
        for index in 0..<60 { history.visit(.kind(Self.pods, Self.key("\(index)"))) }
        #expect(history.entries.count == NavigationHistory.capacity)
        _ = history.back()
        history.visit(.helm)
        #expect(!history.canGoForward)
        history.visit(.helm)
        #expect(history.entries.count == NavigationHistory.capacity)
    }
}
