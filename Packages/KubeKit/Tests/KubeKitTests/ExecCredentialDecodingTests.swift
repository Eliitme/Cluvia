import Foundation
import Testing
@testable import KubeKit

struct ExecCredentialDecodingTests {
    static let cluster = Cluster(
        server: "https://example:6443", certificateAuthorityData: "Q0E=", insecureSkipTLSVerify: nil,
        proxyURL: nil, tlsServerName: "api.internal"
    )

    @Test(arguments: ["client.authentication.k8s.io/v1", "client.authentication.k8s.io/v1beta1"])
    func decodesTokenAndExpiry(apiVersion: String) async throws {
        let json = """
        {"apiVersion":"\(apiVersion)","kind":"ExecCredential",
         "status":{"token":"abc","expirationTimestamp":"2030-01-02T03:04:05Z"}}
        """
        let (credentials, expiry) = try await ExecCredentialProvider.decode(Data(json.utf8), command: "plugin")
        #expect(credentials.bearerToken == "abc")
        #expect(expiry == Date(timeIntervalSince1970: 1_893_553_445))
    }

    @Test func parsesFractionalSecondTimestamps() {
        #expect(ExecCredentialProvider.parseTimestamp("2030-01-02T03:04:05.123Z") != nil)
        #expect(ExecCredentialProvider.parseTimestamp("garbage") == nil)
    }

    @Test(arguments: [#"{"kind":"ExecCredential"}"#, #"{"status":{}}"#, "not json"])
    func rejectsInvalidOutput(json: String) async {
        await #expect(throws: ExecPluginError.self) {
            try await ExecCredentialProvider.decode(Data(json.utf8), command: "plugin")
        }
    }

    @Test func execInfoCarriesClusterOnlyWhenRequested() throws {
        var config = ExecConfig(apiVersion: "client.authentication.k8s.io/v1beta1", command: "x")
        let plain = try JSONSerialization.jsonObject(with: Data(ExecCredentialProvider.execInfo(config: config, cluster: Self.cluster).utf8)) as? [String: Any]
        #expect(plain?["apiVersion"] as? String == "client.authentication.k8s.io/v1beta1")
        #expect((plain?["spec"] as? [String: Any])?["cluster"] == nil)
        #expect((plain?["spec"] as? [String: Any])?["interactive"] as? Bool == false)

        config.provideClusterInfo = true
        let withCluster = try JSONSerialization.jsonObject(with: Data(ExecCredentialProvider.execInfo(config: config, cluster: Self.cluster).utf8)) as? [String: Any]
        let cluster = (withCluster?["spec"] as? [String: Any])?["cluster"] as? [String: Any]
        #expect(cluster?["server"] as? String == "https://example:6443")
        #expect(cluster?["tls-server-name"] as? String == "api.internal")
    }

    @Test func missingPluginListsSearchedPath() async throws {
        let provider = ExecCredentialProvider(config: ExecConfig(command: "cluvia-missing-plugin-xyz"), cluster: Self.cluster)
        do {
            _ = try await provider.credentials()
            Issue.record("expected failure")
        } catch let ExecPluginError.notFound(command, searchPath, _) {
            #expect(command == "cluvia-missing-plugin-xyz")
            #expect(searchPath.contains("/usr/bin"))
        }
    }

    /// Plugin script that counts its invocations and emits a token expiring at `expiry`
    /// (or at `laterExpiry` from the second run on).
    static func countingPlugin(expiry: String, laterExpiry: String? = nil, exitCode: Int = 0) throws -> (script: URL, counter: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let counter = dir.appendingPathComponent("count")
        let script = dir.appendingPathComponent("plugin.sh")
        try """
        #!/bin/sh
        echo x >> "\(counter.path)"
        [ \(exitCode) -ne 0 ] && { echo "token expired, run login" >&2; exit \(exitCode); }
        expiry="\(expiry)"
        [ "$(wc -l < "\(counter.path)")" -gt 1 ] && [ -n "\(laterExpiry ?? "")" ] && expiry="\(laterExpiry ?? "")"
        printf '{"apiVersion":"client.authentication.k8s.io/v1","status":{"token":"t","expirationTimestamp":"%s"}}' "$expiry"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return (script, counter)
    }

    static func runs(_ counter: URL) -> Int {
        ((try? String(contentsOf: counter, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    @Test func cachesUntilExpiryAndRerunsAfterInvalidate() async throws {
        let plugin = try Self.countingPlugin(expiry: "2099-01-01T00:00:00Z")
        let provider = ExecCredentialProvider(config: ExecConfig(command: plugin.script.path), cluster: Self.cluster)
        _ = try await provider.credentials()
        _ = try await provider.credentials()
        #expect(Self.runs(plugin.counter) == 1)
        let used = try await provider.credentials()
        await provider.invalidate(generation: used.generation)
        let fresh = try await provider.credentials()
        #expect(Self.runs(plugin.counter) == 2)
        // A late 401 for the old generation must not evict the refreshed credentials.
        await provider.invalidate(generation: used.generation)
        _ = try await provider.credentials()
        #expect(Self.runs(plugin.counter) == 2)
        #expect(fresh.generation != used.generation)
    }

    @Test func rerunsWhenTokenIsWithinExpiryLeeway() async throws {
        let soon = ISO8601DateFormatter().string(from: Date().addingTimeInterval(10))
        let plugin = try Self.countingPlugin(expiry: soon)
        let provider = ExecCredentialProvider(config: ExecConfig(command: plugin.script.path), cluster: Self.cluster)
        _ = try await provider.credentials()
        _ = try await provider.credentials()
        #expect(Self.runs(plugin.counter) == 2)
    }

    @Test func lateUnauthorizedDoesNotEvictExpiryRefresh() async throws {
        // First run hands out a token inside the expiry leeway, later runs a long-lived one.
        let soon = ISO8601DateFormatter().string(from: Date().addingTimeInterval(10))
        let plugin = try Self.countingPlugin(expiry: soon, laterExpiry: "2099-01-01T00:00:00Z")
        let provider = ExecCredentialProvider(config: ExecConfig(command: plugin.script.path), cluster: Self.cluster)
        let old = try await provider.credentials()
        let refreshed = try await provider.credentials()
        #expect(refreshed.generation != old.generation)
        await provider.invalidate(generation: old.generation)
        _ = try await provider.credentials()
        #expect(Self.runs(plugin.counter) == 2)
    }

    @Test func nonZeroExitSurfacesStderr() async throws {
        let plugin = try Self.countingPlugin(expiry: "2099-01-01T00:00:00Z", exitCode: 3)
        let provider = ExecCredentialProvider(config: ExecConfig(command: plugin.script.path), cluster: Self.cluster)
        do {
            _ = try await provider.credentials()
            Issue.record("expected failure")
        } catch let ExecPluginError.failed(_, status, stderr) {
            #expect(status == 3)
            #expect(stderr == "token expired, run login")
        }
    }
}
