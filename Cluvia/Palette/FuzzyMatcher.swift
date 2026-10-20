import Foundation

/// Subsequence matching for the command palette: every query character must appear in order. Matches at
/// word starts and consecutive runs score higher, so "dpl" ranks "Deployments" above "Endpoint slices".
enum FuzzyMatcher {
    static func score(_ query: String, in candidate: String) -> Int? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        let haystack = Array(candidate.lowercased())
        var score = 0, index = 0, previous = -2
        for (position, character) in haystack.enumerated() where index < needle.count && character == needle[index] {
            score += 1
            if position == previous + 1 { score += 4 }
            if position == 0 || " -_./:".contains(haystack[position - 1]) { score += 6 }
            previous = position
            index += 1
        }
        guard index == needle.count else { return nil }
        // Prefer shorter candidates among equally good matches.
        return score * 100 - haystack.count
    }
}
