import Foundation

/// Objects a parent controls (a Deployment's ReplicaSets, a ReplicaSet's Pods, a CronJob's Jobs), found the way
/// controllers do: by owner reference uid, using the parent's label selector only to narrow the list.
public enum OwnedObjects {
    /// The parent's `spec.selector` (`matchLabels` and `matchExpressions`) in label-selector syntax, e.g.
    /// `app=web,tier in (fe,be),!legacy`; nil when there is none (or it uses an unknown operator), in which case the
    /// whole namespace is listed and filtered by uid.
    public static func labelSelector(of parent: Unstructured) -> String? {
        guard let selector = parent.json[path: "spec", "selector"]?.objectValue else { return nil }
        var terms = (selector["matchLabels"]?.objectValue ?? [:]).compactMap { key, value in value.stringValue.map { "\(key)=\($0)" } }.sorted()
        for expression in selector["matchExpressions"]?.arrayValue ?? [] {
            guard let key = expression["key"]?.stringValue else { return nil }
            let values = (expression["values"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: ",")
            switch expression["operator"]?.stringValue {
            case "In": terms.append("\(key) in (\(values))")
            case "NotIn": terms.append("\(key) notin (\(values))")
            case "Exists": terms.append(key)
            case "DoesNotExist": terms.append("!\(key)")
            default: return nil
            }
        }
        return terms.isEmpty ? nil : terms.joined(separator: ",")
    }

    /// Items whose owner references point at `uid`, sorted by name. Matching on uid, not name, ignores leftovers
    /// of an older parent that had the same name.
    public static func owned(_ items: [Unstructured], by uid: String) -> [Unstructured] {
        items.filter { $0.ownerReferences.contains { $0.uid == uid } }.sorted { $0.name < $1.name }
    }

    /// Children of `parent` of type `child`, metadata only (labels, annotations, owner references).
    public static func list(client: DynamicClient, child: GroupVersionResource, parent: Unstructured) async throws -> [Unstructured] {
        guard let uid = parent.uid else { return [] }
        let options = ListOptions(labelSelector: labelSelector(of: parent))
        return owned(try await client.listMetadata(child, namespace: parent.namespace, options: options), by: uid)
    }
}
