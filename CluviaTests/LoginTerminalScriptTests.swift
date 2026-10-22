import Foundation
import KubeKit
import Testing
@testable import Cluvia

/// The sign-in script must never run text from a kubeconfig before (or instead of) the user pressing Return.
struct LoginTerminalScriptTests {
    static let hostile = [
        "$(touch SENTINEL)", "`touch SENTINEL`", "${IFS}touch${IFS}SENTINEL", "x'; touch SENTINEL; '", #"x"; touch SENTINEL; ""#,
        "a\ntouch SENTINEL", ";touch SENTINEL", "\\$(touch SENTINEL)", "\u{1b}]0;title\u{7}\u{1b}[2K\r$(touch SENTINEL)",
    ]

    /// Runs the script with zsh in a scratch directory, stdin closed so `read` fails; returns (syntax ok, output, sentinel made).
    static func run(_ script: String) throws -> (syntaxOK: Bool, output: String, sentinel: Bool, deleted: Bool) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("login.command")
        try script.write(to: file, atomically: true, encoding: .utf8)

        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/zsh")
        check.arguments = ["-n", file.path]
        try check.run()
        check.waitUntilExit()

        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/bin/zsh")
        run.arguments = ["-f", file.path]
        run.currentDirectoryURL = dir
        run.environment = ["PATH": "/usr/bin:/bin", "TERM": "dumb", "HOME": dir.path]
        let output = Pipe()
        run.standardOutput = output
        run.standardError = output
        run.standardInput = FileHandle.nullDevice
        try run.run()
        run.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let sentinel = FileManager.default.fileExists(atPath: dir.appendingPathComponent("SENTINEL").path)
        return (check.terminationStatus == 0, text, sentinel, !FileManager.default.fileExists(atPath: file.path))
    }

    @Test(arguments: hostile)
    func hostileTextIsPrintedNotRun(_ text: String) throws {
        let script = try #require(LoginTerminalLauncher.script(
            context: text, executable: "/opt/\(text)/aws", arguments: ["sso", "login", "--profile", text],
            env: [ExecEnvVar(name: "AWS_PROFILE", value: text)]
        ))
        let result = try Self.run(script)
        #expect(result.syntaxOK)
        #expect(!result.sentinel)
        #expect(result.deleted)
        #expect(result.output.contains(LoginTerminalLauncher.printable(text)))
        #expect(!result.output.contains("\u{1b}"))
    }

    @Test func onlyLoginToolsAndPlainEnvNames() {
        #expect(LoginTerminalLauncher.script(context: "c", executable: "/usr/local/bin/kubectl", arguments: [], env: []) == nil)
        #expect(LoginTerminalLauncher.script(context: "c", executable: "/bin/aws-plugin", arguments: [], env: []) == nil)
        #expect(LoginTerminalLauncher.script(context: "c", executable: "/bin/aws", arguments: [],
                                             env: [ExecEnvVar(name: "X=1;touch S", value: "v")]) == nil)
    }

    @Test func credentialsFromTheKubeconfigAreNotWritten() throws {
        let script = try #require(LoginTerminalLauncher.script(
            context: "c", executable: "/bin/aws", arguments: ["sso", "login"],
            env: [ExecEnvVar(name: "AWS_PROFILE", value: "prod"), ExecEnvVar(name: "AWS_SECRET_ACCESS_KEY", value: "SECRETVALUE")]
        ))
        #expect(script.contains("export AWS_PROFILE='prod'"))
        #expect(script.contains("printf 'export %s=%s\\n' 'AWS_PROFILE' 'prod'"))
        #expect(!script.contains("SECRETVALUE"))
        #expect(!script.contains("AWS_SECRET_ACCESS_KEY"))
    }
}
