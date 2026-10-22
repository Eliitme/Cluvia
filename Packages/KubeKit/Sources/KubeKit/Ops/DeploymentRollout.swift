import Foundation

/// One entry of a Deployment's rollout history: a ReplicaSet it owns and the template that ReplicaSet runs.
public struct DeploymentRevision: Sendable, Identifiable, Hashable {
    public let revision: Int
    public let replicaSet: String
    public let changeCause: String?
    public let images: [String]
    public let created: Date?

    public var id: Int { revision }
}

public enum RolloutError: Error, LocalizedError, Sendable, Equatable {
    case paused, alreadyCurrent, changed, revisionGone

    public var errorDescription: String? {
        switch self {
        case .paused: "The rollout is paused. Resume it before rolling back."
        case .alreadyCurrent: "The Deployment already runs this revision."
        case .changed: "The Deployment changed since the history was loaded. Reload the history and try again."
        case .revisionGone: "That revision no longer exists. Reload the history."
        }
    }
}

/// Rollout history and rollback the way `kubectl rollout history/undo` do them, over the API.
public enum DeploymentRollout {
    static let deployments = GroupVersionResource(group: "apps", version: "v1", resource: "deployments")
    static let replicaSets = GroupVersionResource(group: "apps", version: "v1", resource: "replicasets")
    static let revisionAnnotation = "deployment.kubernetes.io/revision"
    static let changeCauseAnnotation = "kubernetes.io/change-cause"
    /// Annotations the deployment controller manages itself; a rollback leaves them as they are (as kubectl does).
    static let controllerAnnotations: Set<String> = [
        "kubectl.kubernetes.io/last-applied-configuration", revisionAnnotation, "deployment.kubernetes.io/revision-history",
        "deployment.kubernetes.io/desired-replicas", "deployment.kubernetes.io/max-replicas", "deprecated.deployment.rollback.to",
    ]

    /// Newest first.
    public static func revisions(client: DynamicClient, deployment: Unstructured) async throws -> [DeploymentRevision] {
        guard let uid = deployment.uid else { return [] }
        let options = ListOptions(labelSelector: OwnedObjects.labelSelector(of: deployment))
        let owned = OwnedObjects.owned(try await client.list(replicaSets, namespace: deployment.namespace, options: options).items, by: uid)
        return owned.compactMap(revision).sorted { $0.revision > $1.revision }
    }

    static func revision(of replicaSet: Unstructured) -> DeploymentRevision? {
        guard let number = replicaSet.annotations[revisionAnnotation].flatMap(Int.init) else { return nil }
        let containers = replicaSet.json[path: "spec", "template", "spec", "containers"]?.arrayValue ?? []
        return DeploymentRevision(
            revision: number, replicaSet: replicaSet.name, changeCause: replicaSet.annotations[changeCauseAnnotation],
            images: containers.compactMap { $0["image"]?.stringValue }, created: replicaSet.creationTimestamp
        )
    }

    /// Rolls `name` back to the template of `replicaSet`. `expectedGeneration` is the Deployment's generation when the
    /// history was shown: if its spec changed since (someone deployed meanwhile), nothing is written. Generation, not
    /// resourceVersion, because status updates during a rollout change the latter many times a second.
    public static func rollback(client: DynamicClient, namespace: String, name: String, toReplicaSet replicaSet: String,
                                expectedGeneration: Int64) async throws {
        let deployment = try await client.get(deployments, name: name, namespace: namespace)
        guard generation(of: deployment) == expectedGeneration else { throw RolloutError.changed }
        let source: Unstructured
        do {
            source = try await client.get(replicaSets, name: replicaSet, namespace: namespace)
        } catch let error as KubeAPIError where error.statusCode == 404 {
            throw RolloutError.revisionGone
        }
        guard let patch = try rollbackPatch(deployment: deployment, to: source) else { throw RolloutError.alreadyCurrent }
        do {
            _ = try await client.patch(deployments, name: name, namespace: namespace, type: .json, body: patch)
        } catch let error as KubeAPIError where error.statusCode == 409 || isFailedTest(error) {
            throw RolloutError.changed
        }
    }

    public static func generation(of deployment: Unstructured) -> Int64? {
        deployment.json[path: "metadata", "generation"]?.intValue
    }

    /// The patch's `test` op failing, as opposed to the new template failing validation. Both are 422 Invalid; the
    /// server reports a failed test with no causes, while a validation error lists the offending fields.
    static func isFailedTest(_ error: KubeAPIError) -> Bool {
        error.statusCode == 422 && error.causes.isEmpty
    }

    /// JSON patch setting the deployment's template (without the ReplicaSet's `pod-template-hash` label) and its
    /// annotations to the ReplicaSet's, guarded by a `test` on the generation it was built from. nil when nothing
    /// would change.
    public static func rollbackPatch(deployment: Unstructured, to replicaSet: Unstructured) throws -> Data? {
        if deployment.json[path: "spec", "paused"] == .bool(true) { throw RolloutError.paused }
        guard let generation = generation(of: deployment), var template = replicaSet.json[path: "spec", "template"] else { return nil }
        template = removingHashLabel(template)
        let current = deployment.annotations.filter { !controllerAnnotations.contains($0.key) }
        let target = replicaSet.annotations.filter { !controllerAnnotations.contains($0.key) }
        if template == deployment.json[path: "spec", "template"], current == target { return nil }

        var ops: [JSONValue] = [
            op("test", "/metadata/generation", .int(generation)),
            op("replace", "/spec/template", template),
        ]
        if deployment.json[path: "metadata", "annotations"] == nil, !target.isEmpty {
            ops.append(op("add", "/metadata/annotations", .object([:])))
        }
        for key in current.keys.sorted() where target[key] == nil {
            ops.append(.object(["op": .string("remove"), "path": .string("/metadata/annotations/" + escaped(key))]))
        }
        for (key, value) in target.sorted(by: { $0.key < $1.key }) where current[key] != value {
            ops.append(op("add", "/metadata/annotations/" + escaped(key), .string(value)))
        }
        return try JSONEncoder().encode(JSONValue.array(ops))
    }

    static func removingHashLabel(_ template: JSONValue) -> JSONValue {
        guard case var .object(fields) = template, case var .object(metadata)? = fields["metadata"],
              case var .object(labels)? = metadata["labels"] else { return template }
        labels["pod-template-hash"] = nil
        metadata["labels"] = .object(labels)
        fields["metadata"] = .object(metadata)
        return .object(fields)
    }

    /// JSON pointer escaping (RFC 6901).
    static func escaped(_ key: String) -> String {
        key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }

    private static func op(_ name: String, _ path: String, _ value: JSONValue) -> JSONValue {
        .object(["op": .string(name), "path": .string(path), "value": value])
    }
}
