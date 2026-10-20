import Foundation
import Security

/// Minimal PEM helpers for kubeconfig certificate material.
enum PEM {
    /// DER payloads of every `-----BEGIN <label>-----` block with the given label.
    static func derBlocks(in pem: Data, label: String) -> [Data] {
        let text = String(decoding: pem, as: UTF8.self)
        let begin = "-----BEGIN \(label)-----"
        let end = "-----END \(label)-----"
        var blocks: [Data] = []
        var cursor = text.startIndex
        while let start = text.range(of: begin, range: cursor..<text.endIndex),
              let stop = text.range(of: end, range: start.upperBound..<text.endIndex) {
            let body = text[start.upperBound..<stop.lowerBound].filter { !$0.isWhitespace }
            if let der = Data(base64Encoded: String(body)) { blocks.append(der) }
            cursor = stop.upperBound
        }
        return blocks
    }

    static func certificates(in pem: Data) -> [SecCertificate] {
        derBlocks(in: pem, label: "CERTIFICATE").compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
    }

    /// Kubeconfig `*-data` fields are base64 of PEM text. Accepts raw PEM too, which some tools emit.
    static func decodeKubeconfigData(_ value: String) -> Data? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("-----BEGIN") { return Data(trimmed.utf8) }
        return Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters)
    }
}
