import AppKit
import KubeKit
import SwiftUI

/// Data source/delegate for `ResourceTableView`: column building, sorting, selection sync and ticking ages.
@MainActor
final class ResourceTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let namespaceColumn = NSUserInterfaceItemIdentifier("namespace")
    static let cellIdentifier = NSUserInterfaceItemIdentifier("cell")

    weak var tableView: NSTableView?
    var selection: Binding<ObjectKey?>
    var actions: [ResourceAction] = []
    var onAction: (ResourceAction, ResourceTableRow) -> Void = { _, _ in }
    private var columns: [ResourceTableColumn] = []
    private var extras = TableExtras.none
    private var showNamespace = false
    private var rows: [ResourceTableRow] = []
    private(set) var sorted: [ResourceTableRow] = []
    private var applyingSelection = false
    var ageTimer: Timer?

    init(selection: Binding<ObjectKey?>) {
        self.selection = selection
    }

    func update(columns: [ResourceTableColumn], rows: [ResourceTableRow], showNamespace: Bool, extras: TableExtras, selected: ObjectKey?) {
        guard let tableView else { return }
        // NSTableView trims an out-of-range selection during reload and reports it as a user change;
        // suppress that so the bound selection survives filtering and shrinking lists.
        applyingSelection = true
        let extrasChanged = extras.columns != self.extras.columns
        if columns != self.columns || showNamespace != self.showNamespace || extrasChanged {
            self.columns = columns
            self.showNamespace = showNamespace
            self.extras = extras
            rebuildColumns(in: tableView)
        }
        if rows != self.rows || extras.version != self.extras.version {
            self.rows = rows
            self.extras = extras
            resort()
            tableView.reloadData()
        }
        applyingSelection = false
        select(selected, in: tableView)
        startTimer()
    }

    // MARK: Columns

    private func rebuildColumns(in tableView: NSTableView) {
        tableView.tableColumns.forEach(tableView.removeTableColumn)
        for (index, column) in columns.enumerated() where column.priority == 0 {
            add(identifier: NSUserInterfaceItemIdentifier("c\(index)"), title: column.name, width: index == 0 ? 280 : 110, to: tableView)
            if index == 0, showNamespace {
                add(identifier: Self.namespaceColumn, title: "Namespace", width: 160, to: tableView)
            }
        }
        for extra in extras.columns {
            add(identifier: TableExtras.identifier(extra.id), title: extra.title, width: 90, to: tableView)
        }
        tableView.sortDescriptors = []
    }

    private func add(identifier: NSUserInterfaceItemIdentifier, title: String, width: CGFloat, to tableView: NSTableView) {
        let column = NSTableColumn(identifier: identifier)
        column.title = title
        column.width = width
        column.minWidth = identifier.rawValue == "c0" ? 120 : 40
        column.sortDescriptorPrototype = NSSortDescriptor(key: identifier.rawValue, ascending: true)
        tableView.addTableColumn(column)
    }

    func cellIndex(_ identifier: NSUserInterfaceItemIdentifier) -> Int? {
        identifier.rawValue.hasPrefix("c") ? Int(identifier.rawValue.dropFirst()) : nil
    }

    func isAge(_ index: Int) -> Bool {
        index < columns.count && columns[index].name == "Age"
    }

    // MARK: Values and sorting

    func text(for row: ResourceTableRow, column identifier: NSUserInterfaceItemIdentifier) -> String {
        if identifier == Self.namespaceColumn { return row.object.namespace ?? "" }
        if let extra = TableExtras.extraID(identifier) { return extras.value(extra, row)?.text ?? "" }
        guard let index = cellIndex(identifier) else { return "" }
        // The server's Age text is frozen at list time; compute it from creationTimestamp instead.
        if isAge(index) { return AgeFormatter.string(since: row.object.creationTimestamp) }
        return index < row.cells.count ? row.cells[index].displayText : ""
    }

    private func resort() {
        guard let descriptor = tableView?.sortDescriptors.first, let key = descriptor.key else {
            sorted = rows
            return
        }
        let identifier = NSUserInterfaceItemIdentifier(key)
        let ascending = descriptor.ascending
        if let extra = TableExtras.extraID(identifier) {
            // Numeric columns (CPU, memory): rows without a value sort last either way.
            let keyed = rows.map { (extras.value(extra, $0)?.number, $0) }
            sorted = keyed.sorted { lhs, rhs in
                switch (lhs.0, rhs.0) {
                case let (l?, r?): l == r ? lhs.1.id < rhs.1.id : (l < r) == ascending
                case (nil, nil): lhs.1.id < rhs.1.id
                case (nil, _): false
                case (_, nil): true
                }
            }.map(\.1)
            return
        }
        if let index = cellIndex(identifier), isAge(index) {
            // Ascending = youngest first, matching the displayed age growing downwards.
            let keyed = rows.map { ($0.object.creationTimestamp ?? .distantPast, $0) }
            sorted = keyed.sorted { lhs, rhs in
                lhs.0 == rhs.0 ? lhs.1.id < rhs.1.id : (lhs.0 > rhs.0) == ascending
            }.map(\.1)
            return
        }
        // Sort keys are computed once per row, not per comparison: thousands of rows resort on every update.
        let keyed = rows.map { (text(for: $0, column: identifier), $0) }
        sorted = keyed.sorted { lhs, rhs in
            let result = lhs.0.localizedStandardCompare(rhs.0)
            if result == .orderedSame { return lhs.1.id < rhs.1.id }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }.map(\.1)
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        applyingSelection = true
        resort()
        tableView.reloadData()
        applyingSelection = false
        select(selection.wrappedValue, in: tableView)
    }

    // MARK: Data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { sorted.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < sorted.count else { return nil }
        let cell = (tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? NSTableCellView) ?? Self.makeCell()
        let value = text(for: sorted[row], column: tableColumn.identifier)
        switch TableCellPresentation.present(value, column: tableColumn.title, font: cell.textField?.font ?? .systemFont(ofSize: NSFont.systemFontSize)) {
        case let .plain(text, color, tooltip):
            cell.textField?.stringValue = text
            cell.textField?.textColor = color
            cell.textField?.toolTip = tooltip
        case let .symbol(text, tooltip):
            cell.textField?.attributedStringValue = text
            cell.textField?.toolTip = tooltip
        }
        return cell
    }

    private static func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = cellIdentifier
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applyingSelection, let tableView else { return }
        let row = tableView.selectedRow
        selection.wrappedValue = row >= 0 && row < sorted.count ? sorted[row].id : nil
    }

    private func select(_ key: ObjectKey?, in tableView: NSTableView) {
        let index = key.flatMap { key in sorted.firstIndex { $0.id == key } }
        guard index != (tableView.selectedRow >= 0 ? tableView.selectedRow : nil) else { return }
        applyingSelection = true
        defer { applyingSelection = false }
        if let index {
            tableView.selectRowIndexes([index], byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
        } else {
            tableView.deselectAll(nil)
        }
    }
}
