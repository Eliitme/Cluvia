import Foundation
import KubeKit

/// Entry points for resource actions; menus, the inspector and the command palette all route through here.
extension ClusterSession {
    func request(_ action: ResourceAction, kind: ResourceKind, key: ObjectKey) {
        // A sheet is already open for another action; starting one now would replace it and lose its state.
        guard pendingAction == nil, editModel == nil else { return }
        guard action.route == .immediate else {
            pendingAction = PendingAction(action: action, kind: kind, key: key)
            return
        }
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
        case .edit:
            run { client in
                guard let applier = self.applier else { return }
                let object = try await client.get(kind.gvr, name: key.name, namespace: key.namespace)
                let title = "Edit \(kind.kind) \(key.name)"
                // A Secret that cannot be decoded safely still opens, as base64 like any other object.
                if kind.gvr.group.isEmpty, let secret = (try? SecretDataCodec.decode(ResourceApplier.prepared(object.json))) ?? nil {
                    self.editModel = YamlEditModel(
                        title: title, yaml: try YAMLRenderer.yaml(secret.json), defaultNamespace: key.namespace,
                        applier: applier, concealed: true, secretState: secret.state
                    )
                } else {
                    self.editModel = YamlEditModel(
                        title: title, yaml: try ResourceActions.editableYAML(object),
                        defaultNamespace: key.namespace, applier: applier, concealed: kind.kind == "Secret"
                    )
                }
            }
        case .portForward, .scale, .drain, .delete, .restart, .cordon, .uncordon, .nodeShell:
            assertionFailure("\(action) is routed to a sheet")
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

    /// Runs an action confirmed in `ConfirmActionSheet`; returns an error message for the sheet to show, or nil on success.
    func perform(_ pending: PendingAction) async -> String? {
        guard let client else { return "Not connected" }
        do {
            switch pending.action {
            case .restart:
                try await ResourceActions.restart(client, kind: pending.kind, key: pending.key)
            case .cordon, .uncordon:
                try await ResourceActions.setSchedulable(client, kind: pending.kind, key: pending.key, schedulable: pending.action == .uncordon)
            case .nodeShell:
                try await openNodeShell(client: client, node: pending.key.name)
            case .logs, .shell, .edit, .portForward, .scale, .drain, .delete:
                // Listed rather than defaulted so a new action is a compile error here until it is wired up.
                return "\(pending.action.title) is not run from a confirmation."
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

    /// Creates the helper pod and opens its shell. The pod is deleted on every path: failed start, window
    /// already closed, tab closed, app quit.
    private func openNodeShell(client: DynamicClient, node: String) async throws {
        let namespace = NodeShellPod.namespace
        let name = try await NodeShellPod.create(client: client, node: node, namespace: namespace)
        let cleanup: @Sendable () async -> Void = {
            try? await client.delete(.pods, name: name, namespace: namespace, propagationPolicy: nil)
        }
        let cleanupID = UUID()
        ShutdownCleanup.shared.register(cleanupID, cleanup)
        do {
            guard self.client != nil else { throw CancellationError() }
            let pod = try await client.get(.pods, name: name, namespace: namespace)
            dock.openShell(transport: client.transport, pod: pod, container: "shell", title: "node/\(node)",
                           command: NodeShellPod.command, onClose: cleanup)
            ShutdownCleanup.shared.unregister(cleanupID) // the tab owns cleanup from here
        } catch {
            ShutdownCleanup.shared.unregister(cleanupID)
            await cleanup()
            throw error
        }
    }

    private func run(_ work: @escaping @MainActor (DynamicClient) async throws -> Void) {
        guard let client else { return }
        Task {
            do { try await work(client) } catch { actionError = error.localizedDescription }
        }
    }
}
