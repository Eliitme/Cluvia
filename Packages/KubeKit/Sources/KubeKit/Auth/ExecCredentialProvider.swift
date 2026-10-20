import Foundation

public enum ExecPluginError: Error, LocalizedError, Sendable {
    case notFound(command: String, searchPath: [String], installHint: String?)
    case failed(command: String, status: Int32, stderr: String)
    case invalidOutput(command: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .notFound(command, searchPath, installHint):
            "Credential plugin \"\(command)\" not found."
                + (installHint.map { "\n\($0)" } ?? "")
                + "\nSearched PATH:\n" + searchPath.joined(separator: "\n")
        case let .failed(command, status, stderr):
            "Credential plugin \"\(command)\" exited with status \(status)" + (stderr.isEmpty ? "" : ":\n\(stderr)")
        case let .invalidOutput(command, reason):
            "Credential plugin \"\(command)\" returned an invalid ExecCredential: \(reason)"
        }
    }
}

/// `client.authentication.k8s.io` ExecCredential (v1 and v1beta1 share this shape).
struct ExecCredential: Decodable {
    struct Status: Decodable {
        var expirationTimestamp: String?
        var token: String?
        var clientCertificateData: String?
        var clientKeyData: String?
    }

    var apiVersion: String?
    var status: Status?
}

/// Runs a kubeconfig `exec` credential plugin and caches its output until shortly before it expires.
public actor ExecCredentialProvider: CredentialProvider {
    /// Interactive plugins (browser OIDC login) may legitimately take a while.
    static let timeout: Duration = .seconds(120)
    static let expiryLeeway: TimeInterval = 30

    private let config: ExecConfig
    private let cluster: Cluster
    private let shell: LoginShellEnvironment
    private var cached: (credentials: Credentials, expiresAt: Date?)?
    private var generation: UInt64 = 0
    private var inFlight: Task<(Credentials, Date?), Error>?

    public init(config: ExecConfig, cluster: Cluster, shell: LoginShellEnvironment = .shared) {
        self.config = config
        self.cluster = cluster
        self.shell = shell
    }

    public func credentials() async throws -> Credentials {
        if let cached, cached.expiresAt.map({ $0.timeIntervalSinceNow > Self.expiryLeeway }) ?? true {
            return cached.credentials
        }
        // Concurrent callers share one plugin run.
        if let inFlight { return try await inFlight.value.0 }
        let task = Task { [config, cluster, shell] in
            try await Self.execute(config: config, cluster: cluster, shell: shell)
        }
        inFlight = task
        defer { inFlight = nil }
        var (credentials, expiresAt) = try await task.value
        // Every plugin result is a new generation, including expiry-driven refreshes, so a late 401 for the
        // previous token cannot evict this one.
        generation += 1
        credentials.generation = generation
        cached = (credentials, expiresAt)
        return credentials
    }

    public func invalidate(generation stale: UInt64) {
        guard stale == generation else { return }
        cached = nil
    }

    static func execute(config: ExecConfig, cluster: Cluster, shell: LoginShellEnvironment) async throws -> (Credentials, Date?) {
        guard let executable = await shell.resolveExecutable(config.command) else {
            throw ExecPluginError.notFound(
                command: config.command, searchPath: await shell.searchPath(), installHint: config.installHint
            )
        }
        var environment = await shell.environment()
        for variable in config.env ?? [] { environment[variable.name] = variable.value }
        environment["KUBERNETES_EXEC_INFO"] = execInfo(config: config, cluster: cluster)

        let result = try await ProcessRunner.run(
            executable, arguments: config.args ?? [], environment: environment, timeout: timeout
        )
        guard result.status == 0 else {
            throw ExecPluginError.failed(
                command: config.command, status: result.status,
                stderr: result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return try await decode(result.stdout, command: config.command)
    }

    static func decode(_ output: Data, command: String) async throws -> (Credentials, Date?) {
        let credential: ExecCredential
        do {
            credential = try JSONDecoder().decode(ExecCredential.self, from: output)
        } catch {
            throw ExecPluginError.invalidOutput(command: command, reason: error.localizedDescription)
        }
        guard let status = credential.status else {
            throw ExecPluginError.invalidOutput(command: command, reason: "missing status")
        }
        var credentials = Credentials(bearerToken: status.token.flatMap { $0.isEmpty ? nil : $0 })
        if let cert = status.clientCertificateData, let key = status.clientKeyData {
            credentials.identity = try await ClientIdentityFactory.identity(certificatePEM: Data(cert.utf8), keyPEM: Data(key.utf8))
        }
        guard credentials.bearerToken != nil || credentials.identity != nil else {
            throw ExecPluginError.invalidOutput(command: command, reason: "status has neither token nor client certificate")
        }
        return (credentials, status.expirationTimestamp.flatMap(parseTimestamp))
    }

    /// The plugin receives no TTY, so it is told the session is non-interactive.
    static func execInfo(config: ExecConfig, cluster: Cluster) -> String {
        var spec: [String: Any] = ["interactive": false]
        if config.provideClusterInfo == true {
            var info: [String: Any] = ["server": cluster.server]
            info["certificate-authority-data"] = cluster.certificateAuthorityData
            info["insecure-skip-tls-verify"] = cluster.insecureSkipTLSVerify
            info["tls-server-name"] = cluster.tlsServerName
            info["proxy-url"] = cluster.proxyURL
            spec["cluster"] = info
        }
        let object: [String: Any] = [
            "apiVersion": config.apiVersion ?? "client.authentication.k8s.io/v1",
            "kind": "ExecCredential",
            "spec": spec,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
}
