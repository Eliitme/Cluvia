import Foundation

/// An API server request relative to the cluster's server URL.
public struct KubeRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [URLQueryItem]
    public var body: Data?
    public var contentType: String?
    public var accept: String

    public init(
        method: String = "GET", path: String, query: [URLQueryItem] = [],
        body: Data? = nil, contentType: String? = nil, accept: String = "application/json"
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.contentType = contentType
        self.accept = accept
    }
}

/// Non-2xx response, decoded from the API server's `Status` object when possible.
public struct KubeAPIError: Error, LocalizedError, Sendable {
    public let statusCode: Int
    public let reason: String?
    public let message: String

    public var errorDescription: String? { "\(statusCode)\(reason.map { " \($0)" } ?? ""): \(message)" }

    init(statusCode: Int, body: Data) {
        struct Status: Decodable {
            var reason: String?
            var message: String?
        }
        let status = try? JSONDecoder().decode(Status.self, from: body)
        self.statusCode = statusCode
        reason = status?.reason
        let text = String(decoding: body.prefix(2048), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        message = status?.message ?? (text.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: statusCode) : text)
    }
}

public enum KubeTransportError: Error, LocalizedError, Sendable {
    case invalidServerURL(String)
    case invalidProxyURL(String)
    case nonHTTPResponse
    case untrustedServer(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidServerURL(url): url.isEmpty ? "Cluster has no server URL" : "Invalid cluster server URL: \(url)"
        case let .invalidProxyURL(url): "Unsupported proxy-url: \(url) (use http, https or socks5)"
        case .nonHTTPResponse: "Server returned a non-HTTP response"
        case let .untrustedServer(reason): "API server certificate rejected: \(reason)"
        }
    }
}
