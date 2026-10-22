import Foundation

/// How the log view shows lines; changing any of it redraws the whole view.
struct LogDisplayOptions: Hashable, Sendable {
    var showTimestamps = false
    /// Timestamps in this Mac's time zone instead of the kubelet's UTC.
    var localTime = false
    /// Lines that are a JSON object are shown indented over several lines.
    var prettyJSON = false
    var filter = ""
    var filterIsRegex = false
    var minimumLevel = LogLevel.other

    var lineFilter: LogLineFilter { LogLineFilter(text: filter, isRegex: filterIsRegex, minimumLevel: minimumLevel) }
}

/// Which lines are shown: at least `minimumLevel`, and containing the filter text (case-insensitive) or matching it
/// as a regular expression. Matching uses the line as received plus its pod name, never the formatted text.
struct LogLineFilter: Sendable {
    let minimumLevel: LogLevel
    private let regex: NSRegularExpression?
    /// False for a regular expression that does not compile; such a filter lets every line through.
    let isValid: Bool

    init(text: String, isRegex: Bool, minimumLevel: LogLevel) {
        self.minimumLevel = minimumLevel
        if text.isEmpty {
            regex = nil
            isValid = true
        } else {
            // Plain text runs as an escaped pattern too: it scans 100k lines faster than case-insensitive `range(of:)`.
            regex = try? NSRegularExpression(pattern: isRegex ? text : NSRegularExpression.escapedPattern(for: text), options: .caseInsensitive)
            isValid = regex != nil
        }
    }

    var showsEverything: Bool { minimumLevel == .other && regex == nil }

    func accepts(_ entry: LogEntry, pod: String?) -> Bool {
        guard entry.level >= minimumLevel else { return false }
        guard let regex else { return true }
        return Self.matches(regex, entry.line.text) || pod.map { Self.matches(regex, $0) } == true
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
