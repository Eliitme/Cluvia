import Foundation

/// RFC 3339 timestamps as emitted by the API server, with or without fractional seconds.
public enum KubeTimestamp {
    private static let plain = Date.ISO8601FormatStyle()
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    public static func parse(_ value: String) -> Date? {
        (try? plain.parse(value)) ?? (try? fractional.parse(value))
    }
}
