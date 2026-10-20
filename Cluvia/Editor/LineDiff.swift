import Foundation

/// Line diff for showing what an edit or a dry run changes.
enum LineDiff {
    enum Kind { case same, added, removed }

    struct Line: Hashable {
        let kind: Kind
        let text: String
    }

    static func lines(from old: String, to new: String) -> [Line] {
        let before = old.components(separatedBy: "\n")
        let after = new.components(separatedBy: "\n")
        let difference = after.difference(from: before)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        var result: [Line] = []
        var i = 0, j = 0
        while i < before.count || j < after.count {
            if i < before.count, removed.contains(i) {
                result.append(Line(kind: .removed, text: before[i])); i += 1
            } else if j < after.count, inserted.contains(j) {
                result.append(Line(kind: .added, text: after[j])); j += 1
            } else {
                result.append(Line(kind: .same, text: j < after.count ? after[j] : before[i])); i += 1; j += 1
            }
        }
        return result
    }

    /// Changed lines with `context` unchanged lines around them; `nil` entries mark skipped stretches.
    static func hunks(_ lines: [Line], context: Int = 3) -> [Line?] {
        let changed = lines.indices.filter { lines[$0].kind != .same }
        guard !changed.isEmpty else { return [] }
        var keep = Set<Int>()
        for index in changed { keep.formUnion(max(0, index - context)...min(lines.count - 1, index + context)) }
        var result: [Line?] = []
        for index in lines.indices {
            if keep.contains(index) {
                result.append(lines[index])
            } else if result.last != .some(nil) {
                result.append(nil)
            }
        }
        return result
    }
}
