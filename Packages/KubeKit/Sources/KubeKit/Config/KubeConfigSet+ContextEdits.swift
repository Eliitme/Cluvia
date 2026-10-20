import Foundation
import Yams

/// Everything the context form edits: the context, the cluster and user it points at (existing ones are edited in
/// the file that defines them; unknown names are created), and new credentials.
public struct KubeContextDraft: Sendable, Equatable {
    public enum Credentials: Sendable, Equatable {
        /// Leave the user's authentication fields as they are.
        case unchanged
        case none
        case token(String)
        /// PEM text; stored base64-encoded as `client-certificate-data` / `client-key-data`.
        case clientCertificate(certificatePEM: String, keyPEM: String)
        case exec(command: String, arguments: [String], apiVersion: String)
    }

    public var name = ""
    public var namespace = ""
    public var clusterName = ""
    /// The cluster/user is meant to be new; an existing one with that name is an error, never silently edited.
    public var createsCluster = false
    public var createsUser = false
    public var server = ""
    /// PEM text of the cluster CA. Written only when it differs from `originalCertificateAuthorityPEM`.
    public var certificateAuthorityPEM = ""
    public var originalCertificateAuthorityPEM = ""
    public var insecureSkipTLSVerify = false
    public var userName = ""
    public var credentials: Credentials = .unchanged

    public init() {}
}

/// User fields that select an authentication method; replaced together so two methods never mix.
private let authKeys = [
    "client-certificate", "client-certificate-data", "client-key", "client-key-data",
    "token", "tokenFile", "exec", "auth-provider", "username", "password",
]

extension KubeConfigSet {
    /// The form contents for an existing context. Credentials are never read back into the form.
    public func draft(forContext name: String) throws -> KubeContextDraft {
        guard owner(.contexts, name) != nil else { throw KubeConfigEditError.notFound(section: "context", name: name) }
        var draft = KubeContextDraft()
        draft.name = name
        draft.namespace = field(.contexts, name, "namespace") ?? ""
        draft.userName = field(.contexts, name, "user") ?? ""
        loadCluster(field(.contexts, name, "cluster") ?? "", into: &draft)
        return draft
    }

    /// Fills the cluster fields from the named cluster (empty when it does not exist yet).
    public func loadCluster(_ name: String, into draft: inout KubeContextDraft) {
        draft.clusterName = name
        draft.server = field(.clusters, name, "server") ?? ""
        draft.certificateAuthorityPEM = field(.clusters, name, "certificate-authority-data")
            .flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        draft.originalCertificateAuthorityPEM = draft.certificateAuthorityPEM
        // YAML readers used by kubectl also accept True/TRUE.
        draft.insecureSkipTLSVerify = field(.clusters, name, "insecure-skip-tls-verify")?.lowercased() == "true"
    }

