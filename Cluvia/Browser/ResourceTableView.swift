import AppKit
import KubeKit
import SwiftUI

/// Server-printed resource table backed by `NSTableView`: columns are only known at runtime and collections
/// can hold thousands of rows that update several times a second.
struct ResourceTableView: NSViewRepresentable {
    let columns: [ResourceTableColumn]
    let rows: [ResourceTableRow]
    let showNamespace: Bool
    @Binding var selection: ObjectKey?

    func makeCoordinator() -> ResourceTableCoordinator {
        ResourceTableCoordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.allowsColumnReordering = true
        // Fixed widths: the inspector opening must not squeeze Name to an ellipsis; scroll horizontally instead.
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.rowSizeStyle = .default
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.tableView = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.update(columns: columns, rows: rows, showNamespace: showNamespace, selected: selection)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: ResourceTableCoordinator) {
        coordinator.stopTimer()
    }
}

/// Status words that get a color in status-like columns.
enum StatusTone {
    case good, pending, bad, neutral

    static func of(_ text: String, column: String) -> StatusTone {
        guard ["status", "phase", "ready", "state"].contains(column.lowercased()) else { return .neutral }
        let value = text.lowercased()
        let bad = ["error", "crashloop", "failed", "backoff", "notready", "evicted", "oomkilled", "unknown", "lost"]
        if bad.contains(where: value.contains) { return .bad }
        if ["pending", "containercreating", "terminating", "podinitializing", "init:"].contains(where: value.hasPrefix) { return .pending }
        if ["running", "succeeded", "completed", "active", "bound", "ready", "available", "true"].contains(value) { return .good }
        return .neutral
    }

    var color: NSColor {
        switch self {
        case .good: .systemGreen
        case .pending: .systemOrange
        case .bad: .systemRed
        case .neutral: .labelColor
        }
    }
}
