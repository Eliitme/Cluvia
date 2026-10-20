import Foundation

/// A privileged helper pod pinned to a node whose shell enters the host's namespaces (`nsenter -t 1`).
/// Created on demand and deleted when the shell closes.
public enum NodeShellPod {
    public struct Failure: Error, LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static let image = "busybox:1.36"
    public static let namespace = "kube-system"
    static let maxLifetimeSeconds: Int64 = 4 * 3600
    /// Enters the host's mount, UTS, IPC, network and PID namespaces and starts the host's shell.
    public static let command = ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--", "sh", "-c",
                                 "command -v bash >/dev/null && exec bash -l || exec sh -l"]

    public static func manifest(node: String, name: String) -> Unstructured {
        Unstructured(.object([
            "apiVersion": .string("v1"), "kind": .string("Pod"),
            "metadata": .object(["name": .string(name), "labels": .object(["app.cluvia/node-shell": .string("true")])]),
            "spec": .object([
                "nodeName": .string(node), "hostPID": .bool(true), "hostNetwork": .bool(true), "hostIPC": .bool(true),
                "restartPolicy": .string("Never"), "terminationGracePeriodSeconds": .int(0),
                // Hard stop for a pod the app could not delete (crash, forced quit).
                "activeDeadlineSeconds": .int(maxLifetimeSeconds),
                // Runs on any node, including control-plane and tainted ones.
                "tolerations": .array([.object(["operator": .string("Exists")])]),
                "containers": .array([.object([
                    "name": .string("shell"), "image": .string(image),
                    "command": .array([.string("sleep"), .string(String(maxLifetimeSeconds))]),
                    "stdin": .bool(true), "tty": .bool(true),
                    "securityContext": .object(["privileged": .bool(true)]),
                ])]),
            ]),
        ]))
    }

    /// Creates the pod in `namespace` and waits until it runs; returns its name.
    public static func create(client: DynamicClient, node: String, namespace: String) async throws -> String {
        let name = podName(node: node)
        _ = try await client.create(.pods, namespace: namespace, object: manifest(node: node, name: name))
        do {
            for _ in 0..<120 {
                let pod = try await client.get(.pods, name: name, namespace: namespace)
                switch pod.json[path: "status", "phase"]?.stringValue {
                case "Running": return name
                case "Failed", "Succeeded": throw Failure(message: "Node shell pod \(name) stopped before it could be used")
                default: try await Task.sleep(for: .milliseconds(500))
                }
            }
            throw Failure(message: "Node shell pod \(name) did not start within 60s")
        } catch {
            // Never leave a privileged pod behind on a failed start.
            try? await client.delete(.pods, name: name, namespace: namespace, propagationPolicy: nil)
            throw error
        }
    }

    /// A valid DNS label: node names can contain dots and be long.
    static func podName(node: String) -> String {
        let base = node.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let trimmed = String(base.prefix(30)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "node-shell-\(trimmed)-\(UUID().uuidString.prefix(5).lowercased())"
    }
}
