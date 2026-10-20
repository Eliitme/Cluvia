import Foundation

/// Compact relative age as kubectl prints it: `45s`, `12m`, `5h3m`, `3d4h`, `400d`.
enum AgeFormatter {
    static func string(since date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<120: return "\(seconds)s"
        case ..<(60 * 60): return "\(seconds / 60)m"
        case ..<(8 * 3600): return compound(seconds / 3600, "h", seconds % 3600 / 60, "m")
        case ..<(48 * 3600): return "\(seconds / 3600)h"
        case ..<(8 * 86400): return compound(seconds / 86400, "d", seconds % 86400 / 3600, "h")
        default: return "\(seconds / 86400)d"
        }
    }

    private static func compound(_ major: Int, _ majorUnit: String, _ minor: Int, _ minorUnit: String) -> String {
        minor == 0 ? "\(major)\(majorUnit)" : "\(major)\(majorUnit)\(minor)\(minorUnit)"
    }
}
