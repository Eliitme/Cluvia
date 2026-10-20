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
    private var columns: [ResourceTableColumn] = []
    private var showNamespace = false
    private var rows: [ResourceTableRow] = []
    private var sorted: [ResourceTableRow] = []
    private var applyingSelection = false
    private var ageTimer: Timer?

    init(selection: Binding<ObjectKey?>) {
        self.selection = selection
    }

    func update(columns: [ResourceTableColumn], rows: [ResourceTableRow], showNamespace: Bool, selected: ObjectKey?) {
        guard let tableView else { return }
        // NSTableView trims an out-of-range selection during reload and reports it as a user change;
        // suppress that so the bound selection survives filtering and shrinking lists.
        applyingSelection = true
        if columns != self.columns || showNamespace != self.showNamespace {
            self.columns = columns
            self.showNamespace = showNamespace
            rebuildColumns(in: tableView)
        }
        if rows != self.rows {
            self.rows = rows
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

    private func cellIndex(_ identifier: NSUserInterfaceItemIdentifier) -> Int? {
        identifier.rawValue.hasPrefix("c") ? Int(identifier.rawValue.dropFirst()) : nil
    }

    private func isAge(_ index: Int) -> Bool {
        index < columns.count && columns[index].name == "Age"
    }

    // MARK: Values and sorting

    func text(for row: ResourceTableRow, column identifier: NSUserInterfaceItemIdentifier) -> String {
        if identifier == Self.namespaceColumn { return row.object.namespace ?? "" }
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
        cell.textField?.stringValue = value
        cell.textField?.textColor = StatusTone.of(value, column: tableColumn.title).color
        cell.textField?.toolTip = value.count > 40 ? value : nil
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

    // MARK: Ticking ages

    private func startTimer() {
        guard ageTimer == nil else { return }
        ageTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAges() }
        }
    }

    func stopTimer() {
        ageTimer?.invalidate()
        ageTimer = nil
    }

    private func refreshAges() {
        guard let tableView else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        let ageColumns = tableView.tableColumns.enumerated().compactMap { offset, column in
            cellIndex(column.identifier).flatMap { isAge($0) ? offset : nil }
        }
        guard visible.length > 0, !ageColumns.isEmpty else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)), columnIndexes: IndexSet(ageColumns))
    }
}
