import KubeKit

/// Where the user has been in one cluster window, for Back and Forward. Moving the selection within a table
/// updates the current entry instead of adding one, so arrowing through rows does not flood the history.
struct NavigationHistory {
    enum Location: Hashable {
        case kind(ResourceKind, ObjectKey?)
        case helm
    }

    static let capacity = 50

    private(set) var entries: [Location] = []
    private(set) var index = -1

    var current: Location? { entries.indices.contains(index) ? entries[index] : nil }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < entries.count - 1 }

    /// Adds a location after the current one, dropping anything ahead of it (as a browser does).
    mutating func visit(_ location: Location) {
        guard current != location else { return }
        entries.removeSubrange((index + 1)...)
        entries.append(location)
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        index = entries.count - 1
    }

    /// Records the object selected at the current location.
    mutating func updateCurrent(key: ObjectKey?) {
        guard case let .kind(kind, _)? = current else { return }
        entries[index] = .kind(kind, key)
    }

    mutating func back() -> Location? {
        guard canGoBack else { return nil }
        index -= 1
        return entries[index]
    }

    mutating func forward() -> Location? {
        guard canGoForward else { return nil }
        index += 1
        return entries[index]
    }
}
