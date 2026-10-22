import AppKit

/// Puts a secret on the clipboard the way password managers do: this Mac only (no Universal Clipboard), marked
/// concealed and transient so clipboard history tools skip it, and cleared after a while unless something else
/// was copied since.
@MainActor
enum SecretPasteboard {
    static let clearAfter: Duration = .seconds(60)
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static func copy(_ value: String, pasteboard: NSPasteboard = .general) {
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(value, forType: .string)
        pasteboard.setData(Data(), forType: concealedType)
        pasteboard.setData(Data(), forType: transientType)
        let copied = pasteboard.changeCount
        Task {
            try? await Task.sleep(for: clearAfter)
            if pasteboard.changeCount == copied { pasteboard.clearContents() }
        }
    }

    static func copyPlain(_ value: String, pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}
