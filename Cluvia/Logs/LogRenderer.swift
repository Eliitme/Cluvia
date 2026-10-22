import AppKit
import KubeKit

/// One line of rendered text: where it is (UTF-16 range, relative to the rendered chunk), its severity and pod.
struct RenderedLine: Sendable, Hashable {
    let range: NSRange
    let level: LogLevel
    let source: Int
    /// The pod name inside the `pod │ ` prefix, for coloring.
    let podRange: NSRange?
    /// First text line of its entry (pretty-printed JSON continues on the following lines).
    let startsEntry: Bool
}

struct LogRender: Sendable {
    var text = ""
    var lines: [RenderedLine] = []
}

/// Turns log entries into text and per-line ranges. Pure and nonisolated, so a full redraw of 100k lines can be
/// built off the main thread. A pretty-printed JSON line becomes several text lines that all repeat the pod prefix
/// and share the entry's severity.
enum LogRenderer {
    static let podColors: [NSColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemPink, .systemTeal, .systemYellow, .systemIndigo]

    /// `pods` names each source for a multi-pod view (nil for one pod, which needs no prefix). `leadingNewline`
    /// separates this chunk from text already shown.
    static func render(_ entries: some Sequence<LogEntry>, pods: [String]?, options: LogDisplayOptions, filter: LogLineFilter? = nil,
                       leadingNewline: Bool = false, timeZone: TimeZone = .current) -> LogRender {
        let filter = filter ?? options.lineFilter
        var clock = options.showTimestamps && options.localTime ? LocalClock(timeZone: timeZone) : nil
        var render = LogRender()
        var length = 0
        var first = !leadingNewline
        for entry in entries {
            let pod = pods.flatMap { $0.indices.contains(entry.source) ? $0[entry.source] : nil }
            guard filter.showsEverything || filter.accepts(entry, pod: pod) else { continue }
            var stamp = ""
            if options.showTimestamps, let timestamp = entry.line.timestamp {
                stamp = (clock?.format(timestamp) ?? timestamp) + " "
            }
            for (index, body) in bodies(of: entry.line.text, pretty: options.prettyJSON).enumerated() {
                if !first { render.text += "\n"; length += 1 }
                first = false
                let lead = index == 0 ? stamp : String(repeating: " ", count: stamp.count)
                var podRange: NSRange?
                var line = lead
                if let pod {
                    podRange = NSRange(location: length + lead.utf16.count, length: pod.utf16.count)
                    line += pod + " │ "
                }
                line += body
                let lineLength = line.utf16.count
                render.lines.append(RenderedLine(range: NSRange(location: length, length: lineLength), level: entry.level,
                                                 source: entry.source, podRange: podRange, startsEntry: index == 0))
                render.text += line
                length += lineLength
            }
        }
        return render
    }

    /// Text with severity and pod colors; built off the main thread for full redraws.
    static func attributed(_ render: LogRender, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: render.text, attributes: [.font: font, .foregroundColor: NSColor.textColor])
        result.beginEditing()
        for line in render.lines {
            switch line.level {
            case .error: result.addAttribute(.foregroundColor, value: NSColor.systemRed, range: line.range)
            case .warning: result.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: line.range)
            case .other: break
            }
            if let podRange = line.podRange {
                result.addAttribute(.foregroundColor, value: podColors[line.source % podColors.count], range: podRange)
            }
        }
        result.endEditing()
        return result
    }

    /// A JSON object pretty-printed over several lines, or the text unchanged.
    static func bodies(of text: String, pretty: Bool) -> [Substring] {
        guard pretty, text.drop(while: \.isWhitespace).first == "{", let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data), JSONSerialization.isValidJSONObject(object),
              let formatted = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return [Substring(text)] }
        return String(decoding: formatted, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
    }

}

/// Kubelet timestamps (`2026-10-20T06:00:00.123456789Z`) in a local time zone, as `2026-10-20 13:00:00.123`.
/// Lines arrive many per second, so the date part is formatted once per second and the milliseconds are copied.
struct LocalClock {
    private let formatter: DateFormatter
    private var seconds: [Substring: String] = [:]

    init(timeZone: TimeZone) {
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    }

    /// nil for a timestamp that is not UTC RFC 3339 (shown as received).
    mutating func format(_ timestamp: String) -> String? {
        guard timestamp.count >= 20, timestamp.hasSuffix("Z") else { return nil }
        let whole = timestamp.prefix(19)
        let local: String
        if let cached = seconds[whole] {
            local = cached
        } else {
            guard let date = KubeTimestamp.parse(whole + "Z") else { return nil }
            local = formatter.string(from: date)
            seconds[whole] = local
        }
        // The kubelet trims trailing zeros (and the dot for whole seconds); pad so the column stays aligned.
        let fraction = timestamp.dropFirst(19).dropLast().drop { $0 == "." }.prefix(3)
        return local + "." + fraction.padding(toLength: 3, withPad: "0", startingAt: 0)
    }
}
