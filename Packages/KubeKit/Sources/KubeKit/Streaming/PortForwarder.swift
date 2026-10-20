import Foundation
import Network
import os

/// Forwards a local TCP port on 127.0.0.1 to a pod (or a ready pod behind a service) inside this process.
/// Each accepted connection gets its own `pods/portforward` WebSocket, so concurrent connections are independent.
public actor PortForwarder {
    public enum Target: Sendable, Hashable {
        case pod(String)
        case service(String)
    }

    public nonisolated let namespace: String
    public nonisolated let target: Target
    public nonisolated let remotePort: Int
    public private(set) var localPort: UInt16 = 0

    /// How long a service's resolved pod is reused before asking the API server again.
    static let targetCacheLifetime: Duration = .seconds(30)

    private let client: DynamicClient
    private let onError: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "app.cluvia.port-forward")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var cachedTarget: (pod: String, port: Int, at: ContinuousClock.Instant)?

    /// `onError` receives failures of individual forwarded connections (pod gone, nothing listening, refused).
    public init(client: DynamicClient, namespace: String, target: Target, remotePort: Int,
                onError: @escaping @Sendable (String) -> Void = { _ in }) {
        self.client = client
        self.namespace = namespace
        self.target = target
        self.remotePort = remotePort
        self.onError = onError
    }

    /// Starts listening; `localPort` nil or 0 picks a free port. Returns the bound port.
    public func start(localPort requested: UInt16? = nil) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: requested ?? 0) ?? .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        let resumed = OSAllocatedUnfairLock(initialState: false)
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                let result: Result<UInt16, Error>?
                switch state {
                case .ready: result = .success(listener.port?.rawValue ?? 0)
                case let .failed(error), let .waiting(error): result = .failure(error)
                default: result = nil
                }
                guard let result, resumed.withLock({ done in defer { done = true }; return !done }) else { return }
                if case .failure = result {
                    // A failed or waiting listener must be cancelled, or it keeps retrying and binds later.
                    listener.stateUpdateHandler = nil
                    listener.newConnectionHandler = nil
                    listener.cancel()
                }
                continuation.resume(with: result)
            }
            listener.start(queue: queue)
        }
        self.listener = listener
        localPort = port
        return port
    }

    /// Stops listening and closes open connections. Returns once the listening socket is closed, so the
    /// port can be bound again immediately.
    public func stop() async {
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        guard let listener else { return }
        self.listener = nil
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            listener.stateUpdateHandler = { state in
                if case .cancelled = state { continuation.resume() }
            }
            listener.cancel()
        }
    }

    private func accept(_ connection: NWConnection) async {
        guard listener != nil else { return connection.cancel() }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.start(queue: queue)
        do {
            try await bridge(connection)
        } catch {
            // The next connection resolves a service again, e.g. after its pod was replaced.
            cachedTarget = nil
            onError(ExecSession.describe(error, response: nil))
        }
        connection.cancel()
        connections[id] = nil
    }

    private func resolveTarget() async throws -> (pod: String, port: Int) {
        switch target {
        case let .pod(name):
            return (name, remotePort)
        case let .service(name):
            if let cached = cachedTarget, ContinuousClock.now - cached.at < Self.targetCacheLifetime {
                return (cached.pod, cached.port)
            }
            let resolved = try await ServiceTargetResolver.resolve(client: client, namespace: namespace, service: name, port: remotePort)
            cachedTarget = (resolved.pod, resolved.port, .now)
            return resolved
        }
    }

    private func bridge(_ connection: NWConnection) async throws {
        let (pod, port) = try await resolveTarget()
        let socket = try await client.transport.webSocket(
            path: GroupVersionResource.pods.path(namespace: namespace, name: pod, subresource: "portforward"),
            query: [URLQueryItem(name: "ports", value: String(port))],
            protocols: ["v4.channel.k8s.io"]
        )
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        let downstream = Task {
            // Closing the local connection also ends the upstream loop below, whatever ends this one.
            defer { connection.cancel() }
            var preambleSeen: Set<UInt8> = []
            while let message = try? await socket.receive() {
                guard case let .data(frame) = message, let (channel, payload) = ChannelFrameCodec.decode(frame) else { continue }
                // The first message on each channel only echoes the port number.
                if preambleSeen.insert(channel).inserted, ChannelFrameCodec.portPreamble(payload) != nil { continue }
                if channel == 0 {
                    guard await connection.sendChunk(payload) else { break }
                } else if !payload.isEmpty {
                    throw PortForwardError.remote(String(decoding: payload, as: UTF8.self))
                }
            }
        }
        while let chunk = await connection.receiveChunk() {
            try await socket.send(.data(ChannelFrameCodec.encode(channel: 0, chunk)))
        }
        // The channel protocol cannot pass on a half-close, so give a response still in flight a moment to
        // arrive before closing the stream.
        let drain = Task {
            try? await Task.sleep(for: .seconds(2))
            socket.cancel(with: .normalClosure, reason: nil)
        }
        defer { drain.cancel() }
        try await downstream.value
    }
}

extension NWConnection {
    /// Next bytes from the peer, or nil at end of stream or on error.
    func receiveChunk() async -> Data? {
        await withCheckedContinuation { continuation in
            receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                continuation.resume(returning: data.flatMap { $0.isEmpty ? nil : $0 })
            }
        }
    }

    func sendChunk(_ data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            send(content: data, completion: .contentProcessed { error in continuation.resume(returning: error == nil) })
        }
    }
}
