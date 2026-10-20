import Foundation

/// What a request needs to authenticate: a bearer token, a TLS client identity, or both.
public struct Credentials: Sendable {
    public var bearerToken: String?
    public var identity: ClientIdentity?
    /// Identifies which cached credential set this is, so a late 401 cannot evict a newer set.
    public var generation: UInt64

    public init(bearerToken: String? = nil, identity: ClientIdentity? = nil, generation: UInt64 = 0) {
        self.bearerToken = bearerToken
        self.identity = identity
        self.generation = generation
    }
}

public protocol CredentialProvider: Sendable {
    func credentials() async throws -> Credentials
    /// Drops cached credentials after the server rejected them (HTTP 401). No-op if `generation` is already stale,
    /// so concurrent 401s from one expired token trigger a single refresh (one plugin run / login prompt).
    func invalidate(generation: UInt64) async
}

public enum CredentialError: Error, LocalizedError, Sendable {
    case unreadableFile(path: String, reason: String)
    case incompleteClientCertificate
    case invalidData(field: String)
    case unsupportedAuth(String)

    public var errorDescription: String? {
        switch self {
        case let .unreadableFile(path, reason): "Cannot read \(path): \(reason)"
        case .incompleteClientCertificate: "User has a client certificate without a key (or a key without a certificate)"
        case let .invalidData(field): "Kubeconfig field \(field) is invalid"
        case let .unsupportedAuth(kind): "Authentication method \(kind) is not supported; use an exec credential plugin instead"
        }
    }
}

/// Credentials stored directly in the kubeconfig: token, tokenFile, client certificate/key (inline or file).
public actor StaticCredentialProvider: CredentialProvider {
    private let user: AuthInfo
    private var identity: ClientIdentity?
    private var generation: UInt64 = 0

    public init(user: AuthInfo) {
        self.user = user
    }

    public func credentials() async throws -> Credentials {
        let credentials = Credentials(bearerToken: try bearerToken(), identity: try await clientIdentity(), generation: generation)
        if credentials.bearerToken == nil, credentials.identity == nil {
            if let provider = user.authProvider?.name { throw CredentialError.unsupportedAuth("auth-provider \"\(provider)\"") }
            if user.username != nil { throw CredentialError.unsupportedAuth("username/password") }
        }
        return credentials
    }

    public func invalidate(generation stale: UInt64) {
        guard stale == generation else { return }
        // Rebuilt from disk on next use, picking up a renewed certificate file.
        identity = nil
        generation += 1
    }

    private func bearerToken() throws -> String? {
        // tokenFile wins over token (client-go semantics) and is re-read on every call: projected
        // service-account tokens are rotated in place.
        if let tokenFile = user.tokenFile, !tokenFile.isEmpty {
            let token = try Self.read(tokenFile).trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? nil : token
        }
        return user.token.flatMap { $0.isEmpty ? nil : $0 }
    }

    private func clientIdentity() async throws -> ClientIdentity? {
        if let identity { return identity }
        let cert = try Self.material(data: user.clientCertificateData, file: user.clientCertificate, field: "client-certificate-data")
        let key = try Self.material(data: user.clientKeyData, file: user.clientKey, field: "client-key-data")
        switch (cert, key) {
        case (nil, nil): return nil
        case let (cert?, key?):
            let built = try await ClientIdentityFactory.identity(certificatePEM: cert, keyPEM: key)
            identity = built
            return built
        default: throw CredentialError.incompleteClientCertificate
        }
    }

    static func material(data: String?, file: String?, field: String) throws -> Data? {
        if let data, !data.isEmpty {
            guard let decoded = PEM.decodeKubeconfigData(data) else { throw CredentialError.invalidData(field: field) }
            return decoded
        }
        guard let file, !file.isEmpty else { return nil }
        return Data(try read(file).utf8)
    }

    static func read(_ path: String) throws -> String {
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw CredentialError.unreadableFile(path: path, reason: error.localizedDescription)
        }
    }
}

public enum CredentialProviderFactory {
    /// Exec plugins take precedence over static fields, matching client-go.
    public static func make(for context: ResolvedContext, shell: LoginShellEnvironment = .shared) -> any CredentialProvider {
        if let exec = context.user.exec {
            return ExecCredentialProvider(config: exec, cluster: context.cluster, shell: shell)
        }
        return StaticCredentialProvider(user: context.user)
    }
}
