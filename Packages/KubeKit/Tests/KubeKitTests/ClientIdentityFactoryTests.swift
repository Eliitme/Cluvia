import Foundation
import Security
import Testing
@testable import KubeKit

struct ClientIdentityFactoryTests {
    /// Generates a throwaway self-signed cert + key with a unique CN using the system openssl.
    static func makeCertificate(keyArgs: [String]) async throws -> (cert: Data, key: Data, commonName: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cn = "cluvia-test-\(UUID().uuidString.prefix(8))"
        let keyURL = dir.appendingPathComponent("key.pem")
        let certURL = dir.appendingPathComponent("cert.pem")
        let openssl = URL(fileURLWithPath: "/usr/bin/openssl")
        _ = try await ProcessRunner.run(openssl, arguments: keyArgs + ["-out", keyURL.path])
        let req = try await ProcessRunner.run(openssl, arguments: [
            "req", "-new", "-x509", "-key", keyURL.path, "-subj", "/CN=\(cn)", "-days", "1", "-out", certURL.path,
        ])
        #expect(req.status == 0, "\(req.stderrText)")
        return (try Data(contentsOf: certURL), try Data(contentsOf: keyURL), cn)
    }

    @Test(arguments: [
        ["genrsa", "2048"],
        ["ecparam", "-name", "prime256v1", "-genkey", "-noout"],
    ])
    func importsIdentityInMemoryOnly(keyArgs: [String]) async throws {
        let material = try await Self.makeCertificate(keyArgs: keyArgs)
        let identity = try await ClientIdentityFactory.identity(certificatePEM: material.cert, keyPEM: material.key)

        var cert: SecCertificate?
        #expect(SecIdentityCopyCertificate(identity.identity, &cert) == errSecSuccess)
        #expect(cert.flatMap { SecCertificateCopySubjectSummary($0) as String? } == material.commonName)

        // Nothing must be persisted to the user's keychain.
        let lookup = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/security"), arguments: ["find-certificate", "-c", material.commonName]
        )
        #expect(lookup.status != 0)
    }

    @Test func temporaryKeychainFallbackKeepsLoginKeychainClean() async throws {
        let material = try await Self.makeCertificate(keyArgs: ["genrsa", "2048"])
        let passphrase = "test-pass"
        let keyFile = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pem")
        let certFile = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pem")
        try material.key.write(to: keyFile)
        try material.cert.write(to: certFile)
        defer { [keyFile, certFile].forEach { try? FileManager.default.removeItem(at: $0) } }
        let p12 = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/openssl"), arguments: [
            "pkcs12", "-export", "-passout", "pass:\(passphrase)", "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES",
            "-in", certFile.path, "-inkey", keyFile.path,
        ])

        let identity = try ClientIdentityFactory.importPKCS12(p12.stdout, passphrase: passphrase, memoryOnly: false)
        #expect(identity.keychainOwner != nil)
        let lookup = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/security"), arguments: ["find-certificate", "-c", material.commonName]
        )
        #expect(lookup.status != 0)
    }

    @Test func rejectsMissingKey() async {
        await #expect(throws: ClientIdentityError.self) {
            try await ClientIdentityFactory.identity(certificatePEM: Data("nope".utf8), keyPEM: Data())
        }
    }
}
