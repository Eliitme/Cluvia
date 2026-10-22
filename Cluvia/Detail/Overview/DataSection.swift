import KubeKit
import SwiftUI

/// `data` of a ConfigMap or Secret, one row per key with a Copy button. Secret values stay masked until revealed;
/// copying one works while masked and goes through `SecretPasteboard`.
struct DataSection: View {
    let json: JSONValue
    let secret: Bool
    @Binding var reveal: Bool
    @State private var copiedKey: String?
    @State private var copyCount = 0

    var body: some View {
        let entries = (json["data"]?.objectValue ?? [:]).sorted { $0.key < $1.key }
        DetailSection("Data (\(entries.count))") {
            if secret {
                GridRow { Toggle("Reveal values", isOn: $reveal).gridCellColumns(2) }
            }
            ForEach(entries, id: \.key) { entry in
                DetailRow(entry.key) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(secret ? (reveal ? SecretMasking.decoded(entry.value) : SecretMasking.placeholder) : entry.value.displayText)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(8)
                        Spacer(minLength: 4)
                        Button { copy(entry.key, entry.value) } label: {
                            Image(systemName: copiedKey == entry.key ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy value")
                    }
                }
            }
            if secret, copiedKey != nil {
                GridRow {
                    Text("Copied to this Mac only. The clipboard clears in \(Int(SecretPasteboard.clearAfter.components.seconds)) seconds.")
                        .font(.caption).foregroundStyle(.secondary).gridCellColumns(2)
                }
            }
        }
    }

    private func copy(_ key: String, _ value: JSONValue) {
        if secret {
            // Binary values are copied as their base64 text; anything else as the decoded text.
            SecretPasteboard.copy(SecretMasking.decodedUTF8(value) ?? value.displayText)
        } else {
            SecretPasteboard.copyPlain(value.displayText)
        }
        copiedKey = key
        copyCount += 1
        let copy = copyCount
        Task {
            // A secret's note stays for as long as the value is on the clipboard; a later copy restarts it.
            try? await Task.sleep(for: secret ? SecretPasteboard.clearAfter : .seconds(2))
            if copyCount == copy { copiedKey = nil }
        }
    }
}
