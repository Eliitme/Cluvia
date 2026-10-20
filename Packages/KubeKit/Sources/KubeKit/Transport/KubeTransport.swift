import Foundation
import Security

/// Authenticated HTTP/WebSocket access to one cluster's API server.
///
/// Owns two sessions sharing one TLS delegate: a request session with short timeouts and a stream session
/// (watch, logs, exec, port-forward) without an idle cutoff. A 401 drops the credentials that were used and
/// retries once, which re-runs exec plugins whose tokens expired early.
public actor KubeTransport {
    public nonisolated let serverURL: URL
    private let credentials: any CredentialProvider
    private let delegate: TransportSessionDelegate
    private let proxy: [AnyHashable: Any]?
    private var requestSession: URLSession
    private var streamSession: URLSession
    /// DER of the client certificate the current sessions present. A client cert is bound to a TLS connection,
    /// so when it changes (rotated by an exec plugin, renewed on disk) pooled connections must be dropped.
    private var sessionCertificate: Data?
    /// Newest credential generation applied; a request that fetched older credentials must not roll the
    /// sessions back to a stale certificate.
    private var appliedGeneration: UInt64 = 0

    public init(serverURL: URL, trust: TrustPolicy, proxyURL: String? = nil, credentials: any CredentialProvider) throws {
        let proxy = try TransportSessionConfiguration.proxyDictionary(proxyURL)
        let delegate = TransportSessionDelegate(policy: trust)
        self.serverURL = serverURL
        self.credentials = credentials
        self.delegate = delegate
        self.proxy = proxy
        (requestSession, streamSession) = Self.makeSessions(delegate: delegate, proxy: proxy)
    }

    public init(context: ResolvedContext, shell: LoginShellEnvironment = .shared) throws {
        guard let url = URL(string: context.cluster.server), url.host != nil else {
            throw KubeTransportError.invalidServerURL(context.cluster.server)
        }
        try self.init(
            serverURL: url,
            trust: try TrustPolicy.from(context.cluster),
            proxyURL: context.cluster.proxyURL,
            credentials: CredentialProviderFactory.make(for: context, shell: shell)
        )
    }

    deinit {
        requestSession.invalidateAndCancel()
        streamSession.invalidateAndCancel()
    }

    /// Buffered request; throws `KubeAPIError` for non-2xx responses.
    public func data(_ request: KubeRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await sendWithAuthRetry(request) { session, urlRequest in
            try await session.request.data(for: urlRequest)
        }
        guard (200..<300).contains(response.statusCode) else { throw KubeAPIError(statusCode: response.statusCode, body: data) }
        return (data, response)
    }

    /// Streaming request (watch, follow logs); throws `KubeAPIError` for non-2xx responses.
    public func bytes(_ request: KubeRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let (bytes, response) = try await sendWithAuthRetry(request) { session, urlRequest in
            try await session.stream.bytes(for: urlRequest)
        }
        guard (200..<300).contains(response.statusCode) else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 64 * 1024 { break }
            }
            throw KubeAPIError(statusCode: response.statusCode, body: body)
        }
        return (bytes, response)
    }

    /// Opens a WebSocket (exec, attach, port-forward) offering the given Kubernetes subprotocols in preference order.
    public func webSocket(path: String, query: [URLQueryItem], protocols: [String]) async throws -> URLSessionWebSocketTask {
        // Streaming subresources have no JSON representation; `Accept: application/json` gets a 406.
        var (request, _) = try await urlRequest(for: KubeRequest(path: path, query: query, accept: "*/*"), webSocket: true)
        request.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let task = streamSession.webSocketTask(with: request)
        task.resume()
        return task
    }

    private func sendWithAuthRetry<Body>(
        _ request: KubeRequest,
        perform: ((request: URLSession, stream: URLSession), URLRequest) async throws -> (Body, URLResponse)
    ) async throws -> (Body, HTTPURLResponse) {
        var retried = false
        while true {
            let (urlRequest, generation) = try await urlRequest(for: request, webSocket: false)
            let (body, response): (Body, URLResponse)
            _ = delegate.takeTrustFailure() // drop stale failures, e.g. from an earlier WebSocket handshake
            do {
                (body, response) = try await perform((requestSession, streamSession), urlRequest)
            } catch let error as URLError where error.code == .cancelled || error.code == .secureConnectionFailed {
                if let reason = delegate.takeTrustFailure() { throw KubeTransportError.untrustedServer(reason) }
                throw error
            }
            guard let http = response as? HTTPURLResponse else { throw KubeTransportError.nonHTTPResponse }
            if http.statusCode == 401, !retried {
                retried = true
                await credentials.invalidate(generation: generation)
                continue
            }
            return (body, http)
        }
    }

    private func urlRequest(for request: KubeRequest, webSocket: Bool) async throws -> (URLRequest, generation: UInt64) {
        let current = try await credentials.credentials()
        applyIdentity(current.identity, generation: current.generation)

        var urlRequest = URLRequest(url: try url(path: request.path, query: request.query, webSocket: webSocket))
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.setValue(request.accept, forHTTPHeaderField: "Accept")
        urlRequest.setValue("Cluvia", forHTTPHeaderField: "User-Agent")
        if let contentType = request.contentType { urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let token = current.bearerToken { urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return (urlRequest, current.generation)
    }

    private func applyIdentity(_ identity: ClientIdentity?, generation: UInt64) {
        guard generation >= appliedGeneration else { return }
        appliedGeneration = generation
        let certificate = identity?.leafCertificateData
        guard certificate != sessionCertificate else { return }
        if sessionCertificate != nil {
            // In-flight streams finish on the old connections; new requests handshake with the new certificate.
            requestSession.finishTasksAndInvalidate()
            streamSession.finishTasksAndInvalidate()
            (requestSession, streamSession) = Self.makeSessions(delegate: delegate, proxy: proxy)
        }
        sessionCertificate = certificate
        delegate.setIdentity(identity)
    }

    private static func makeSessions(delegate: TransportSessionDelegate, proxy: [AnyHashable: Any]?) -> (URLSession, URLSession) {
        func session(_ timeout: TimeInterval) -> URLSession {
            URLSession(
                configuration: TransportSessionConfiguration.make(idleTimeout: timeout, proxy: proxy),
                delegate: delegate, delegateQueue: nil
            )
        }
        return (session(TransportSessionConfiguration.requestTimeout), session(TransportSessionConfiguration.streamTimeout))
    }

    /// Appends `path` to the server URL, preserving any path prefix (clusters behind a gateway).
    nonisolated func url(path: String, query: [URLQueryItem], webSocket: Bool) throws -> URL {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            throw KubeTransportError.invalidServerURL(serverURL.absoluteString)
        }
        let prefix = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = prefix + path
        components.queryItems = query.isEmpty ? nil : query
        // URLComponents leaves `+` literal, which servers decode as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        if webSocket { components.scheme = components.scheme == "http" ? "ws" : "wss" }
        guard let url = components.url else { throw KubeTransportError.invalidServerURL(serverURL.absoluteString) }
        return url
    }
}

extension ClientIdentity {
    var leafCertificateData: Data? {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return nil }
        return SecCertificateCopyData(certificate) as Data
    }
}
