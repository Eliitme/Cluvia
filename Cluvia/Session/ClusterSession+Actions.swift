import Foundation
import KubeKit

/// Entry points for resource actions; menus, the inspector and the command palette all route through here.
extension ClusterSession {
    func request(_ action: ResourceAction, kind: ResourceKind, key: ObjectKey) {
        switch action {
        case .logs where kind.kind != "Pod":
            run { client in
                let object = try await client.get(kind.gvr, name: key.name, namespace: key.namespace)
                guard let selector = ResourceActions.podSelector(of: object) else {
                    self.actionError = "\(kind.kind) \(key.name) has no pod selector"
                    return
                }
                let pods = try await client.list(.pods, namespace: key.namespace, options: ListOptions(labelSelector: selector)).items
                guard !pods.isEmpty else {
                    self.actionError = "No pods match \(kind.kind) \(key.name)"
                    return
                }
                self.dock.openLogs(client: client, title: "\(kind.kind.lowercased())/\(key.name)", pods: pods)
            }
        case .logs:
            run { client in
                let pod = try await client.get(kind.gvr, name: key.name, namespace: key.namespace)
                self.dock.openLogs(client: client, pod: pod)
            }
        case .shell:
            run { client in
                let pod = try await client.get(kind.gvr, name: key.name, namespace: key.namespace)
                self.dock.openShell(transport: client.transport, pod: pod, container: nil)
            }
        case .nodeShell:
            run { client in
                // kube-system is usually exempt from Pod Security admission, which rejects privileged pods elsewhere.
                let namespace = "kube-system"
                let name = try await NodeShellPod.create(client: client, node: key.name, namespace: namespace)
                let pod = try await client.get(.pods, name: name, namespace: namespace)
                self.dock.openShell(transport: client.transport, pod: pod, container: "shell", title: "node/\(key.name)",
                                    command: NodeShellPod.command) {
                    try? await client.delete(.pods, name: name, namespace: namespace, propagationPolicy: nil)
                }
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

    /// Logs or shell for a specific container (from the pod overview).
    func open(_ action: ResourceAction, pod: Unstructured, container: String) {
        guard let client else { return }
        switch action {
        case .logs: dock.openLogs(client: client, pod: pod, container: container)
        case .shell: dock.openShell(transport: client.transport, pod: pod, container: container)
        default: break
        }
    }

    /// Ports declared by a pod's containers or a service, offered in the forward sheet.
    func declaredPorts(_ pending: PendingAction) async -> [Int] {
        guard let client, let object = try? await client.get(pending.kind.gvr, name: pending.key.name, namespace: pending.key.namespace) else {
            return []
        }
        let ports: [JSONValue] = pending.kind.kind == "Service"
            ? object.json[path: "spec", "ports"]?.arrayValue ?? []
            : (object.json[path: "spec", "containers"]?.arrayValue ?? []).flatMap { $0["ports"]?.arrayValue ?? [] }
        // Port-forwarding is TCP only; a port can also be declared once per protocol (e.g. DNS 53).
        let tcp = ports.filter { ($0["protocol"]?.stringValue ?? "TCP") == "TCP" }
        var seen = Set<Int>()
        return tcp.compactMap { ($0["port"] ?? $0["containerPort"])?.intValue.map(Int.init) }.filter { seen.insert($0).inserted }
    }

    func startForward(_ pending: PendingAction, remotePort: Int, localPort: UInt16?) async -> String? {
        guard let client else { return "Not connected" }
        let target: PortForwarder.Target = pending.kind.kind == "Service" ? .service(pending.key.name) : .pod(pending.key.name)
        let error = await portForwards.start(client: client, namespace: pending.key.namespace ?? "default", target: target,
                                             remotePort: remotePort, localPort: localPort)
        if error == nil { dock.showPortForwards() }
        return error
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
