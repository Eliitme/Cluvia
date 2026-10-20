import Foundation

/// One kubeconfig file. Field names follow the kubeconfig YAML schema (`clientcmd/api/v1`).
public struct KubeConfig: Codable, Sendable, Equatable {
    public var clusters: [NamedCluster]
    public var users: [NamedAuthInfo]
    public var contexts: [NamedContext]
    public var currentContext: String?

    enum CodingKeys: String, CodingKey {
        case clusters, users, contexts
        case currentContext = "current-context"
    }

    public init(clusters: [NamedCluster] = [], users: [NamedAuthInfo] = [], contexts: [NamedContext] = [], currentContext: String? = nil) {
        self.clusters = clusters
        self.users = users
        self.contexts = contexts
        self.currentContext = currentContext
    }

    public init(from decoder: Decoder) throws {
        // Real-world kubeconfigs often carry `null` lists or omit sections entirely.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clusters = try c.decodeIfPresent([NamedCluster].self, forKey: .clusters) ?? []
        users = try c.decodeIfPresent([NamedAuthInfo].self, forKey: .users) ?? []
        contexts = try c.decodeIfPresent([NamedContext].self, forKey: .contexts) ?? []
        currentContext = try c.decodeIfPresent(String.self, forKey: .currentContext).flatMap { $0.isEmpty ? nil : $0 }
    }
}

public struct NamedCluster: Codable, Sendable, Equatable {
    public var name: String
    public var cluster: Cluster
}

public struct Cluster: Codable, Sendable, Equatable {
    /// Empty when the kubeconfig omits it; the context is still listed (as kubectl does) and fails on connect.
    public var server: String
    public var certificateAuthority: String?
    public var certificateAuthorityData: String?
    public var insecureSkipTLSVerify: Bool?
    public var proxyURL: String?
    public var tlsServerName: String?

    enum CodingKeys: String, CodingKey {
        case server
        case certificateAuthority = "certificate-authority"
        case certificateAuthorityData = "certificate-authority-data"
        case insecureSkipTLSVerify = "insecure-skip-tls-verify"
        case proxyURL = "proxy-url"
        case tlsServerName = "tls-server-name"
    }

    public init(
        server: String, certificateAuthority: String? = nil, certificateAuthorityData: String? = nil,
        insecureSkipTLSVerify: Bool? = nil, proxyURL: String? = nil, tlsServerName: String? = nil
    ) {
        self.server = server
        self.certificateAuthority = certificateAuthority
        self.certificateAuthorityData = certificateAuthorityData
        self.insecureSkipTLSVerify = insecureSkipTLSVerify
        self.proxyURL = proxyURL
        self.tlsServerName = tlsServerName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        server = try c.decodeIfPresent(String.self, forKey: .server) ?? ""
        certificateAuthority = try c.decodeIfPresent(String.self, forKey: .certificateAuthority)
        certificateAuthorityData = try c.decodeIfPresent(String.self, forKey: .certificateAuthorityData)
        insecureSkipTLSVerify = try c.decodeIfPresent(Bool.self, forKey: .insecureSkipTLSVerify)
        proxyURL = try c.decodeIfPresent(String.self, forKey: .proxyURL)
        tlsServerName = try c.decodeIfPresent(String.self, forKey: .tlsServerName)
    }
}

public struct NamedAuthInfo: Codable, Sendable, Equatable {
    public var name: String
    public var user: AuthInfo
}

public struct AuthInfo: Codable, Sendable, Equatable {
    public var clientCertificate: String?
    public var clientCertificateData: String?
    public var clientKey: String?
    public var clientKeyData: String?
    public var token: String?
    public var tokenFile: String?
    public var exec: ExecConfig?
    /// Decoded only to report them as unsupported instead of silently sending anonymous requests.
    public var authProvider: AuthProviderConfig?
    public var username: String?

    public init(token: String? = nil, exec: ExecConfig? = nil) {
        self.token = token
        self.exec = exec
    }

    enum CodingKeys: String, CodingKey {
        case clientCertificate = "client-certificate"
        case clientCertificateData = "client-certificate-data"
        case clientKey = "client-key"
        case clientKeyData = "client-key-data"
        case token, tokenFile, exec, username
        case authProvider = "auth-provider"
    }
}

public struct AuthProviderConfig: Codable, Sendable, Equatable {
    public var name: String
}

public struct ExecConfig: Codable, Sendable, Equatable {
    public var apiVersion: String?
    public var command: String
    public var args: [String]?
    public var env: [ExecEnvVar]?
    public var provideClusterInfo: Bool?
    public var interactiveMode: String?
    public var installHint: String?

    public init(apiVersion: String? = nil, command: String, args: [String]? = nil, env: [ExecEnvVar]? = nil) {
        self.apiVersion = apiVersion
        self.command = command
        self.args = args
        self.env = env
    }
}

public struct ExecEnvVar: Codable, Sendable, Equatable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct NamedContext: Codable, Sendable, Equatable {
    public var name: String
    public var context: Context
}

public struct Context: Codable, Sendable, Equatable {
    public var cluster: String
    public var user: String
    public var namespace: String?

    public init(from decoder: Decoder) throws {
        // Partial contexts are listed rather than failing the whole file; resolve() reports what is missing.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cluster = try c.decodeIfPresent(String.self, forKey: .cluster) ?? ""
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        namespace = try c.decodeIfPresent(String.self, forKey: .namespace)
    }

    enum CodingKeys: String, CodingKey {
        case cluster, user, namespace
    }
}
