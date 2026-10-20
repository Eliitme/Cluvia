import Foundation
import Security

/// How the API server certificate is validated for one cluster.
public struct TrustPolicy: @unchecked Sendable {
    // SecCertificate values are immutable CF objects.
    public let anchors: [SecCertificate]
    public let insecureSkipVerify: Bool
    /// Overrides the hostname checked against the server certificate (`tls-server-name`). URLSession cannot
    /// change the SNI it sends, so this only affects verification.
    public let serverName: String?

    public init(anchors: [SecCertificate] = [], insecureSkipVerify: Bool = false, serverName: String? = nil) {
        self.anchors = anchors
        self.insecureSkipVerify = insecureSkipVerify
        self.serverName = serverName
    }

    /// Builds the policy from kubeconfig cluster fields; inline CA data wins over a CA file.
    public static func from(_ cluster: Cluster) throws -> TrustPolicy {
        var anchors: [SecCertificate] = []
        if let data = cluster.certificateAuthorityData, !data.isEmpty {
            anchors = PEM.decodeKubeconfigData(data).map(PEM.certificates(in:)) ?? []
            guard !anchors.isEmpty else { throw CredentialError.invalidData(field: "certificate-authority-data") }
        } else if let file = cluster.certificateAuthority, !file.isEmpty {
            anchors = PEM.certificates(in: Data(try StaticCredentialProvider.read(file).utf8))
            guard !anchors.isEmpty else { throw CredentialError.invalidData(field: "certificate-authority") }
        }
        return TrustPolicy(
            anchors: anchors,
            insecureSkipVerify: cluster.insecureSkipTLSVerify ?? false,
            serverName: cluster.tlsServerName.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

enum TrustEvaluator {
    /// Same rules as kubectl: with a cluster CA configured only that CA is trusted; without one the system roots
    /// are used (clusters behind public CAs). Returns nil when trusted, otherwise the failure reason.
    static func failureReason(_ trust: SecTrust, host: String, policy: TrustPolicy) -> String? {
        if policy.insecureSkipVerify { return nil }
        let sslPolicy = SecPolicyCreateSSL(true, (policy.serverName ?? host) as CFString)
        guard SecTrustSetPolicies(trust, sslPolicy) == errSecSuccess else { return "could not apply TLS policy" }
        if !policy.anchors.isEmpty {
            guard SecTrustSetAnchorCertificates(trust, policy.anchors as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else { return "could not apply cluster CA" }
        }
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) { return nil }
        return error.map { CFErrorCopyDescription($0) as String } ?? "certificate not trusted"
    }
}