    /// Creates the context (`originalName` nil) or updates/renames it. Clusters and users are shared, so their edits
    /// apply to every context that references them.
    public mutating func apply(_ draft: KubeContextDraft, originalName: String?) throws {
        let trim = { (value: String) in value.trimmingCharacters(in: .whitespacesAndNewlines) }
        let (name, clusterName, userName, server) = (trim(draft.name), trim(draft.clusterName), trim(draft.userName), trim(draft.server))
        for (value, what) in [(name, "Context name"), (clusterName, "Cluster"), (userName, "User"), (server, "Server")] where value.isEmpty {
            throw KubeConfigEditError.missingValue(what)
        }
        let caChanged = trim(draft.certificateAuthorityPEM) != trim(draft.originalCertificateAuthorityPEM)
        if draft.insecureSkipTLSVerify, !trim(draft.certificateAuthorityPEM).isEmpty {
            throw KubeConfigEditError.invalidValue("Skipping TLS verification cannot be combined with a CA certificate")
        }
        if draft.createsCluster, owner(.clusters, clusterName) != nil {
            throw KubeConfigEditError.duplicateName(section: "cluster", name: clusterName)
        }
        if draft.createsUser, owner(.users, userName) != nil {
            throw KubeConfigEditError.duplicateName(section: "user", name: userName)
        }
        let userIndex = owner(.users, userName)
        if userIndex == nil, draft.credentials == .unchanged {
            throw KubeConfigEditError.missingValue("An authentication method for the new user \"\(userName)\"")
        }
        // Validate everything that can fail before touching any file.
        let caData = caChanged && !trim(draft.certificateAuthorityPEM).isEmpty ? try Self.base64(draft.certificateAuthorityPEM, what: "CA certificate") : nil
        let user = try credentialFields(draft.credentials)

        let contextIndex: Int
        if let originalName {
            guard let index = owner(.contexts, originalName) else { throw KubeConfigEditError.notFound(section: "context", name: originalName) }
            if name != originalName {
                guard owner(.contexts, name) == nil else { throw KubeConfigEditError.duplicateName(section: "context", name: name) }
                try modify(index) { try $0.rename(.contexts, from: originalName, to: name) }
                if currentContext == originalName { setCurrentContext(name) }
            }
            contextIndex = index
        } else {
            guard owner(.contexts, name) == nil else { throw KubeConfigEditError.duplicateName(section: "context", name: name) }
            contextIndex = primary
        }
        modify(contextIndex) { document in
            var context = document.body(.contexts, name) ?? [:]
            context["cluster"] = .str(clusterName)
            context["user"] = .str(userName)
            let namespace = trim(draft.namespace)
            context["namespace"] = namespace.isEmpty ? nil : .str(namespace)
            document.setBody(.contexts, name, context)
        }

        let clusterIndex = owner(.clusters, clusterName) ?? contextIndex
        modify(clusterIndex) { document in
            var cluster = document.body(.clusters, clusterName) ?? [:]
            cluster["server"] = .str(server)
            cluster["insecure-skip-tls-verify"] = draft.insecureSkipTLSVerify ? Node("true", Tag(.bool)) : nil
            if caChanged {
                cluster["certificate-authority-data"] = caData.map { .str($0) }
                if caData != nil { cluster["certificate-authority"] = nil }
            }
            document.setBody(.clusters, clusterName, cluster)
        }

        if let user {
            modify(userIndex ?? contextIndex) { document in
                var body = document.body(.users, userName) ?? [:]
                for key in authKeys { body[key] = nil }
                for (key, value) in user { body[key] = value }
                document.setBody(.users, userName, body)
            }
        }
    }

    /// Fields for the chosen authentication method; nil keeps the user's current ones.
    private func credentialFields(_ credentials: KubeContextDraft.Credentials) throws -> [(String, Node)]? {
        switch credentials {
        case .unchanged:
            return nil
        case .none:
            return []
        case let .token(token):
            return [("token", .str(token.trimmingCharacters(in: .whitespacesAndNewlines)))]
        case let .clientCertificate(certificate, key):
            return [
                ("client-certificate-data", .str(try Self.base64(certificate, what: "client certificate"))),
                ("client-key-data", .str(try Self.base64(key, what: "private key"))),
            ]
        case let .exec(command, arguments, apiVersion):
            guard !apiVersion.isEmpty else { throw KubeConfigEditError.missingValue("The plugin API version") }
            // client.authentication.k8s.io/v1 requires interactiveMode; IfAvailable matches kubectl's default.
            var exec: Node.Mapping = [
                Node("apiVersion"): .str(apiVersion), Node("command"): .str(command), Node("interactiveMode"): .str("IfAvailable"),
            ]
            if !arguments.isEmpty { exec["args"] = .sequence(Node.Sequence(arguments.map { .str($0) })) }
            return [("exec", .mapping(exec))]
        }
    }

    /// PEM text (anything containing a PEM block, e.g. with leading `subject=` lines) is base64-encoded; text that
    /// is already base64 of a PEM block is kept.
    static func base64(_ text: String, what: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("-----BEGIN") { return Data((trimmed + "\n").utf8).base64EncodedString() }
        let compact = trimmed.filter { !$0.isWhitespace }
        if let decoded = Data(base64Encoded: compact), String(decoding: decoded, as: UTF8.self).contains("-----BEGIN") { return compact }
        throw KubeConfigEditError.invalidValue("The \(what) must be PEM text (-----BEGIN …)")
    }
}
