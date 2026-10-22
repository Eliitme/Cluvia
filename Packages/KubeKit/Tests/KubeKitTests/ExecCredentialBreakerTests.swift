import Foundation
import Testing
@testable import KubeKit

struct ExecCredentialBreakerTests {
    /// Plugin that counts runs and fails while `fail` exists next to it.
    static func togglingPlugin() throws -> (script: URL, counter: URL, failFlag: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let counter = dir.appendingPathComponent("count"), flag = dir.appendingPathComponent("fail")
        let script = dir.appendingPathComponent("plugin.sh")
        try """
        #!/bin/sh
        echo x >> "\(counter.path)"
        [ -e "\(flag.path)" ] && { echo "session expired, sign in again" >&2; exit 1; }
        printf '{"apiVersion":"client.authentication.k8s.io/v1","status":{"token":"t","expirationTimestamp":"2001-01-01T00:00:00Z"}}'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        FileManager.default.createFile(atPath: flag.path, contents: nil)
        return (script, counter, flag)
    }

    static func provider(_ script: URL, cooldown: Duration = .seconds(60)) -> ExecCredentialProvider {
        ExecCredentialProvider(config: ExecConfig(command: script.path), cluster: ExecCredentialDecodingTests.cluster,
                               shell: .shared, cooldown: cooldown)
    }

    @Test func failureIsNotRetriedUntilResetAndIsReportedOnce() async throws {
        let plugin = try Self.togglingPlugin()
        let provider = Self.provider(plugin.script)
        var events = await provider.failures().makeAsyncIterator()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 { group.addTask { _ = try? await provider.credentials() } }
        }
        for _ in 0..<5 { _ = try? await provider.credentials() }
        #expect(ExecCredentialDecodingTests.runs(plugin.counter) == 1)
        #expect(await provider.reportedFailureCount == 1)
        let reported = await events.next()
        #expect((reported ?? nil).map { ($0 as? ExecPluginError)?.stderr } == "session expired, sign in again")

        try FileManager.default.removeItem(at: plugin.failFlag)
        await provider.reset()
        _ = try await provider.credentials()
        #expect(ExecCredentialDecodingTests.runs(plugin.counter) == 2)
        let cleared = await events.next()
        #expect(cleared.map { $0 == nil } == true)
    }

    @Test func cooldownLetsThePluginRunAgain() async throws {
        let plugin = try Self.togglingPlugin()
        let provider = Self.provider(plugin.script, cooldown: .milliseconds(200))
        _ = try? await provider.credentials()
        try await Task.sleep(for: .milliseconds(300))
        _ = try? await provider.credentials()
        #expect(ExecCredentialDecodingTests.runs(plugin.counter) == 2)
    }

    @Test func currentFailureIsReplayedToANewSubscriber() async throws {
        let plugin = try Self.togglingPlugin()
        let provider = Self.provider(plugin.script)
        _ = try? await provider.credentials()
        var events = await provider.failures().makeAsyncIterator()
        let replayed = await events.next()
        #expect((replayed ?? nil) is ExecPluginError)
    }

    @Test func cancellationDoesNotTripTheBreaker() {
        #expect(!ExecCredentialProvider.tripsBreaker(ProcessRunnerError.cancelled(executable: "x")))
        #expect(ExecCredentialProvider.tripsBreaker(ProcessRunnerError.timedOut(executable: "x", seconds: 120)))
        #expect(!ExecCredentialProvider.tripsBreaker(CancellationError()))
    }
}
