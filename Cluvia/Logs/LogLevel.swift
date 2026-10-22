import Foundation

/// Severity of a log line, decided once from its raw text when it arrives (before any pod prefix, timestamp or
/// formatting is added), so coloring, the level filter and jumping to errors always agree.
///
/// Matches `level=error` / `"level" : "warn"` (any case), bare upper-case `ERROR`/`WARN`, bracketed
/// `[error]`/`[warn]`, and klog's `E1020`/`W1020` line prefixes. A lower-case "error" in a message (`error=null`)
/// does not count.
enum LogLevel: Int, Comparable, Sendable {
    case other, warning, error

    static let errorPattern = try! NSRegularExpression(
        pattern: #"\blevel"?\s*[=:]\s*"?(?i:error|err|fatal|panic|crit)\b|\b(?:ERROR|FATAL|PANIC|CRITICAL)\b|\[(?i:error|fatal)\]|^[EF]\d{4} "#
    )
    static let warningPattern = try! NSRegularExpression(
        pattern: #"\blevel"?\s*[=:]\s*"?(?i:warn(?:ing)?)\b|\bWARN(?:ING)?\b|\[(?i:warn(?:ing)?)\]|^W\d{4} "#
    )

    static func classify(_ text: String) -> LogLevel {
        let range = NSRange(text.startIndex..., in: text)
        if errorPattern.firstMatch(in: text, range: range) != nil { return .error }
        if warningPattern.firstMatch(in: text, range: range) != nil { return .warning }
        return .other
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}
