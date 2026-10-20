import Foundation
import KubeKit

enum ResourceAction: String, CaseIterable, Identifiable {
    case logs, shell, portForward, edit, scale, restart, cordon, uncordon, drain, nodeShell, delete

    var id: String { rawValue }

    var title: String {
        switch self {
        case .logs: "Logs"
        case .shell: "Shell"
        case .portForward: "Forward Port…"
        case .edit: "Edit YAML"
        case .scale: "Scale…"
        case .restart: "Restart"
        case .cordon: "Cordon"
        case .uncordon: "Uncordon"
        case .drain: "Drain…"
        case .nodeShell: "Node Shell"
        case .delete: "Delete…"
        }
    }

    var symbol: String {
        switch self {
        case .logs: "text.alignleft"
        case .shell: "terminal"
        case .portForward: "arrow.left.arrow.right"
        case .edit: "pencil"
        case .scale: "arrow.up.and.down"
        case .restart: "arrow.clockwise"
        case .cordon: "nosign"
        case .uncordon: "checkmark.circle"
        case .drain: "arrow.down.to.line"
        case .nodeShell: "terminal.fill"
        case .delete: "trash"
        }
    }

    /// Kinds whose pods are found through a label selector, so their logs can be shown together.
    static func hasPodSelector(_ kind: ResourceKind) -> Bool {
        switch (kind.gvr.group, kind.kind) {
        case ("apps", "Deployment"), ("apps", "StatefulSet"), ("apps", "DaemonSet"), ("apps", "ReplicaSet"),
             ("batch", "Job"), ("", "Service"): true
        default: false
        }
    }

    /// Actions that disrupt workloads go through a confirmation that names the cluster context.
    var needsConfirmation: Bool { [.restart, .cordon, .uncordon, .delete].contains(self) }

    static func available(for kind: ResourceKind) -> [ResourceAction] {
        // Group checks keep a CRD that happens to be called "Deployment" from getting built-in actions.
        let core = kind.gvr.group.isEmpty, apps = kind.gvr.group == "apps"
        var actions: [ResourceAction] = []
        if core, kind.kind == "Pod" { actions += [.logs, .shell] }
        if Self.hasPodSelector(kind) { actions.append(.logs) }
        if core, ["Pod", "Service"].contains(kind.kind) { actions.append(.portForward) }
        actions.append(.edit)
        if apps, ["Deployment", "StatefulSet", "ReplicaSet"].contains(kind.kind) { actions.append(.scale) }
        if apps, ["Deployment", "StatefulSet", "DaemonSet"].contains(kind.kind) { actions.append(.restart) }
        if core, kind.kind == "Node" { actions += [.cordon, .uncordon, .drain, .nodeShell] }
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

    /// `k=v,…` from `spec.selector.matchLabels` (workloads) or `spec.selector` (services).
    static func podSelector(of object: Unstructured) -> String? {
        let selector = object.json[path: "spec", "selector", "matchLabels"]?.objectValue ?? object.json[path: "spec", "selector"]?.objectValue
        let pairs = (selector ?? [:]).compactMap { key, value in value.stringValue.map { "\(key)=\($0)" } }.sorted()
        return pairs.isEmpty ? nil : pairs.joined(separator: ",")
    }

    /// YAML for editing: the live object without status and server bookkeeping.
    static func editableYAML(_ object: Unstructured) throws -> String {
        try YAMLRenderer.yaml(ResourceApplier.prepared(object.json))
    }
}
