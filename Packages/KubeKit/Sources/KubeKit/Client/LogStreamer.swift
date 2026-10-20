import Foundation

public struct LogOptions: Sendable, Hashable {
    public var container: String?
    public var previous = false
    public var tailLines: Int? = 1000
    public var follow = true

    public init(container: String? = nil, previous: Bool = false, tailLines: Int? = 1000, follow: Bool = true) {
        self.container = container
        self.previous = previous
        self.tailLines = tailLines
        self.follow = follow
    }
}

public struct LogLine: Sendable, Hashable {
    /// RFC 3339 timestamp the kubelet prefixed the line with.
    public let timestamp: String?
    public let text: String

    public init(timestamp: String?, text: String) {
        self.timestamp = timestamp
        self.text = text
    }

    /// Splits `2026-10-20T06:00:00.123456789Z message` as returned with `timestamps=true`.
    static func parse(_ raw: String) -> LogLine {
        guard let space = raw.firstIndex(of: " "), raw[..<space].count >= 20, raw[raw.startIndex].isNumber else {
            return LogLine(timestamp: nil, text: raw)
        }
        return LogLine(timestamp: String(raw[..<space]), text: String(raw[raw.index(after: space)...]))
    }
}

public enum LogEvent: Sendable {
    case line(LogLine)
    /// The stream ended while following (container restarted, server timeout); reconnecting from the last line.
    case reconnecting(String)
    /// Following stopped for good, e.g. the pod was deleted.
    case ended(String)
}

/// Streams a container's logs. While following, a closed stream is resumed with `sinceTime` from the last
/// line's timestamp and already-seen lines are skipped, so a container restart continues in the same view.
public struct LogStreamer: Sendable {
    static let retryDelay: Duration = .seconds(2)

    public let client: DynamicClient

    public init(client: DynamicClient) {
        self.client = client
    }

    public func stream(pod: String, namespace: String, options: LogOptions) -> AsyncThrowingStream<LogEvent, Error> {
        let client = client
        return AsyncThrowingStream { continuation in
            let task = Task {
                var lastTimestamp: String?
                var resume = ResumeFilter()
                while !Task.isCancelled {
                    do {
                        let request = KubeRequest(
                            path: GroupVersionResource.pods.path(namespace: namespace, name: pod, subresource: "log"),
                            query: Self.query(options, sinceTime: lastTimestamp), accept: "*/*"
                        )
                        let (bytes, _) = try await client.transport.bytes(request)
                        for try await raw in bytes.lines {
                            let line = LogLine.parse(raw)
                            guard resume.accept(line) else { continue }
                            if line.timestamp != nil { lastTimestamp = line.timestamp }
                            continuation.yield(.line(line))
                        }
                        resume.begin()
                        guard options.follow, !options.previous else { return continuation.finish() }
                        continuation.yield(.reconnecting("Log stream closed; waiting for the container"))
                    } catch let error as KubeAPIError where options.follow && !options.previous && error.statusCode == 400 {
                        // Container not started yet (ContainerCreating, waiting to restart).
                        continuation.yield(.reconnecting(error.message))
                    } catch {
                        return continuation.finish(throwing: error)
                    }
                    try? await Task.sleep(for: Self.retryDelay)
                    do {
                        _ = try await client.get(.pods, name: pod, namespace: namespace)
                    } catch let error as KubeAPIError where error.statusCode == 404 {
                        continuation.yield(.ended("Pod \(pod) was deleted"))
                        return continuation.finish()
                    } catch {}
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Skips the lines a resumed stream repeats. `sinceTime` has second precision, so after a reconnect the
    /// server resends that whole second; only lines up to the last one already shown are dropped. Outside that
    /// window nothing is filtered, because stdout and stderr lines are not strictly ordered by timestamp.
    struct ResumeFilter {
        private var lastDate: Date?
        private var seenAtLastDate = Set<LogLine>()
        private var resuming = false

        mutating func begin() {
            resuming = lastDate != nil
        }

        mutating func accept(_ line: LogLine) -> Bool {
            guard let date = line.timestamp.flatMap(KubeTimestamp.parse) else { return !resuming }
            if resuming {
                if date < lastDate! || (date == lastDate! && seenAtLastDate.contains(line)) { return false }
                if date > lastDate! { resuming = false }
            }
            if date != lastDate {
                lastDate = date
                seenAtLastDate.removeAll(keepingCapacity: true)
            }
            seenAtLastDate.insert(line)
            return true
        }
    }

    static func query(_ options: LogOptions, sinceTime: String?) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "timestamps", value: "true")]
        if let container = options.container { items.append(URLQueryItem(name: "container", value: container)) }
        if options.follow, !options.previous { items.append(URLQueryItem(name: "follow", value: "true")) }
        if options.previous { items.append(URLQueryItem(name: "previous", value: "true")) }
        if let sinceTime {
            items.append(URLQueryItem(name: "sinceTime", value: sinceTime))
        } else if let tail = options.tailLines {
            items.append(URLQueryItem(name: "tailLines", value: String(tail)))
        }
        return items
    }
}
