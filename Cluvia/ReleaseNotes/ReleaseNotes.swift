import Foundation

/// Releases read from the bundled CHANGELOG.md, in the format release-please writes:
///
///     ## [0.2.0](https://…/compare/v0.1.0...v0.2.0) (2026-10-21)
///     ### Features
///     * **logs:** highlight errors ([abc1234](https://…/commit/abc1234))
struct ReleaseNotes: Equatable {
    struct Release: Equatable, Identifiable {
        struct Section: Equatable {
            let title: String
            /// Markdown, with trailing commit links removed.
            var items: [String]
        }

        let version: String
        let date: String?
        var sections: [Section]
        var id: String { version }
    }

    let releases: [Release]

    static let versionPattern = try! NSRegularExpression(pattern: #"^## \[?(\d+\.\d+\.\d+[^\]\s]*)\]?(?:\([^)]*\))?(?: \((\d{4}-\d{2}-\d{2})\))?"#)
    static let commitLinkPattern = try! NSRegularExpression(pattern: #"\s*\(\[[0-9a-f]{7,40}\]\([^)]*\)\)\s*$"#)

    init(markdown: String) {
        var releases: [Release] = []
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let range = NSRange(line.startIndex..., in: line)
            if let match = Self.versionPattern.firstMatch(in: line, range: range), let version = Range(match.range(at: 1), in: line) {
                let date = Range(match.range(at: 2), in: line).map { String(line[$0]) }
                releases.append(Release(version: String(line[version]), date: date, sections: []))
            } else if line.hasPrefix("### "), !releases.isEmpty {
                releases[releases.count - 1].sections.append(.init(title: String(line.dropFirst(4)), items: []))
            } else if line.hasPrefix("* ") || line.hasPrefix("- "), let last = releases.indices.last, !releases[last].sections.isEmpty {
                let item = Self.commitLinkPattern.stringByReplacingMatches(in: String(line.dropFirst(2)), range: NSRange(location: 0, length: (line as NSString).length - 2), withTemplate: "")
                releases[last].sections[releases[last].sections.count - 1].items.append(item)
            }
        }
        self.releases = releases
    }

    func release(_ version: String) -> Release? {
        releases.first { $0.version == version }
    }

    /// The changelog shipped inside the app.
    static let bundled = ReleaseNotes(
        markdown: Bundle.main.url(forResource: "CHANGELOG", withExtension: "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    )

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}

/// Decides when to show "What's New": once after an update, never on a first install.
enum WhatsNew {
    static let lastSeenKey = "lastSeenReleaseNotesVersion"

    /// The release to present now, if any, recording the current version as seen either way.
    static func releaseToShow(defaults: UserDefaults = .standard, notes: ReleaseNotes = .bundled, version: String = ReleaseNotes.appVersion) -> ReleaseNotes.Release? {
        let lastSeen = defaults.string(forKey: lastSeenKey)
        defaults.set(version, forKey: lastSeenKey)
        guard let lastSeen, lastSeen != version else { return nil }
        return notes.release(version)
    }
}
