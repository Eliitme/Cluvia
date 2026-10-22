import Foundation
import Testing
@testable import KubeKit

struct RolloutAndCronJobTests {
    static func object(_ json: String) throws -> Unstructured { try Unstructured(data: Data(json.utf8)) }

    static let deployment = """
    {"metadata":{"name":"web","resourceVersion":"42","generation":7,"annotations":{"deployment.kubernetes.io/revision":"2",
      "kubernetes.io/change-cause":"bump to 1.26","team":"web"}},
     "spec":{"template":{"metadata":{"labels":{"app":"web"}},"spec":{"containers":[{"name":"c","image":"nginx:1.26"}]}}}}
    """
    static let revisionOne = """
    {"metadata":{"name":"web-abc","annotations":{"deployment.kubernetes.io/revision":"1","kubernetes.io/change-cause":"first",
      "example.com/a/b":"x~y"}},
     "spec":{"template":{"metadata":{"labels":{"app":"web","pod-template-hash":"abc"}},"spec":{"containers":[{"name":"c","image":"nginx:1.25"}]}}}}
    """

    @Test func rollbackPatchMirrorsKubectlUndo() throws {
        let patch = try #require(try DeploymentRollout.rollbackPatch(deployment: Self.object(Self.deployment), to: Self.object(Self.revisionOne)))
        let ops = try #require(try JSONDecoder().decode(JSONValue.self, from: patch).arrayValue)
        #expect(ops.first == .object(["op": .string("test"), "path": .string("/metadata/generation"), "value": .int(7)]))
        #expect(ops[1]["path"] == .string("/spec/template"))
        #expect(ops[1][path: "value", "metadata", "labels"] == .object(["app": .string("web")]))
        #expect(ops[1][path: "value", "spec", "containers"]?.arrayValue?.first?["image"] == .string("nginx:1.25"))
        let annotationOps = ops.dropFirst(2).map { "\($0["op"]?.stringValue ?? "") \($0["path"]?.stringValue ?? "")" }
        #expect(annotationOps == [
            "remove /metadata/annotations/team",
            "add /metadata/annotations/example.com~1a~1b",
            "add /metadata/annotations/kubernetes.io~1change-cause",
        ])
        // The controller's own revision annotation is never touched.
        #expect(!annotationOps.contains { $0.contains("deployment.kubernetes.io") })
    }

    @Test func rollbackToTheCurrentTemplateIsNothing() throws {
        let current = try Self.object(Self.deployment)
        let sameRS = try Self.object("""
        {"metadata":{"name":"web-def","annotations":{"deployment.kubernetes.io/revision":"2","kubernetes.io/change-cause":"bump to 1.26","team":"web"}},
         "spec":{"template":{"metadata":{"labels":{"app":"web","pod-template-hash":"def"}},"spec":{"containers":[{"name":"c","image":"nginx:1.26"}]}}}}
        """)
        #expect(try DeploymentRollout.rollbackPatch(deployment: current, to: sameRS) == nil)
    }

    @Test func pausedDeploymentIsNotRolledBack() throws {
        let paused = try Self.object(#"{"metadata":{"name":"web","generation":1},"spec":{"paused":true,"template":{}}}"#)
        #expect(throws: RolloutError.paused) { try DeploymentRollout.rollbackPatch(deployment: paused, to: Self.object(Self.revisionOne)) }
    }

    @Test func addsAnAnnotationsMapWhenThereIsNone() throws {
        let bare = try Self.object(#"{"metadata":{"name":"web","generation":1},"spec":{"template":{}}}"#)
        let patch = try #require(try DeploymentRollout.rollbackPatch(deployment: bare, to: Self.object(Self.revisionOne)))
        let ops = try #require(try JSONDecoder().decode(JSONValue.self, from: patch).arrayValue)
        #expect(ops[2] == .object(["op": .string("add"), "path": .string("/metadata/annotations"), "value": .object([:])]))
    }

    @Test func revisionReadsHistoryFields() throws {
        let revision = try #require(DeploymentRollout.revision(of: Self.object(Self.revisionOne)))
        #expect(revision.revision == 1 && revision.changeCause == "first" && revision.images == ["nginx:1.25"])
    }

    @Test func manualJobFromCronJob() throws {
        let cronJob = try Self.object("""
        {"apiVersion":"batch/v1","kind":"CronJob","metadata":{"name":"report","namespace":"ops","uid":"u1"},
         "spec":{"jobTemplate":{"metadata":{"labels":{"app":"report"},"annotations":{"team":"ops"}},
           "spec":{"template":{"spec":{"restartPolicy":"Never","containers":[{"name":"c","image":"busybox"}]}}}}}}
        """)
        let job = CronJobTrigger.jobManifest(cronJob: cronJob, name: "report-manual-abcde")
        #expect(job[path: "metadata", "annotations"] == .object(["team": .string("ops"), "cronjob.kubernetes.io/instantiate": .string("manual")]))
        #expect(job[path: "metadata", "labels"] == .object(["app": .string("report")]))
        #expect(job[path: "metadata", "namespace"] == .string("ops"))
        let owner = try #require(job[path: "metadata", "ownerReferences"]?.arrayValue?.first)
        #expect(owner["uid"] == .string("u1") && owner["controller"] == .bool(true) && owner["kind"] == .string("CronJob"))
        #expect(owner["blockOwnerDeletion"] == nil)
        #expect(job[path: "spec", "template", "spec", "restartPolicy"] == .string("Never"))
    }

    @Test func jobNamesFitALabel() {
        let long = String(repeating: "a", count: 80)
        let name = CronJobTrigger.jobName(for: long, suffix: "x1y2z")
        #expect(name.count == 63 && name.hasSuffix("-manual-x1y2z"))
        #expect(CronJobTrigger.jobName(for: "report").wholeMatch(of: /report-manual-[a-z0-9]{5}/) != nil)
        #expect(CronJobTrigger.jobName(for: String(repeating: "a", count: 49) + ".b", suffix: "x1y2z") == String(repeating: "a", count: 49) + "-manual-x1y2z")
    }

    @Test func onlyTheGenerationTestCountsAsAConcurrentChange() {
        // Bodies as the API server sends them.
        let failedTest = KubeAPIError(statusCode: 422, body: Data(#"{"kind":"Status","status":"Failure","message":"the server rejected our request due to an error in our request","reason":"Invalid","details":{},"code":422}"#.utf8))
        let invalidTemplate = KubeAPIError(statusCode: 422, body: Data(#"{"kind":"Status","message":"Deployment.apps \"web\" is invalid: spec.template.spec.containers[0].image: Required value","reason":"Invalid","details":{"name":"web","causes":[{"reason":"FieldValueRequired","message":"Required value","field":"spec.template.spec.containers[0].image"}]},"code":422}"#.utf8))
        #expect(DeploymentRollout.isFailedTest(failedTest))
        #expect(!DeploymentRollout.isFailedTest(invalidTemplate))
    }
}
