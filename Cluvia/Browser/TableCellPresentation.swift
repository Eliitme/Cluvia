import AppKit

/// How a table cell's text is shown; sorting and filtering keep using the raw text.
enum TableCellPresentation {
    enum Shown {
        /// Plain text and color: the field adapts it on selected rows.
        case plain(String, NSColor, tooltip: String?)
        /// Status text with a colored symbol in front.
        case symbol(NSAttributedString, tooltip: String?)
    }

    static let restartsPattern = try! NSRegularExpression(pattern: #"^(\d+) \((.+)\)$"#)
    @MainActor private static var symbols: [String: NSImage] = [:]

    /// Status words get a colored symbol (shape as well as color); "Restarts" keeps the count and moves
    /// "(2m ago)" into the tooltip; anything else is plain.
    @MainActor static func present(_ value: String, column: String, font: NSFont) -> Shown {
        let tone = StatusTone.of(value, column: column)
        if column.lowercased() == "restarts",
           let match = restartsPattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
           let count = Range(match.range(at: 1), in: value), let when = Range(match.range(at: 2), in: value) {
            return .plain(String(value[count]), tone.color, tooltip: "\(value[count]) restarts, last \(value[when])")
        }
        let tooltip = value.count > 24 ? value : nil
        guard let name = tone.symbol, ["status", "phase", "state"].contains(column.lowercased()),
              let image = symbol(name, tone: tone, size: font.pointSize - 2) else {
            return .plain(value, tone.color, tooltip: tooltip)
        }
        // Attributed text replaces the field's own line break mode, so truncation is restated here.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tone.color, .paragraphStyle: paragraph]
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: -1, width: image.size.width, height: image.size.height)
        let text = NSMutableAttributedString(attachment: attachment)
        text.append(NSAttributedString(string: " " + value))
        text.addAttributes(attributes, range: NSRange(location: 0, length: text.length))
        return .symbol(text, tooltip: tooltip)
    }

    /// Symbols are reused across cells and reloads (a watch update reloads every visible row).
    @MainActor private static func symbol(_ name: String, tone: StatusTone, size: CGFloat) -> NSImage? {
        let key = "\(name)|\(size)"
        if let cached = symbols[key] { return cached }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: tone.accessibilityName)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .semibold).applying(.init(paletteColors: [tone.color])))
        symbols[key] = image
        return image
    }
}

extension StatusTone {
    var symbol: String? {
        switch self {
        case .good: "checkmark.circle.fill"
        case .pending: "clock.fill"
        case .bad: "exclamationmark.triangle.fill"
        case .neutral: nil
        }
    }

    var accessibilityName: String {
        switch self {
        case .good: "Healthy"
        case .pending: "In progress"
        case .bad: "Problem"
        case .neutral: ""
        }
    }
}
