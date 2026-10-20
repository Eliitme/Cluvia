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
    /// Context-menu actions for a row.
    var actions: [ResourceAction] = []
    var onAction: (ResourceAction, ResourceTableRow) -> Void = { _, _ in }
    /// Client-computed columns appended after the server's (e.g. live CPU and memory).
    var extras = TableExtras.none

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
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.actions = actions
        context.coordinator.onAction = onAction
        context.coordinator.update(columns: columns, rows: rows, showNamespace: showNamespace, extras: extras, selected: selection)
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

/// Extra table columns computed by the app rather than printed by the server.
struct TableExtras: Sendable {
    struct Column: Equatable, Sendable {
        let id: String
        let title: String
    }

    let columns: [Column]
    /// Changes whenever values change, so the table reloads even though the rows did not.
    let version: Int
    let value: @Sendable (String, ResourceTableRow) -> (text: String, number: Double?)?

    static let none = TableExtras(columns: [], version: 0) { _, _ in nil }

    static func identifier(_ id: String) -> NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier("x:\(id)") }

    static func extraID(_ identifier: NSUserInterfaceItemIdentifier) -> String? {
        identifier.rawValue.hasPrefix("x:") ? String(identifier.rawValue.dropFirst(2)) : nil
    }
}
