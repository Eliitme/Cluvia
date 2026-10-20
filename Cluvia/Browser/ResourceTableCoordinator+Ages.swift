import AppKit

/// Ages are computed from creationTimestamp; visible age cells are redrawn every few seconds.
extension ResourceTableCoordinator {
    func startTimer() {
        guard ageTimer == nil else { return }
        ageTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAges() }
        }
    }

    func stopTimer() {
        ageTimer?.invalidate()
        ageTimer = nil
    }

    func refreshAges() {
        guard let tableView else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        let ageColumns = tableView.tableColumns.enumerated().compactMap { offset, column in
            cellIndex(column.identifier).flatMap { isAge($0) ? offset : nil }
        }
        guard visible.length > 0, !ageColumns.isEmpty else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)), columnIndexes: IndexSet(ageColumns))
    }
}
