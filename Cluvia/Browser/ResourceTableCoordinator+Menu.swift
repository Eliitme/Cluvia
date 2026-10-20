import AppKit
import KubeKit

/// Right-click menu with the actions available for the clicked row.
extension ResourceTableCoordinator: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let tableView, tableView.clickedRow >= 0, tableView.clickedRow < sorted.count else { return }
        let row = sorted[tableView.clickedRow]
        for action in actions {
            if action == .delete { menu.addItem(.separator()) }
            let item = NSMenuItem(title: action.title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            item.representedObject = MenuPayload(action: action, row: row)
            menu.addItem(item)
        }
    }

    final class MenuPayload {
        let action: ResourceAction
        let row: ResourceTableRow

        init(action: ResourceAction, row: ResourceTableRow) {
            self.action = action
            self.row = row
        }
    }

    @objc func performMenuAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? MenuPayload else { return }
        selection.wrappedValue = payload.row.id
        onAction(payload.action, payload.row)
    }
}
