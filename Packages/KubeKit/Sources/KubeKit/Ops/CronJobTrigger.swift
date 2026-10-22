import Foundation

/// Runs a CronJob now, as `kubectl create job --from=cronjob/<name>` does: a Job from its template, owned by the
/// CronJob (so its history limits clean it up) and marked as started by hand.
public enum CronJobTrigger {
    static let jobs = GroupVersionResource(group: "batch", version: "v1", resource: "jobs")
    static let manualAnnotation = "cronjob.kubernetes.io/instantiate"

    /// Creates the Job and returns it.
    public static func trigger(client: DynamicClient, cronJob: Unstructured) async throws -> Unstructured {
        let job = jobManifest(cronJob: cronJob, name: jobName(for: cronJob.name))
        return try await client.create(jobs, namespace: cronJob.namespace, object: Unstructured(job))
    }

    /// `<cronjob>-manual-<5 random>`, at most 63 characters (the Job name is copied into a pod label).
    static func jobName(for cronJob: String, suffix: String = randomSuffix()) -> String {
        var base = String(cronJob.prefix(63 - "-manual-".count - suffix.count))
        // Cutting the name must not leave it ending in "." or "-" (invalid before "-manual-").
        while let last = base.last, last == "." || last == "-" { base.removeLast() }
        return "\(base)-manual-\(suffix)"
    }

    static func randomSuffix() -> String {
        String((0..<5).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
    }

    static func jobManifest(cronJob: Unstructured, name: String) -> JSONValue {
        let template = cronJob.json[path: "spec", "jobTemplate"]
        var annotations = template?[path: "metadata", "annotations"]?.objectValue ?? [:]
        annotations[manualAnnotation] = .string("manual")
        var metadata: [String: JSONValue] = [
            "name": .string(name),
            "annotations": .object(annotations),
            "ownerReferences": .array([.object([
                "apiVersion": .string(cronJob.apiVersion ?? "batch/v1"), "kind": .string("CronJob"),
                "name": .string(cronJob.name), "uid": .string(cronJob.uid ?? ""),
                // No blockOwnerDeletion, as kubectl does: setting it needs update on cronjobs/finalizers, which
                // users allowed to create Jobs often lack.
                "controller": .bool(true),
            ])]),
        ]
        if let namespace = cronJob.namespace { metadata["namespace"] = .string(namespace) }
        if let labels = template?[path: "metadata", "labels"] { metadata["labels"] = labels }
        return .object([
            "apiVersion": .string("batch/v1"), "kind": .string("Job"),
            "metadata": .object(metadata), "spec": template?["spec"] ?? .object([:]),
        ])
    }
}
