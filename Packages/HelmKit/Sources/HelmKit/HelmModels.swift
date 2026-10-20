import Foundation
import KubeKit

public struct HelmRelease: Sendable, Hashable, Identifiable {
    public let name: String
    public let namespace: String
    public let revision: Int
    public let updated: String
    public let status: String
    public let chart: String
    public let appVersion: String

    public var id: String { "\(namespace)/\(name)" }

    /// Chart name without the version suffix (`demo-0.1.0` -> `demo`).
    public var chartName: String {
        guard let dash = chart.lastIndex(of: "-"), chart[chart.index(after: dash)...].first?.isNumber == true else { return chart }
        return String(chart[..<dash])
    }
}

public struct HelmRevision: Sendable, Hashable, Identifiable {
    public let revision: Int
    public let updated: String
    public let status: String
    public let chart: String
    public let appVersion: String
    public let description: String

    public var id: Int { revision }
}

/// Helm's JSON output differs between commands and major versions (e.g. `revision` is a string in `list`
/// and a number in `history`), so it is read leniently field by field.
enum HelmDecoding {
    static func field(_ json: JSONValue, _ key: String) -> String {
        json[key]?.displayText ?? ""
    }

    static func releases(_ data: Data) throws -> [HelmRelease] {
        (try JSONValue.parse(data).arrayValue ?? []).map { json in
            HelmRelease(
                name: field(json, "name"), namespace: field(json, "namespace"), revision: Int(field(json, "revision")) ?? 0,
                updated: field(json, "updated"), status: field(json, "status"), chart: field(json, "chart"),
                appVersion: field(json, "app_version")
            )
        }
    }

    static func history(_ data: Data) throws -> [HelmRevision] {
        (try JSONValue.parse(data).arrayValue ?? []).map { json in
            HelmRevision(
                revision: Int(field(json, "revision")) ?? 0, updated: field(json, "updated"), status: field(json, "status"),
                chart: field(json, "chart"), appVersion: field(json, "app_version"), description: field(json, "description")
            )
        }.sorted { $0.revision > $1.revision }
    }
}
