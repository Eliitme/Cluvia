import KubeKit

/// One received line: the kubelet's text as sent, which pod it came from, and its severity.
struct LogEntry: Sendable, Hashable {
    let line: LogLine
    /// Index into the view's sources; the pod name prefix is added when rendering.
    let source: Int
    let level: LogLevel

    init(_ line: LogLine, source: Int = 0) {
        self.line = line
        self.source = source
        level = LogLevel.classify(line.text)
    }
}

/// Bounded log storage. Oldest lines are dropped in chunks (10% of capacity) so trimming stays cheap and
/// the view only has to rebuild occasionally rather than on every new line.
struct LogBuffer {
    static let defaultCapacity = 100_000

    let capacity: Int
    private(set) var entries: [LogEntry] = []
    /// Lines dropped from the front since the buffer was created; `dropped + index` is a stable line number.
    private(set) var dropped = 0

    init(capacity: Int = LogBuffer.defaultCapacity) {
        self.capacity = max(capacity, 10)
    }

    var endIndex: Int { dropped + entries.count }

    mutating func append(_ newEntries: [LogEntry]) {
        entries.append(contentsOf: newEntries)
        guard entries.count > capacity else { return }
        let excess = entries.count - capacity + capacity / 10
        entries.removeFirst(excess)
        dropped += excess
    }

    mutating func removeAll() {
        dropped += entries.count
        entries.removeAll()
    }

    /// Entries with stable numbers in `start..<endIndex`, or nil if some of them were already dropped.
    func entries(from start: Int) -> ArraySlice<LogEntry>? {
        guard start >= dropped else { return nil }
        return entries[(start - dropped)...]
    }
}
