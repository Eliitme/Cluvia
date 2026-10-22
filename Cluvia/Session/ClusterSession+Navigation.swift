import AppKit
import KubeKit

/// Back/Forward through the window's history and jumps along owner references.
extension ClusterSession {
    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    func goBack() { step(back: true) }

    func goForward() { step(back: false) }

    /// A sheet (including ones a page keeps to itself, like Helm's) would be torn down by navigating under it.
    static var sheetIsOpen: Bool { NSApp.keyWindow?.sheetParent != nil || NSApp.keyWindow?.attachedSheet != nil }

    /// Go to Owner applies to a visible object in a resource table; whether it has an owner is checked when run.
    var canGoToOwner: Bool { selectionVisible && !showingHelm && selectedObject != nil }

    /// Jumps to another object, e.g. from an owner reference or the palette.
    func reveal(_ kind: ResourceKind, _ key: ObjectKey) {
        if kind == selectedKind, !showingHelm, key != selectedObject {
            // Same table: a new entry, so Back returns to the object selected before.
            history.visit(.kind(kind, key))
            isRestoringHistory = true
            selectedObject = key
            isRestoringHistory = false
        } else {
            selectedKind = kind
            selectedObject = key
        }
    }

    /// Owner of the selected row, read from the table's own copy of the object (no request): the controller if
    /// there is one, else the first owner.
    var selectedRowOwner: OwnerReference? {
        guard !showingHelm, let gvr = selectedKind?.gvr, let key = selectedObject, let registry else { return nil }
        let row = registry.activeStores.lazy.filter { $0.gvr == gvr }.compactMap { $0.store.items.first { $0.id == key } }.first
        let owners = row?.object.ownerReferences ?? []
        return owners.first(where: \.controller) ?? owners.first
    }

    /// The menu's ⌘↑ fires before the focused view sees the key, so text fields, the log view and terminals would
    /// lose "move to the beginning". Checked when the command runs; menu enablement is not recomputed on focus changes.
    func goToOwner() {
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextInputClient {
            // Hand the key back: text views map it to "move to the beginning", terminals to whatever they do.
            if let event = NSApp.currentEvent, event.type == .keyDown { responder.keyDown(with: event) }
            return
        }
        guard !Self.sheetIsOpen, canGoToOwner, let owner = selectedRowOwner,
              let kind = kind(named: owner.kind, apiVersion: owner.apiVersion) else { return }
        reveal(kind, ObjectKey(namespace: kind.namespaced ? selectedObject?.namespace : nil, name: owner.name))
    }

    private func step(back: Bool) {
        guard !Self.sheetIsOpen else { return }
        let before = history
        while let location = back ? history.back() : history.forward() {
            if restore(location) { return }
        }
        // Nothing left that can be shown (kinds gone after a reconnect): stay on the entry that is on screen.
        history = before
    }

    /// Shows a recorded location without recording it again; false when its kind is no longer served.
    private func restore(_ location: NavigationHistory.Location) -> Bool {
        isRestoringHistory = true
        defer { isRestoringHistory = false }
        switch location {
        case .helm:
            showingHelm = true
        case let .kind(kind, key):
            guard kinds.isEmpty || kinds.contains(kind) else { return false }
            selectedKind = kind
            selectedObject = key
        }
        return true
    }
}
