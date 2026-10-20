import Foundation
import Testing
@testable import KubeKit

@Suite(.enabled(if: IntegrationCluster.isEnabled, "set CLUVIA_IT_CONTEXT to run against a real cluster"), .serialized)
struct KubeTransportIntegrationTests {
    @Test func versionAndIdentityViaKubeconfigUser() async throws {
        let transport = try IntegrationCluster.transport()
        let version = try await IntegrationCluster.json(transport, KubeRequest(path: "/version"))
        #expect((version["gitVersion"] as? String)?.hasPrefix("v") == true)
        let user = try await IntegrationCluster.authenticatedUser(transport)
        #expect(user != nil && user?.hasPrefix("system:anonymous") == false)
    }

    @Test func serviceAccountBearerToken() async throws {
        let token = try await IntegrationCluster.serviceAccountToken(try IntegrationCluster.transport())
        let transport = try IntegrationCluster.transport(credentials: StaticCredentialProvider(user: AuthInfo(token: token)))
        #expect(try await IntegrationCluster.authenticatedUser(transport) == "system:serviceaccount:default:default")
    }

    @Test func execPluginToken() async throws {
        let token = try await IntegrationCluster.serviceAccountToken(try IntegrationCluster.transport())
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
        #expect(try await IntegrationCluster.authenticatedUser(transport) == "system:serviceaccount:default:default")
    }

    /// Watch streams must survive well past URLSession's default 60s idle timeout. Duration via `CLUVIA_IT_WATCH_SECONDS`.
    @Test func watchStreamStaysOpen() async throws {
        let seconds = Int(IntegrationCluster.environment["CLUVIA_IT_WATCH_SECONDS"] ?? "") ?? 20
        let transport = try IntegrationCluster.transport()
        let (bytes, _) = try await transport.bytes(KubeRequest(path: "/api/v1/pods", query: [
            URLQueryItem(name: "watch", value: "1"), URLQueryItem(name: "allowWatchBookmarks", value: "true"),
        ]))
        let reader = Task<Int, Error> {
            var events = 0
            for try await _ in bytes.lines { events += 1 }
            return events
        }
        try await Task.sleep(for: .seconds(seconds))
        reader.cancel()
        // A stream that ended on its own before cancellation would have returned normally instead of being cancelled.
        let outcome = await reader.result
        if case let .success(events) = outcome {
            Issue.record("watch stream ended early after \(events) events")
        }
    }

    @Test func execWebSocketRoundTrip() async throws {
        let transport = try IntegrationCluster.transport()
        let pod = try await IntegrationCluster.ensureEchoPod(transport)
        let socket = try await transport.webSocket(
            path: "/api/v1/namespaces/default/pods/\(pod)/exec",
            query: ["cat"].map { URLQueryItem(name: "command", value: $0) } + ["stdin", "stdout", "stderr"].map {
                URLQueryItem(name: $0, value: "true")
            },
            protocols: ["v5.channel.k8s.io", "v4.channel.k8s.io"]
        )
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        try await socket.send(.data(Data([0]) + Data("ping\n".utf8)))
        var stdout = Data()
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !String(decoding: stdout, as: UTF8.self).contains("ping") {
            guard case let .data(frame) = try await socket.receive(), let channel = frame.first else { continue }
            if channel == 1 { stdout.append(frame.dropFirst()) }
        }
        #expect(String(decoding: stdout, as: UTF8.self) == "ping\n")
    }
}
