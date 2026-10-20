import Foundation
import Testing
@testable import KubeKit

/// Uses `cluvia-it-http` (busybox httpd on 8080) and service `cluvia-it-http` (80 -> 8080) in `cluvia-it`.
@Suite(.enabled(if: IntegrationCluster.isEnabled, "set CLUVIA_IT_CONTEXT to run against a real cluster"), .serialized)
struct ExecAndPortForwardIntegrationTests {
    static let namespace = WatchCacheIntegrationTests.namespace

    static func ensureHTTPPod(_ client: DynamicClient) async throws {
        try await WatchCacheIntegrationTests.ensureNamespace(client)
        if (try? await client.get(.pods, name: "cluvia-it-http", namespace: namespace)) == nil {
            let pod = """
            {"apiVersion":"v1","kind":"Pod","metadata":{"name":"cluvia-it-http","labels":{"run":"cluvia-it-http"}},
             "spec":{"containers":[{"name":"http","image":"busybox:1.36","ports":[{"containerPort":8080,"name":"web"}],
               "command":["sh","-c","mkdir -p /www && echo hello from cluvia-it-http > /www/index.html && exec httpd -f -p 8080 -h /www"]}]}}
            """
            _ = try await client.create(.pods, namespace: namespace, object: Unstructured(data: Data(pod.utf8)))
        }
        let services = GroupVersionResource(group: "", version: "v1", resource: "services")
        if (try? await client.get(services, name: "cluvia-it-http", namespace: namespace)) == nil {
            let service = """
            {"apiVersion":"v1","kind":"Service","metadata":{"name":"cluvia-it-http"},
             "spec":{"selector":{"run":"cluvia-it-http"},"ports":[{"port":80,"targetPort":8080}]}}
            """
            _ = try await client.create(services, namespace: namespace, object: Unstructured(data: Data(service.utf8)))
        }
        for _ in 0..<60 {
            let pod = try await client.get(.pods, name: "cluvia-it-http", namespace: namespace)
            if pod.json[path: "status", "phase"]?.stringValue == "Running" { return }
            try await Task.sleep(for: .seconds(1))
        }
    }

    static func output(of session: ExecSession) async -> (String, Int?) {
        let collected = TextCollector()
        let exit = await session.output { collected.append($0) }
        return (collected.text, exit.code)
    }

    @Test func execShellRunsCommandsAndReportsExitCode() async throws {
        let client = try WatchCacheIntegrationTests.client()
        try await Self.ensureHTTPPod(client)
        let session = ExecSession(transport: client.transport, namespace: Self.namespace, pod: "cluvia-it-http",
                                  container: nil, command: ExecSession.defaultShell)
        try await session.start()
        await session.resize(columns: 100, rows: 30)
        // Resize and stdin travel on separate streams inside the runtime; give the resize a moment to apply.
        await session.send(Data("sleep 0.5; stty size; echo marker-$((40+2)); exit 3\n".utf8))
        let (text, code) = await Self.output(of: session)
        #expect(text.contains("30 100"), "resize not applied: \(text)")
        #expect(text.contains("marker-42"))
        #expect(code == 3)
    }

    @Test func execWithoutTTYSucceeds() async throws {
        let client = try WatchCacheIntegrationTests.client()
        try await Self.ensureHTTPPod(client)
        let session = ExecSession(transport: client.transport, namespace: Self.namespace, pod: "cluvia-it-http",
                                  container: nil, command: ["sh", "-c", "echo out; echo err >&2"], tty: false)
        try await session.start()
        let (text, code) = await Self.output(of: session)
        #expect(text.contains("out") && text.contains("err"))
        #expect(code == 0)
    }

