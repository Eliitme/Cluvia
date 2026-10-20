import Foundation

/// An interactive process in a container (`pods/exec` over WebSocket), e.g. a shell with a TTY.
/// Runs in-process on the cluster transport, so it authenticates exactly like every other request.
public actor ExecSession {
    public struct Exit: Sendable, Equatable {
        /// nil when the connection ended without an exit status (dropped, refused, closed locally).
        public let code: Int?
        public let message: String?

        public init(code: Int?, message: String?) {
            self.code = code
            self.message = message
        }
    }

    /// Prefers bash, falls back to sh, without assuming either exists.
    public static let defaultShell = ["sh", "-c", "command -v bash >/dev/null && exec bash || exec sh"]

    private let transport: KubeTransport
    private let path: String
    private let query: [URLQueryItem]
    private var socket: URLSessionWebSocketTask?
    private var supportsStdinClose: Bool?

    public init(transport: KubeTransport, namespace: String, pod: String, container: String?, command: [String], tty: Bool = true) {
        self.transport = transport
        path = GroupVersionResource.pods.path(namespace: namespace, name: pod, subresource: "exec")
        var query = command.map { URLQueryItem(name: "command", value: $0) }
        query += [URLQueryItem(name: "stdin", value: "true"), URLQueryItem(name: "stdout", value: "true")]
        // With a TTY the remote side merges stderr into stdout; requesting both is rejected.
        query.append(tty ? URLQueryItem(name: "tty", value: "true") : URLQueryItem(name: "stderr", value: "true"))
        if let container { query.append(URLQueryItem(name: "container", value: container)) }
        self.query = query
    }

    public func start() async throws {
        socket = try await transport.webSocket(path: path, query: query, protocols: ["v5.channel.k8s.io", "v4.channel.k8s.io"])
    }

    /// Delivers output until the process ends. Each chunk is awaited before the next frame is read, so a slow
    /// consumer (a terminal drawing on the main thread) applies backpressure instead of buffering without bound.
    public func output(_ handle: @Sendable (Data) async -> Void) async -> Exit {
        guard let socket else { return Exit(code: nil, message: "Not started") }
        do {
            while true {
                let message = try await socket.receive()
                if supportsStdinClose == nil {
                    supportsStdinClose = (socket.response as? HTTPURLResponse)?
                        .value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == "v5.channel.k8s.io"
                }
                guard case let .data(frame) = message, let (channel, payload) = ChannelFrameCodec.decode(frame) else { continue }
                switch channel {
                case ChannelFrameCodec.stdout, ChannelFrameCodec.stderr:
                    await handle(payload)
                case ChannelFrameCodec.status:
                    let (code, message) = ChannelFrameCodec.exitCode(fromStatus: payload)
                    return Exit(code: code, message: message)
                default:
                    break
                }
            }
        } catch {
            return Exit(code: nil, message: Self.describe(error, response: socket.response))
        }
    }

    public func send(_ input: Data) async {
        try? await socket?.send(.data(ChannelFrameCodec.encode(channel: ChannelFrameCodec.stdin, input)))
    }

    public func resize(columns: Int, rows: Int) async {
        guard columns > 0, rows > 0 else { return }
        try? await socket?.send(.data(ChannelFrameCodec.resizeFrame(columns: columns, rows: rows)))
    }

    /// Ends the session: signals stdin EOF where the protocol allows it, then closes the socket, which also
    /// ends `output`.
    public func close() async {
        if supportsStdinClose == true { try? await socket?.send(.data(ChannelFrameCodec.closeStdinFrame)) }
        socket?.cancel(with: .normalClosure, reason: nil)
    }

    /// URLSession reports a refused upgrade as a generic "bad response"; the HTTP status is what users need.
    static func describe(_ error: Error, response: URLResponse?) -> String {
        guard let http = response as? HTTPURLResponse, http.statusCode >= 400 else { return error.localizedDescription }
        let hint = switch http.statusCode {
        case 401: " (credentials rejected)"
        case 403: " (not allowed to exec into this pod)"
        case 404: " (pod not found)"
        case 400: " (container not running or not found)"
        default: ""
        }
        return "The API server refused the connection: HTTP \(http.statusCode)\(hint)"
    }
}
