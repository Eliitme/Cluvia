import Foundation
import Testing
@testable import KubeKit

struct NodeDrainerTests {
    static func pod(owner: String? = nil, mirror: Bool = false, emptyDir: Bool = false, phase: String = "Running") -> Unstructured {
        var metadata: [String: JSONValue] = ["name": .string("p"), "namespace": .string("ns")]
        if let owner {
            metadata["ownerReferences"] = .array([.object(["kind": .string(owner), "name": .string("o"), "controller": .bool(true)])])
        }
        if mirror { metadata["annotations"] = .object(["kubernetes.io/config.mirror": .string("x")]) }
        let volumes: [JSONValue] = emptyDir ? [.object(["name": .string("tmp"), "emptyDir": .object([:])])] : []
        return Unstructured(.object([
            "metadata": .object(metadata), "spec": .object(["volumes": .array(volumes)]),
            "status": .object(["phase": .string(phase)]),
        ]))
    }

    @Test func classifiesLikeKubectlDrain() {
        let defaults = DrainOptions()
        #expect(NodeDrainer.classify(Self.pod(owner: "ReplicaSet"), options: defaults) == .evict)
        #expect(NodeDrainer.classify(Self.pod(owner: "DaemonSet"), options: defaults) == .skip("managed by a DaemonSet"))
        #expect(NodeDrainer.classify(Self.pod(mirror: true), options: defaults) == .skip("static pod managed by the kubelet"))
        #expect(NodeDrainer.classify(Self.pod(), options: defaults) == .refuse("not managed by a controller (use force)"))
        #expect(NodeDrainer.classify(Self.pod(phase: "Succeeded"), options: defaults) == .evict)
        if case .refuse = NodeDrainer.classify(Self.pod(owner: "ReplicaSet", emptyDir: true), options: defaults) {} else {
            Issue.record("emptyDir pods need explicit consent")
        }
        var permissive = DrainOptions()
        permissive.force = true
        permissive.deleteEmptyDirData = true
        permissive.ignoreDaemonSets = false
        #expect(NodeDrainer.classify(Self.pod(emptyDir: true), options: permissive) == .evict)
        if case .refuse = NodeDrainer.classify(Self.pod(owner: "DaemonSet"), options: permissive) {} else {
            Issue.record("DaemonSet pods are refused when not ignored")
        }
    }

    @Test func nodeShellPodNamesAreValidLabels() {
        let name = NodeShellPod.podName(node: "ip-10-0-1-23.eu-west-1.compute.internal")
        #expect(name.hasPrefix("node-shell-ip-10-0-1-23-eu-west-1-compu"))
        #expect(name.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" } && !name.contains("--"))
    }
}
