import AppKit

/// Colors whole log lines by severity so errors stand out in a fast-moving stream. Matches `level=error` /
/// `"level":"warn"` (any case), bare upper-case `ERROR`/`WARN`, bracketed `[error]`/`[warn]`, and klog's
/// `E1020`/`W1020` prefixes, also after a timestamp or a `pod │ ` prefix. A lower-case "error" in a message
/// (`error=null`) does not count.
enum LogLevelColoring {
    private static let prefix = #"^(?:\S+ )?(?:[A-Za-z0-9.\-]+ │ )?"#

    static let error = try! NSRegularExpression(
        pattern: #"^.*(?:\blevel"?[=:]\s*"?(?i:error|err|fatal|panic|crit)\b|\b(?:ERROR|FATAL|PANIC|CRITICAL)\b|\[(?i:error|fatal)\]).*$|"#
            + prefix + #"[EF]\d{4} .*$"#,
        options: .anchorsMatchLines
    )
    static let warning = try! NSRegularExpression(
        pattern: #"^.*(?:\blevel"?[=:]\s*"?(?i:warn(?:ing)?)\b|\bWARN(?:ING)?\b|\[(?i:warn(?:ing)?)\]).*$|"# + prefix + #"W\d{4} .*$"#,
        options: .anchorsMatchLines
    )

    /// Colors lines from `start`; the caller groups this with other attribute changes in one editing pass.
    static func apply(to storage: NSTextStorage, text: String, from start: Int) {
        let range = NSRange(location: start, length: (text as NSString).length - start)
        for (pattern, color) in [(warning, NSColor.systemOrange), (error, NSColor.systemRed)] {
            for match in pattern.matches(in: text, range: range) {
                storage.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }
    }
}
