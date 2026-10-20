import Foundation
import KubeKit

public enum HelmError: Error, LocalizedError, Sendable {
    case failed(command: String, message: String)

    public var errorDescription: String? {
        if case let .failed(command, message) = self { return "helm \(command) failed: \(message)" }
        return nil
    }
}

/// Runs the user's `helm` binary against one kubeconfig context. Each call is a short-lived process;
/// nothing is left running in the background.
public struct HelmRunner: Sendable {
    /// Install and upgrade can pull charts and wait on hooks.
    static let longTimeout: Duration = .seconds(300)

    public let executable: URL
    public let context: String
    /// Major version of the helm binary (3, 4, ...); flags differ between majors.
    public let majorVersion: Int
    private let environment: [String: String]

    public init(executable: URL, context: String, environment: [String: String], majorVersion: Int) {
        self.executable = executable
        self.context = context
        self.environment = environment
        self.majorVersion = majorVersion
    }

    /// nil when helm is not installed; the app then hides Helm features behind an install hint.
    public static func locate(context: String, shell: LoginShellEnvironment = .shared) async -> HelmRunner? {
        guard let helm = await HelmLocator.helmExecutable(shell: shell) else { return nil }
        let environment = await shell.environment()
        let version = try? await ProcessRunner.run(helm, arguments: ["version", "--short"], environment: environment, timeout: .seconds(10))
        return HelmRunner(executable: helm, context: context, environment: environment,
                          majorVersion: parseMajorVersion(version?.stdoutText ?? "") ?? 3)
    }

    /// `v4.0.1+g12500dd` -> 4
    static func parseMajorVersion(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("v") ? Int(trimmed.dropFirst().prefix { $0.isNumber }) : nil
    }

    public func releases() async throws -> [HelmRelease] {
        // Helm 3 lists only deployed and failed releases unless asked; Helm 4 lists every status by default.
        let all = majorVersion < 4 ? ["--all"] : []
        return try HelmDecoding.releases(try await run(["list", "--all-namespaces", "--output", "json"] + all).stdout)
    }

    public func history(release: String, namespace: String) async throws -> [HelmRevision] {
        try HelmDecoding.history(try await run(["history", release, "--namespace", namespace, "--output", "json"]).stdout)
    }

    /// User-supplied values (or all computed values) as YAML.
    public func values(release: String, namespace: String, all: Bool = false) async throws -> String {
        try await text(["get", "values", release, "--namespace", namespace, "--output", "yaml"] + (all ? ["--all"] : []))
    }

    public func manifest(release: String, namespace: String) async throws -> String {
        try await text(["get", "manifest", release, "--namespace", namespace])
    }

    public func notes(release: String, namespace: String) async throws -> String {
        try await text(["get", "notes", release, "--namespace", namespace])
    }

    public func rollback(release: String, namespace: String, revision: Int) async throws {
        _ = try await run(["rollback", release, String(revision), "--namespace", namespace], timeout: Self.longTimeout)
    }

    public func uninstall(release: String, namespace: String) async throws {
        _ = try await run(["uninstall", release, "--namespace", namespace], timeout: Self.longTimeout)
    }

    /// Installs or upgrades `release` from `chart` (repo/chart, OCI reference or local path) with `values`
    /// YAML passed on stdin, so no values file is written to disk.
    public func upgradeOrInstall(
        release: String, namespace: String, chart: String, version: String?, values: String, install: Bool
    ) async throws {
        var arguments = ["upgrade", release, chart, "--namespace", namespace, "--values", "-"]
        if install { arguments += ["--install", "--create-namespace"] }
        if let version, !version.isEmpty { arguments += ["--version", version] }
        _ = try await run(arguments, stdin: Data(values.utf8), timeout: Self.longTimeout)
    }

    private func text(_ arguments: [String]) async throws -> String {
        try await run(arguments).stdoutText
    }

    @discardableResult
    func run(_ arguments: [String], stdin: Data? = nil, timeout: Duration = .seconds(60)) async throws -> ProcessResult {
        let result = try await ProcessRunner.run(
            executable, arguments: arguments + ["--kube-context", context], environment: environment, stdin: stdin, timeout: timeout
        )
        guard result.status == 0 else {
            throw HelmError.failed(command: arguments.first ?? "", message: result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }
}
