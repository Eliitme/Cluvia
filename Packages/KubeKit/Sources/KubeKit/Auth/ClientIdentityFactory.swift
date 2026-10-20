import Foundation
import Security

/// TLS client identity usable in URLSession client-certificate challenges.
public struct ClientIdentity: @unchecked Sendable {
    // SecIdentity is an immutable CF object; sharing it across tasks is safe.
    public let identity: SecIdentity
    public let certificates: [SecCertificate]
    /// Keeps the backing temporary keychain alive (macOS 14 only) for as long as the identity is in use.
    let keychainOwner: TemporaryKeychain?

    var urlCredential: URLCredential {
        URLCredential(identity: identity, certificates: certificates.isEmpty ? nil : certificates, persistence: .forSession)
    }
}

public enum ClientIdentityError: Error, LocalizedError, Sendable {
    case missingCertificate
    case missingKey
    case pkcs12ExportFailed(String)
    case importFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .missingCertificate: "Client certificate PEM contains no CERTIFICATE block"
        case .missingKey: "Client key PEM contains no PRIVATE KEY block"
        case let .pkcs12ExportFailed(stderr): "Could not bundle client certificate and key: \(stderr)"
        case let .importFailed(status): "Could not import client identity (OSStatus \(status))"
        }
    }
}

/// Builds a `SecIdentity` from PEM certificate + key without writing the key to disk or any keychain.
///
/// macOS has no public API to pair a raw key with a certificate in memory, so the PEM pair is bundled into
/// PKCS#12 by the system `openssl` and imported in memory. The private key only travels over stdin and the
/// passphrase through the child env; the certificate (public data) goes through a short-lived temp file because
/// openssl reads its `-in` input twice and cannot rewind a pipe.
public enum ClientIdentityFactory {
    public static func identity(certificatePEM: Data, keyPEM: Data) async throws -> ClientIdentity {
        guard !PEM.derBlocks(in: certificatePEM, label: "CERTIFICATE").isEmpty else { throw ClientIdentityError.missingCertificate }
        guard String(decoding: keyPEM, as: UTF8.self).contains("PRIVATE KEY-----") else { throw ClientIdentityError.missingKey }

        let passphrase = randomPassphrase()
        let certURL = FileManager.default.temporaryDirectory.appendingPathComponent("cluvia-cert-\(UUID().uuidString).pem")
        try certificatePEM.write(to: certURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: certURL) }

        // Explicit SHA1/3DES PBE keeps the bundle importable regardless of the openssl flavor's defaults.
        let result = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/openssl"),
            arguments: [
                "pkcs12", "-export", "-passout", "env:CLUVIA_P12_PASS",
                "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES",
                "-in", certURL.path, "-inkey", "/dev/stdin",
            ],
            environment: ["CLUVIA_P12_PASS": passphrase, "PATH": "/usr/bin:/bin"],
            stdin: keyPEM,
            timeout: .seconds(10)
        )
        guard result.status == 0, !result.stdout.isEmpty else {
            throw ClientIdentityError.pkcs12ExportFailed(result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try importPKCS12(result.stdout, passphrase: passphrase)
    }

    static var supportsMemoryOnlyImport: Bool {
        if #available(macOS 15.0, *) { true } else { false }
    }

    static func importPKCS12(_ data: Data, passphrase: String, memoryOnly: Bool = supportsMemoryOnlyImport) throws -> ClientIdentity {
        var options: [String: Any] = [kSecImportExportPassphrase as String: passphrase]
        var keychainOwner: TemporaryKeychain?
        if memoryOnly, #available(macOS 15.0, *) {
            options[kSecImportToMemoryOnly as String] = true
        } else {
            let temporary = try TemporaryKeychain()
            options[kSecImportExportKeychain as String] = temporary.keychain
            keychainOwner = temporary
        }
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let rawIdentity = first[kSecImportItemIdentity as String] else {
            throw ClientIdentityError.importFailed(status)
        }
        let identity = rawIdentity as! SecIdentity // CF bridging: the value is always a SecIdentity
        let chain = (first[kSecImportItemCertChain as String] as? [SecCertificate]) ?? []
        // URLCredential expects intermediates only; the leaf comes from the identity.
        return ClientIdentity(identity: identity, certificates: Array(chain.dropFirst()), keychainOwner: keychainOwner)
    }

    private static func randomPassphrase() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
