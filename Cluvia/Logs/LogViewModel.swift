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

    struct ContainerChoice: Hashable {
        let name: String
        let role: String?
    }

    let id = UUID()
    let pod: String
    let namespace: String
    let containers: [ContainerChoice]
    var container: String { didSet { restart() } }
    var previous = false { didSet { restart() } }
    var follow = true { didSet { restart() } }
    /// Lines fetched before following; nil means the whole log.
    var tailLines: Int? = 1000 { didSet { restart() } }
    var showTimestamps = false
    var wrapLines = true
    var search = ""
    private(set) var buffer = LogBuffer()
    private(set) var status = Status.streaming
    /// Changes whenever the buffer is replaced rather than appended to, so the view must redraw everything.
    private(set) var resetToken = 0

    @ObservationIgnored private let client: DynamicClient
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// Identifies the current stream; results from a stream replaced by `restart()` are ignored.
    @ObservationIgnored private var generation = 0
    /// Lines are received off the main actor and handed over in batches.
    @ObservationIgnored private let inbox = OSAllocatedUnfairLock<[LogLine]>(initialState: [])

    var title: String { containers.count > 1 ? "\(pod)/\(container)" : pod }

    /// Containers of a pod, including init and ephemeral ones.
    static func containers(of pod: Unstructured) -> [ContainerChoice] {
        let spec = pod.json["spec"]
        func names(_ key: String, role: String?) -> [ContainerChoice] {
            (spec?[key]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }.map { ContainerChoice(name: $0, role: role) }
        }
        return names("containers", role: nil) + names("initContainers", role: "init") + names("ephemeralContainers", role: "ephemeral")
    }

    init(client: DynamicClient, pod: Unstructured, container: String? = nil) {
        self.client = client
        self.pod = pod.name
        namespace = pod.namespace ?? "default"
        containers = Self.containers(of: pod)
        self.container = container ?? containers.first?.name ?? ""
        restart()
    }

    func stop() {
        streamTask?.cancel()
        flushTask?.cancel()
        streamTask = nil
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
        let options = LogOptions(container: container, previous: previous, tailLines: tailLines, follow: follow)
        let stream = LogStreamer(client: client).stream(pod: pod, namespace: namespace, options: options)
        let inbox = inbox
        streamTask = Task.detached { [weak self] in
            do {
                for try await event in stream {
                    switch event {
                    case let .line(line): inbox.withLock { $0.append(line) }
                    case let .reconnecting(reason): await self?.update(.reconnecting(reason), generation: current)
                    case let .ended(reason): await self?.update(.ended(reason), generation: current)
                    }
                }
                // A cancelled stream also ends normally; only a real end reports "finished".
                if !Task.isCancelled { await self?.finish(error: nil, generation: current) }
            } catch {
                if !Task.isCancelled { await self?.finish(error: error, generation: current) }
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

    func format(_ line: LogLine) -> String {
        showTimestamps ? "\(line.timestamp ?? "") \(line.text)" : line.text
    }

    func text(from start: Int) -> String? {
        buffer.lines(from: start).map { $0.map(format).joined(separator: "\n") }
    }

    func saveToFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(pod)-\(container).log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = buffer.lines.map(format).joined(separator: "\n")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