    /// Shell through a transport authenticated by an exec credential plugin (token for a service account that
    /// is granted pods/exec in the test namespace).
    @Test func execWorksWithExecPluginCredentials() async throws {
        let admin = try WatchCacheIntegrationTests.client()
        try await Self.ensureHTTPPod(admin)
        let binding = """
        {"apiVersion":"rbac.authorization.k8s.io/v1","kind":"RoleBinding","metadata":{"name":"cluvia-it-exec","namespace":"\(Self.namespace)"},
         "roleRef":{"apiGroup":"rbac.authorization.k8s.io","kind":"ClusterRole","name":"admin"},
         "subjects":[{"kind":"ServiceAccount","name":"default","namespace":"default"}]}
        """
        let roleBindings = GroupVersionResource(group: "rbac.authorization.k8s.io", version: "v1", resource: "rolebindings")
        _ = try await admin.apply(roleBindings, name: "cluvia-it-exec", namespace: Self.namespace, manifest: Data(binding.utf8), force: true)
        let token = try await IntegrationCluster.serviceAccountToken(admin.transport)

        let script = FileManager.default.temporaryDirectory.appendingPathComponent("cluvia-exec-\(UUID().uuidString).sh")
        try """
        #!/bin/sh
        printf '{"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential","status":{"token":"%s"}}' "$IT_TOKEN"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }
        let provider = ExecCredentialProvider(
            config: ExecConfig(command: script.path, env: [ExecEnvVar(name: "IT_TOKEN", value: token)]),
            cluster: try IntegrationCluster.context().cluster
        )
        let transport = try IntegrationCluster.transport(credentials: provider)
        let session = ExecSession(transport: transport, namespace: Self.namespace, pod: "cluvia-it-http",
                                  container: nil, command: ["sh", "-c", "echo via-plugin"], tty: false)
        try await session.start()
        let (text, code) = await Self.output(of: session)
        #expect(text.contains("via-plugin"))
        #expect(code == 0)
    }

    static func fetch(port: UInt16) async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!)
        return String(decoding: data, as: UTF8.self)
    }

    @Test(arguments: [PortForwarder.Target.pod("cluvia-it-http"), .service("cluvia-it-http")])
    func portForwardServesConcurrentConnectionsAndFreesPort(target: PortForwarder.Target) async throws {
        let client = try WatchCacheIntegrationTests.client()
        try await Self.ensureHTTPPod(client)
        let remote = if case .service = target { 80 } else { 8080 }
        let forwarder = PortForwarder(client: client, namespace: Self.namespace, target: target, remotePort: remote)
        let port = try await forwarder.start()
        #expect(port > 0)

        let bodies = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { try await Self.fetch(port: port) } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(bodies.count == 8 && bodies.allSatisfy { $0 == "hello from cluvia-it-http\n" })

        await forwarder.stop()
        // The port is free again: a new forwarder can bind it.
        let again = PortForwarder(client: client, namespace: Self.namespace, target: target, remotePort: remote)
        #expect(try await again.start(localPort: port) == port)
        await again.stop()
    }

    /// Nothing listens on 9999 in the pod: the local connection must close promptly and the error be reported.
    @Test func refusedRemotePortClosesConnectionAndReportsError() async throws {
        let client = try WatchCacheIntegrationTests.client()
        try await Self.ensureHTTPPod(client)
        let errors = TextCollector()
        let forwarder = PortForwarder(client: client, namespace: Self.namespace, target: .pod("cluvia-it-http"), remotePort: 9999) {
            errors.append(Data($0.utf8))
        }
        let port = try await forwarder.start()
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: (any Error).self) { _ = try await Self.fetch(port: port) }
        #expect(clock.now - start < .seconds(10))
        try await Task.sleep(for: .milliseconds(300))
        #expect(!errors.text.isEmpty)
        await forwarder.stop()
    }

    @Test func portInUseIsReported() async throws {
        let client = try WatchCacheIntegrationTests.client()
        let first = PortForwarder(client: client, namespace: Self.namespace, target: .pod("x"), remotePort: 1)
        let port = try await first.start()
        defer { Task { await first.stop() } }
        let second = PortForwarder(client: client, namespace: Self.namespace, target: .pod("x"), remotePort: 1)
        await #expect(throws: (any Error).self) { try await second.start(localPort: port) }
    }
}

final class TextCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    var text: String { lock.withLock { buffer } }

    func append(_ data: Data) {
        lock.withLock { buffer += String(decoding: data, as: UTF8.self) }
    }
}
