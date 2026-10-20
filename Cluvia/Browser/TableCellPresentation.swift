import AppKit

/// How a table cell's text is shown; sorting and filtering keep using the raw text.
enum TableCellPresentation {
    static let restartsPattern = try! NSRegularExpression(pattern: #"^(\d+) \((.+)\)$"#)

    /// Status words get a colored symbol (shape as well as color); "Restarts" keeps the count and moves
    /// "(2m ago)" into the tooltip; anything else is plain.
    static func present(_ value: String, column: String, font: NSFont) -> (text: NSAttributedString, tooltip: String?) {
        let tone = StatusTone.of(value, column: column)
        // Attributed text replaces the field's own line break mode, so truncation is restated here.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tone.color, .paragraphStyle: paragraph]
        if column.lowercased() == "restarts",
           let match = restartsPattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
           let count = Range(match.range(at: 1), in: value), let when = Range(match.range(at: 2), in: value) {
            return (NSAttributedString(string: String(value[count]), attributes: attributes), "\(value[count]) restarts, last \(value[when])")
        }
        let text = NSMutableAttributedString(string: value, attributes: attributes)
        if let symbol = tone.symbol, ["status", "phase", "state"].contains(column.lowercased()),
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
               .withSymbolConfiguration(.init(pointSize: font.pointSize - 2, weight: .semibold).applying(.init(paletteColors: [tone.color]))) {
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(x: 0, y: -1, width: image.size.width, height: image.size.height)
            text.insert(NSAttributedString(string: " ", attributes: attributes), at: 0)
            let symbolText = NSMutableAttributedString(attachment: attachment)
            symbolText.addAttributes(attributes, range: NSRange(location: 0, length: symbolText.length))
            text.insert(symbolText, at: 0)
        }
        return (text, value.count > 24 ? value : nil)
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
}
