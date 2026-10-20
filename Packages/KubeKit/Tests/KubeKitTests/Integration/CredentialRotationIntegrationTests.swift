import Foundation
import Testing
@testable import KubeKit

@Suite(.enabled(if: IntegrationCluster.isEnabled, "set CLUVIA_IT_CONTEXT to run against a real cluster"), .serialized)
struct CredentialRotationIntegrationTests {
    /// Issues a client certificate for `commonName` through the CertificateSigningRequest API.
    static func issueClientCertificate(commonName: String, admin: KubeTransport) async throws -> (cert: String, key: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyURL = dir.appendingPathComponent("key.pem")
        let openssl = URL(fileURLWithPath: "/usr/bin/openssl")
        _ = try await ProcessRunner.run(openssl, arguments: ["genrsa", "-out", keyURL.path, "2048"])
        let csr = try await ProcessRunner.run(openssl, arguments: ["req", "-new", "-key", keyURL.path, "-subj", "/CN=\(commonName)"])

        let name = "\(commonName)-\(UUID().uuidString.prefix(6).lowercased())"
        let path = "/apis/certificates.k8s.io/v1/certificatesigningrequests"
        var request = try await IntegrationCluster.post(admin, path: path, body: [
            "apiVersion": "certificates.k8s.io/v1", "kind": "CertificateSigningRequest",
            "metadata": ["name": name],
            "spec": [
                "request": csr.stdout.base64EncodedString(), "signerName": "kubernetes.io/kube-apiserver-client",
                "expirationSeconds": 600, "usages": ["client auth"],
            ],
        ])
        request["status"] = ["conditions": [[
            "type": "Approved", "status": "True", "reason": "IntegrationTest", "message": "approved by test",
        ]]]
        defer { Task { _ = try? await admin.data(KubeRequest(method: "DELETE", path: "\(path)/\(name)")) } }
        _ = try await admin.data(KubeRequest(
            method: "PUT", path: "\(path)/\(name)/approval",
            body: try JSONSerialization.data(withJSONObject: request), contentType: "application/json"
        ))
        for _ in 0..<30 {
            let current = try await IntegrationCluster.json(admin, KubeRequest(path: "\(path)/\(name)"))
            if let encoded = (current["status"] as? [String: Any])?["certificate"] as? String,
               let pem = Data(base64Encoded: encoded) {
                return (String(decoding: pem, as: UTF8.self), try String(contentsOf: keyURL, encoding: .utf8))
            }
            try await Task.sleep(for: .seconds(1))
        }
        Issue.record("CSR \(name) was not signed")
        throw CancellationError()
    }

    /// Exec plugin that serves whichever cert/key pair `selector` currently names.
    static func rotatingPlugin(in dir: URL, pairs: [String: (cert: String, key: String)]) throws -> (script: URL, selector: URL) {
        let selector = dir.appendingPathComponent("current")
        for (label, pair) in pairs {
            let status: [String: Any] = ["clientCertificateData": pair.cert, "clientKeyData": pair.key]
            let json = try JSONSerialization.data(withJSONObject: [
                "apiVersion": "client.authentication.k8s.io/v1", "kind": "ExecCredential", "status": status,
            ])
            try json.write(to: dir.appendingPathComponent("\(label).json"))
        }
        let script = dir.appendingPathComponent("plugin.sh")
        try "#!/bin/sh\ncat \"\(dir.path)/$(cat \"\(selector.path)\").json\"\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return (script, selector)
    }

    @Test func rotatedClientCertificateIsUsedOnNextHandshake() async throws {
        let admin = try IntegrationCluster.transport()
        let first = try await Self.issueClientCertificate(commonName: "cluvia-it-first", admin: admin)
        let second = try await Self.issueClientCertificate(commonName: "cluvia-it-second", admin: admin)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plugin = try Self.rotatingPlugin(in: dir, pairs: ["first": first, "second": second])
        try "first".write(to: plugin.selector, atomically: true, encoding: .utf8)

        let provider = ExecCredentialProvider(config: ExecConfig(command: plugin.script.path), cluster: try IntegrationCluster.context().cluster)
        let transport = try IntegrationCluster.transport(credentials: provider)
        #expect(try await IntegrationCluster.authenticatedUser(transport) == "cluvia-it-first")

        // Simulate the plugin handing out a renewed certificate after the old one was rejected.
        try "second".write(to: plugin.selector, atomically: true, encoding: .utf8)
        await provider.invalidate(generation: try await provider.credentials().generation)
        #expect(try await IntegrationCluster.authenticatedUser(transport) == "cluvia-it-second")
    }

    @Test func wrongClusterCAReportsUntrustedServer() async throws {
        let bogusCA = try await ClientIdentityFactoryTests.makeCertificate(keyArgs: ["genrsa", "2048"])
        var cluster = try IntegrationCluster.context().cluster
        cluster.certificateAuthorityData = bogusCA.cert.base64EncodedString()
        let transport = try KubeTransport(
            serverURL: URL(string: cluster.server)!, trust: try TrustPolicy.from(cluster),
            credentials: StaticCredentialProvider(user: AuthInfo(token: "unused"))
        )
        await #expect {
            _ = try await transport.data(KubeRequest(path: "/version"))
        } throws: { error in
            if case KubeTransportError.untrustedServer = error { return true }
            return false
        }
    }
}
