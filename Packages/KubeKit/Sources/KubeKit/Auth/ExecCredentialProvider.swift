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
///
/// After a failed run the error is returned again without running the plugin until `reset()` or a cooldown: every
/// watch retries on its own backoff, and rerunning an interactive plugin each time would keep opening browser
/// windows or lock the account at the identity provider.
public actor ExecCredentialProvider: CredentialProvider {
    /// Interactive plugins (browser OIDC login) may legitimately take a while.
    static let timeout: Duration = .seconds(120)
    static let expiryLeeway: TimeInterval = 30
    static let failureCooldown: Duration = .seconds(60)

    public nonisolated let config: ExecConfig
    private let cluster: Cluster
    private let shell: LoginShellEnvironment
    private let cooldown: Duration
    private var cached: (credentials: Credentials, expiresAt: Date?)?
    private var generation: UInt64 = 0
    private var inFlight: Task<Credentials, Error>?
    /// Monotonic, so setting the clock back cannot hold the breaker open.
    private var lastFailure: (error: any Error, at: ContinuousClock.Instant)?
    private var failureReported = false
    /// Failures sent to `failures()`; tests check each failed run is reported once, not once per waiting caller.
    private(set) var reportedFailureCount = 0
    private var failureContinuation: AsyncStream<(any Error)?>.Continuation?

    public init(config: ExecConfig, cluster: Cluster, shell: LoginShellEnvironment = .shared) {
        self.init(config: config, cluster: cluster, shell: shell, cooldown: Self.failureCooldown)
    }

    init(config: ExecConfig, cluster: Cluster, shell: LoginShellEnvironment, cooldown: Duration) {
        self.config = config
        self.cluster = cluster
        self.shell = shell
        self.cooldown = cooldown
    }

    /// Plugin failures as they happen, and `nil` once a later run succeeds. One consumer: subscribing again ends the
    /// previous stream. A failure that is still current is delivered immediately.
    public func failures() -> AsyncStream<(any Error)?> {
        let (stream, continuation) = AsyncStream.makeStream(of: (any Error)?.self, bufferingPolicy: .bufferingNewest(1))
        failureContinuation?.finish()
        failureContinuation = continuation
        if let lastFailure { continuation.yield(lastFailure.error) }
        return stream
    }

    /// Lets the next request run the plugin again (the user signed in, or asked to retry).
    public func reset() {
        lastFailure = nil
    }

    public func credentials() async throws -> Credentials {
        if let cached, cached.expiresAt.map({ $0.timeIntervalSinceNow > Self.expiryLeeway }) ?? true {
            return cached.credentials
        }
        if let lastFailure, ContinuousClock.now - lastFailure.at < cooldown { throw lastFailure.error }
        // Concurrent callers share one plugin run and all get its finished result, generation included.
        if let inFlight { return try await inFlight.value }
        let task = Task { [config, cluster, shell] in
            do {
                return self.finished(try await Self.execute(config: config, cluster: cluster, shell: shell))
            } catch {
                self.failed(error)
                throw error
            }
        }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    /// Records a successful run once, whichever caller started it.
    private func finished(_ result: (Credentials, Date?)) -> Credentials {
        var (credentials, expiresAt) = result
        lastFailure = nil
        if failureReported {
            failureReported = false
            failureContinuation?.yield(nil)
        }
        // Every plugin result is a new generation, including expiry-driven refreshes, so a late 401 for the
        // previous token cannot evict this one.
        generation += 1
        credentials.generation = generation
        cached = (credentials, expiresAt)
        return credentials
    }

    /// Opens the breaker and reports the failure once, however many callers were waiting on the run.
    private func failed(_ error: any Error) {
        guard Self.tripsBreaker(error) else { return }
        lastFailure = (error, ContinuousClock.now)
        failureReported = true
        reportedFailureCount += 1
        failureContinuation?.yield(error)
    }

    /// A plugin that failed, could not start or timed out (an unfinished browser sign-in); not a cancelled request.
    public static func tripsBreaker(_ error: any Error) -> Bool {
        switch error {
        case is ExecPluginError: true
        case let error as ProcessRunnerError: if case .cancelled = error { false } else { true }
        default: false
        }
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
            do {
                credentials.identity = try await ClientIdentityFactory.identity(certificatePEM: Data(cert.utf8), keyPEM: Data(key.utf8))
            } catch {
                throw ExecPluginError.invalidOutput(command: command, reason: "unusable client certificate: \(error.localizedDescription)")
            }
        }
        guard credentials.bearerToken != nil || credentials.identity != nil else {
            throw ExecPluginError.invalidOutput(command: command, reason: "status has neither token nor client certificate")
        }
        return (credentials, status.expirationTimestamp.flatMap(KubeTimestamp.parse))
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
}
