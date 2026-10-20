import Foundation
import KubeKit

/// Free-text filter for resource tables.
///
/// Space-separated terms must all match. A term matches the name, namespace, any cell, or a label
/// (`app=web` or just `web`). `column:value` restricts a term to one column, e.g. `status:running`.
struct RowFilter {
    private let terms: [(column: String?, text: String)]

    init(_ query: String) {
        terms = query.lowercased().split(whereSeparator: \.isWhitespace).map { term in
            if let colon = term.firstIndex(of: ":"), colon != term.startIndex, term.index(after: colon) != term.endIndex {
                return (String(term[..<colon]), String(term[term.index(after: colon)...]))
            }
            return (nil, String(term))
        }
    }

    var isEmpty: Bool { terms.isEmpty }

    func matches(_ row: ResourceTableRow, columns: [ResourceTableColumn]) -> Bool {
        terms.allSatisfy { term in
            if let column = term.column {
                guard let index = columns.firstIndex(where: { $0.name.lowercased() == column }) else {
                    return column == "namespace" && (row.object.namespace ?? "").lowercased().contains(term.text)
                }
                return index < row.cells.count && row.cells[index].displayText.lowercased().contains(term.text)
            }
            return Self.haystack(row).contains { $0.contains(term.text) }
        }
    }

    private static func haystack(_ row: ResourceTableRow) -> [String] {
        var values = [row.object.name.lowercased(), (row.object.namespace ?? "").lowercased()]
        values += row.cells.map { $0.displayText.lowercased() }
        values += row.object.labels.map { "\($0.key)=\($0.value)".lowercased() }
        return values
    }
}
