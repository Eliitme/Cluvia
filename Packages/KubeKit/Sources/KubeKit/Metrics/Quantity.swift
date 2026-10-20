import Foundation

/// Kubernetes resource quantities (`250m`, `1.5`, `128Mi`, `2G`, `1e3`) as plain numbers:
/// CPU in cores, memory in bytes.
public enum Quantity {
    private static let suffixes: [(String, Double)] = [
        ("Ki", 1024), ("Mi", pow(1024, 2)), ("Gi", pow(1024, 3)), ("Ti", pow(1024, 4)), ("Pi", pow(1024, 5)), ("Ei", pow(1024, 6)),
        ("n", 1e-9), ("u", 1e-6), ("m", 1e-3), ("k", 1e3), ("M", 1e6), ("G", 1e9), ("T", 1e12), ("P", 1e15), ("E", 1e18),
    ]

    public static func parse(_ text: String) -> Double? {
        let value = text.trimmingCharacters(in: .whitespaces)
        for (suffix, factor) in suffixes where value.hasSuffix(suffix) {
            return Double(value.dropLast(suffix.count)).map { $0 * factor }
        }
        return Double(value)
    }

    /// `435m`, `1.2` — the way kubectl shows CPU.
    public static func formatCPU(_ cores: Double) -> String {
        cores < 1 ? "\(Int((cores * 1000).rounded()))m" : String(format: "%.2f", cores)
    }

    /// `316Ki`, `12Mi`, `1.4Gi` — binary units, as kubectl shows memory.
    public static func formatMemory(_ bytes: Double) -> String {
        let units = ["", "Ki", "Mi", "Gi", "Ti"]
        var value = bytes, index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return index >= 3 ? String(format: "%.1f%@", value, units[index]) : "\(Int(value.rounded()))\(units[index])"
    }
}
