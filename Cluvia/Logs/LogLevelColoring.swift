import AppKit

/// Colors whole log lines by severity so errors stand out in a fast-moving stream. Matches the common shapes:
/// `level=error`, `ERROR`, `[warn]`, `E1020 …` (klog), `"level":"error"` (JSON).
enum LogLevelColoring {
    static let error = try! NSRegularExpression(
        pattern: #"^.*(?:\blevel"?[=:]\s*"?(?:error|err|fatal|panic|crit)\b|\b(?:ERROR|FATAL|PANIC|CRITICAL)\b|^[EF]\d{4} ).*$"#,
        options: [.anchorsMatchLines, .caseInsensitive]
    )
    static let warning = try! NSRegularExpression(
        pattern: #"^.*(?:\blevel"?[=:]\s*"?warn(?:ing)?\b|\bWARN(?:ING)?\b|^W\d{4} ).*$"#,
        options: [.anchorsMatchLines]
    )

    static func apply(to storage: NSTextStorage, from start: Int) {
        let range = NSRange(location: start, length: storage.length - start)
        for (pattern, color) in [(warning, NSColor.systemOrange), (error, NSColor.systemRed)] {
            for match in pattern.matches(in: storage.string, range: range) {
                storage.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }
    }
}
