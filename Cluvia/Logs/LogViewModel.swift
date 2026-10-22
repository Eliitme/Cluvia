import AppKit
import KubeKit
import Observation
import os

/// One log tab: streams a container's logs into a bounded buffer, batching UI updates.
@MainActor @Observable
final class LogViewModel: Identifiable {
    enum Status: Equatable {
        case streaming
        case reconnecting(String)
        case ended(String)
        case failed(String)
    }

    struct Source: Hashable {
        let pod: String
        let namespace: String
        /// Pods with sidecars need an explicit container; multi-pod views use each pod's default.
        var container: String?
    }

    let id = UUID()
    let pod: String
    let namespace: String
    /// Several pods (a workload's) stream into one view, each line prefixed with its pod name.
    let sources: [Source]
    @ObservationIgnored private let groupTitle: String?
    let containers: [ContainerChoice]
    var container: String { didSet { restart() } }
    var previous = false { didSet { restart() } }
    var follow = true { didSet { restart() } }
    /// Lines fetched before following; nil means the whole log.
    var tailLines: Int? = 1000 { didSet { if !adjustingWindow { restart() } } }
    /// Only lines from the last this many seconds. A window lifts the line limit (it would otherwise cut a busy
    /// pod's window to its last few minutes); going back to any time restores the limit chosen before.
    var sinceSeconds: Int? {
        didSet {
            adjustingWindow = true
            if oldValue == nil, sinceSeconds != nil { tailBeforeWindow = tailLines; tailLines = nil }
            if sinceSeconds == nil, oldValue != nil { tailLines = tailBeforeWindow }
            adjustingWindow = false
            restart()
        }
    }
    var display = LogDisplayOptions()
    var wrapLines = true
    var search = ""
    private(set) var buffer = LogBuffer()
    /// Set by the error buttons; the text view moves the selection to the next or previous error line.
    private(set) var jumpRequest: (id: Int, forward: Bool)?
    private(set) var status = Status.streaming
    /// Changes whenever the buffer is replaced rather than appended to, so the view must redraw everything.
    private(set) var resetToken = 0

    @ObservationIgnored private let client: DynamicClient
    @ObservationIgnored private var streamTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// Identifies the current stream; results from a stream replaced by `restart()` are ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var adjustingWindow = false
    @ObservationIgnored private var tailBeforeWindow: Int? = 1000
    /// Lines are received (and classified) off the main actor and handed over in batches.
    @ObservationIgnored private let inbox = OSAllocatedUnfairLock<[LogEntry]>(initialState: [])

    var isMultiPod: Bool { sources.count > 1 }
    /// Pod names by source index for the `pod │ ` prefix; nil for a single pod.
    var podNames: [String]? { isMultiPod ? sources.map(\.pod) : nil }

    func jump(forward: Bool) {
        jumpRequest = ((jumpRequest?.id ?? 0) + 1, forward)
    }

    var title: String {
        if let groupTitle { return groupTitle }
        return containers.count > 1 ? "\(pod)/\(container)" : pod
    }

    init(client: DynamicClient, pod: Unstructured, container: String? = nil) {
        self.client = client
        self.pod = pod.name
        namespace = pod.namespace ?? "default"
        sources = [Source(pod: pod.name, namespace: namespace)]
        groupTitle = nil
        containers = Self.containers(of: pod)
        self.container = container ?? containers.first?.name ?? ""
        restart()
    }

    /// Logs of several pods (each pod's default container) merged into one view.
    init(client: DynamicClient, title: String, pods: [Unstructured]) {
        self.client = client
        pod = title
        namespace = pods.first?.namespace ?? "default"
        sources = pods.map { Source(pod: $0.name, namespace: $0.namespace ?? "default", container: $0.defaultContainerName) }
        groupTitle = title
        containers = []
        container = ""
        restart()
    }

    func stop() {
        streamTasks.forEach { $0.cancel() }
        flushTask?.cancel()
        streamTasks = []
        flushTask = nil
    }

    func clear() {
        inbox.withLock { $0.removeAll() }
        buffer.removeAll()
        resetToken += 1
    }

    func restart() {
        stop()
        generation += 1
        let current = generation
        inbox.withLock { $0.removeAll() }
        buffer = LogBuffer()
        resetToken += 1
        status = .streaming
        let remaining = OSAllocatedUnfairLock(initialState: sources.count)
        streamTasks = sources.enumerated().map { index, source in
            let options = LogOptions(container: isMultiPod ? source.container : container, previous: previous, tailLines: tailLines,
                                     follow: follow, sinceSeconds: sinceSeconds)
            let stream = LogStreamer(client: client).stream(pod: source.pod, namespace: source.namespace, options: options)
            // Several pods: events of one pod are shown inline as lines rather than as the view's state.
            let inline = isMultiPod
            let inbox = inbox
            let note: @Sendable (String) -> Void = { text in
                inbox.withLock { $0.append(LogEntry(LogLine(timestamp: nil, text: "[\(text)]"), source: index)) }
            }
            return Task.detached { [weak self] in
                var failure: Error?
                do {
                    for try await event in stream {
                        switch event {
                        case let .line(line):
                            let entry = LogEntry(line, source: index)
                            inbox.withLock { $0.append(entry) }
                        case let .reconnecting(reason):
                            if inline { note(reason) } else { await self?.update(.reconnecting(reason), generation: current) }
                        case let .ended(reason):
                            if inline { note(reason) } else { await self?.update(.ended(reason), generation: current) }
                        }
                    }
                } catch {
                    failure = error
                    // With several pods, one failing pod is reported inline and the others keep streaming.
                    if inline { note(error.localizedDescription) }
                }
                // A cancelled stream also ends normally; only a real end reports "finished".
                let last = remaining.withLock { count in
                    count -= 1
                    return count == 0
                }
                if !Task.isCancelled, last || !inline {
                    await self?.finish(error: inline ? nil : failure, generation: current)
                }
            }
        }
        flushTask = Task { [weak self] in
            // Repaint at most ten times a second however fast lines arrive.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                self?.flush()
            }
        }
    }

    private func update(_ newStatus: Status, generation stream: Int) {
        guard stream == generation else { return }
        flush()
        status = newStatus
    }

    private func finish(error: Error?, generation stream: Int) {
        guard stream == generation else { return }
        flush()
        if let error {
            status = .failed(error.localizedDescription)
        } else if status == .streaming {
            status = .ended("Stream finished")
        }
    }

    private func flush() {
        let lines = inbox.withLock { pending in
            defer { pending.removeAll(keepingCapacity: true) }
            return pending
        }
        guard !lines.isEmpty else { return }
        let dropsBefore = buffer.dropped
        buffer.append(lines)
        if buffer.dropped != dropsBefore { resetToken += 1 }
        if case .reconnecting = status { status = .streaming }
    }
}
