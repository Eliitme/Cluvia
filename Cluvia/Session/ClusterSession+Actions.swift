import Foundation
import KubeKit

/// Entry points for resource actions; menus, the inspector and the command palette all route through here.
extension ClusterSession {
    func request(_ action: ResourceAction, kind: ResourceKind, key: ObjectKey) {
        switch action {
        case .logs:
            run { client in
                let pod = try await client.get(kind.gvr, name: key.name, namespace: key.namespace)
                self.dock.openLogs(client: client, pod: pod)
            }
        case .edit:
            run { client in
                guard let applier = self.applier else { return }
                let object = try await client.get(kind.gvr, name: key.name, namespace: key.namespace)
                self.editModel = YamlEditModel(
                    title: "Edit \(kind.kind) \(key.name)", yaml: try ResourceActions.editableYAML(object),
                    defaultNamespace: key.namespace, applier: applier, concealed: kind.kind == "Secret"
                )
            }
        default:
            pendingAction = PendingAction(action: action, kind: kind, key: key)
        }
    }

    func createResource(of kind: ResourceKind) {
        guard let applier else { return }
        let namespace = selectedNamespaces.count == 1 ? selectedNamespaces.first : nil
        editModel = YamlEditModel(
            title: "New \(kind.kind)", yaml: YamlEditModel.template(for: kind, namespace: namespace),
            defaultNamespace: namespace, applier: applier
        )
    }

    /// Runs a confirmed action; returns an error message for the sheet to show, or nil on success.
    func perform(_ pending: PendingAction, propagation: DynamicClient.PropagationPolicy) async -> String? {
        guard let client else { return "Not connected" }
        do {
            switch pending.action {
            case .delete:
                try await client.delete(pending.kind.gvr, name: pending.key.name, namespace: pending.key.namespace, propagationPolicy: propagation)
                if selectedObject == pending.key { selectedObject = nil }
            case .restart:
                try await ResourceActions.restart(client, kind: pending.kind, key: pending.key)
            case .cordon, .uncordon:
                try await ResourceActions.setSchedulable(client, kind: pending.kind, key: pending.key, schedulable: pending.action == .uncordon)
            default:
                break
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func scale(_ pending: PendingAction, to replicas: Int) async -> String? {
        guard let client else { return "Not connected" }
        do {
            try await ResourceActions.scale(client, kind: pending.kind, key: pending.key, replicas: replicas)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Current replica count; the API server defaults an absent `spec.replicas` to 1.
    func currentReplicas(_ pending: PendingAction) async throws -> Int {
        guard let client else { throw URLError(.notConnectedToInternet) }
        let object = try await client.get(pending.kind.gvr, name: pending.key.name, namespace: pending.key.namespace)
        return Int(object.json[path: "spec", "replicas"]?.intValue ?? 1)
    }

    private func run(_ work: @escaping @MainActor (DynamicClient) async throws -> Void) {
        guard let client else { return }
        Task {
            do { try await work(client) } catch { actionError = error.localizedDescription }
        }
    }
}
