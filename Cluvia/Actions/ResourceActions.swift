import Foundation
import KubeKit

enum ResourceAction: String, CaseIterable, Identifiable {
    case logs, edit, scale, restart, cordon, uncordon, delete

    var id: String { rawValue }

    var title: String {
        switch self {
        case .logs: "Logs"
        case .edit: "Edit YAML"
        case .scale: "Scale…"
        case .restart: "Restart"
        case .cordon: "Cordon"
        case .uncordon: "Uncordon"
        case .delete: "Delete…"
        }
    }

    var symbol: String {
        switch self {
        case .logs: "text.alignleft"
        case .edit: "pencil"
        case .scale: "arrow.up.and.down"
        case .restart: "arrow.clockwise"
        case .cordon: "nosign"
        case .uncordon: "checkmark.circle"
        case .delete: "trash"
        }
    }

    /// Actions that disrupt workloads go through a confirmation that names the cluster context.
    var needsConfirmation: Bool { [.restart, .cordon, .uncordon, .delete].contains(self) }

    static func available(for kind: ResourceKind) -> [ResourceAction] {
        // Group checks keep a CRD that happens to be called "Deployment" from getting built-in actions.
        let core = kind.gvr.group.isEmpty, apps = kind.gvr.group == "apps"
        var actions: [ResourceAction] = []
        if core, kind.kind == "Pod" { actions.append(.logs) }
        actions.append(.edit)
        if apps, ["Deployment", "StatefulSet", "ReplicaSet"].contains(kind.kind) { actions.append(.scale) }
        if apps, ["Deployment", "StatefulSet", "DaemonSet"].contains(kind.kind) { actions.append(.restart) }
        if core, kind.kind == "Node" { actions += [.cordon, .uncordon] }
        actions.append(.delete)
        return actions
    }
}

/// An action the user picked, waiting for its sheet (confirmation, scale, editor).
struct PendingAction: Identifiable {
    let id = UUID()
    let action: ResourceAction
    let kind: ResourceKind
    let key: ObjectKey
}

/// Executes resource actions; shared by the table menu, inspector toolbar and command palette.
enum ResourceActions {
    /// Same annotation `kubectl rollout restart` sets, so rollout history reads the same either way.
    static let restartedAtAnnotation = "kubectl.kubernetes.io/restartedAt"

    static func scale(_ client: DynamicClient, kind: ResourceKind, key: ObjectKey, replicas: Int) async throws {
        _ = try await client.patch(kind.gvr, name: key.name, namespace: key.namespace, type: .merge,
                                   body: Data(#"{"spec":{"replicas":\#(replicas)}}"#.utf8))
    }

    static func restart(_ client: DynamicClient, kind: ResourceKind, key: ObjectKey, now: Date = Date()) async throws {
        let stamp = now.formatted(.iso8601)
        let body = #"{"spec":{"template":{"metadata":{"annotations":{"\#(restartedAtAnnotation)":"\#(stamp)"}}}}}"#
        _ = try await client.patch(kind.gvr, name: key.name, namespace: key.namespace, type: .strategicMerge, body: Data(body.utf8))
    }

    static func setSchedulable(_ client: DynamicClient, kind: ResourceKind, key: ObjectKey, schedulable: Bool) async throws {
        let body = schedulable ? #"{"spec":{"unschedulable":null}}"# : #"{"spec":{"unschedulable":true}}"#
        _ = try await client.patch(kind.gvr, name: key.name, type: .merge, body: Data(body.utf8))
    }

    /// YAML for editing: the live object without status and server bookkeeping.
    static func editableYAML(_ object: Unstructured) throws -> String {
        try YAMLRenderer.yaml(ResourceApplier.prepared(object.json))
    }
}
