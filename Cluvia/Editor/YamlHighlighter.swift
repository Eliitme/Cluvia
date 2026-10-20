import AppKit

/// Lightweight YAML coloring by regular expressions: keys, comments, quoted strings, scalars.
/// Not a parser; it only needs to be right for the manifests Kubernetes produces.
enum YamlHighlighter {
    private static let rules: [(NSRegularExpression, NSColor)] = [
        (try! NSRegularExpression(pattern: #"^[ \t]*(?:- )?([^\s#:'"][^:#\n]*?):(?=\s|$)"#, options: .anchorsMatchLines), .systemBlue),
        (try! NSRegularExpression(pattern: #"(?<=: |- )(?:true|false|null|~|-?\d+(?:\.\d+)?)[ \t]*$"#, options: .anchorsMatchLines), .systemPurple),
        (try! NSRegularExpression(pattern: #"'[^'\n]*'|"(?:[^"\\\n]|\\.)*""#), .systemRed),
        (try! NSRegularExpression(pattern: #"(?:^|[ \t])#.*$"#, options: .anchorsMatchLines), .secondaryLabelColor),
    ]

    /// Ranges to color; later rules win where they overlap (comments last).
    static func spans(in text: String) -> [(NSRange, NSColor)] {
        let full = NSRange(location: 0, length: (text as NSString).length)
        return rules.flatMap { regex, color in
            regex.matches(in: text, range: full).map { match in
                (match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range, color)
            }
        }
    }
}
