import Foundation
import Testing
@testable import KubeKit

struct LoginShellEnvironmentTests {
    @Test func parsesDumpAfterMarkerIgnoringShellNoise() {
        var data = Data("Welcome banner\nPATH=/wrong\n__M__".utf8)
        data.append(Data("PATH=/opt/homebrew/bin:/usr/bin\u{0}MULTI=a\nb\u{0}EQ=x=y\u{0}".utf8))
        let env = LoginShellEnvironment.parseEnvironmentDump(data, marker: "__M__")
        #expect(env["PATH"] == "/opt/homebrew/bin:/usr/bin")
        #expect(env["MULTI"] == "a\nb")
        #expect(env["EQ"] == "x=y")
    }

    @Test func missingMarkerYieldsEmpty() {
        #expect(LoginShellEnvironment.parseEnvironmentDump(Data("PATH=/x".utf8), marker: "__M__").isEmpty)
    }

    @Test func fallbackDirectoriesAppendedOnce() {
        let path = LoginShellEnvironment.appendingFallbackDirectories(to: "/usr/local/bin:/custom")
        let entries = path.split(separator: ":")
        #expect(entries.first == "/usr/local/bin")
        #expect(entries.filter { $0 == "/usr/local/bin" }.count == 1)
        #expect(entries.contains("/opt/homebrew/bin"))
    }

    @Test func capturesRealShellAndResolvesExecutables() async {
        // Simulate a Finder launch: launchd-style minimal PATH.
        let shellEnv = LoginShellEnvironment(baseEnvironment: [
            "HOME": NSHomeDirectory(), "SHELL": ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
            "PATH": "/usr/bin:/bin",
        ])
        #expect(await shellEnv.resolveExecutable("env")?.path == "/usr/bin/env")
        #expect(await shellEnv.resolveExecutable("definitely-not-a-command-xyz") == nil)
        #expect(await shellEnv.searchPath().contains("/opt/homebrew/bin"))
    }

    @Test func processRunnerFeedsStdinAndTimesOut() async throws {
        let echoed = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/cat"), stdin: Data("hello".utf8))
        #expect(echoed.stdoutText == "hello")
        await #expect(throws: ProcessRunnerError.self) {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: .milliseconds(200))
        }
    }

    @Test func backgroundGrandchildHoldingPipesDoesNotBlock() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await ProcessRunner.run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30 & echo done"], timeout: .seconds(10)
        )
        #expect(result.stdoutText == "done\n")
        #expect(clock.now - start < .seconds(5))
    }

    @Test func cancellationBeforeOrDuringRunTerminates() async {
        let task = Task { try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"]) }
        task.cancel()
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: ProcessRunnerError.self) { try await task.value }
        #expect(clock.now - start < .seconds(5))
    }

    @Test func childIgnoringStdinDoesNotCrashWriter() async throws {
        let result = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/true"), stdin: Data(repeating: 0x41, count: 4 * 1024 * 1024)
        )
        #expect(result.status == 0)
    }
}
