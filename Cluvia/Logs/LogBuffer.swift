import KubeKit

/// Bounded log storage. Oldest lines are dropped in chunks (10% of capacity) so trimming stays cheap and
/// the view only has to rebuild occasionally rather than on every new line.
struct LogBuffer {
    static let defaultCapacity = 100_000

    let capacity: Int
    private(set) var lines: [LogLine] = []
    /// Lines dropped from the front since the buffer was created; `dropped + index` is a stable line number.
    private(set) var dropped = 0

    init(capacity: Int = LogBuffer.defaultCapacity) {
        self.capacity = max(capacity, 10)
    }

    var endIndex: Int { dropped + lines.count }

    mutating func append(_ newLines: [LogLine]) {
        lines.append(contentsOf: newLines)
        guard lines.count > capacity else { return }
        let excess = lines.count - capacity + capacity / 10
        lines.removeFirst(excess)
        dropped += excess
    }

    mutating func removeAll() {
        dropped += lines.count
        lines.removeAll()
    }

    /// Lines with stable numbers in `start..<endIndex`, or nil if some of them were already dropped.
    func lines(from start: Int) -> ArraySlice<LogLine>? {
        guard start >= dropped else { return nil }
        return lines[(start - dropped)...]
    }
}
