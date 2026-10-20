import Foundation
import Security

/// Throwaway file keychain used to hold an imported client identity on macOS 14, where `SecPKCS12Import`
/// otherwise writes the private key into the user's login keychain. Deleted when the last identity using it goes away.
final class TemporaryKeychain: @unchecked Sendable {
    // SecKeychain is only touched at init/deinit; the identity itself is used read-only by URLSession.
    let keychain: SecKeychain
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cluvia-kc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let path = directory.appendingPathComponent("identity.keychain").path
        let password = UUID().uuidString + UUID().uuidString
        var created: SecKeychain?
        let status = SecKeychainCreate(path, UInt32(password.utf8.count), password, false, nil, &created)
        guard status == errSecSuccess, let created else {
            try? FileManager.default.removeItem(at: directory)
            throw ClientIdentityError.importFailed(status)
        }
        keychain = created
    }

    deinit {
        SecKeychainDelete(keychain)
        try? FileManager.default.removeItem(at: directory)
    }
}
