import CFNetwork
import Foundation

enum TransportSessionConfiguration {
    /// Short-lived API calls.
    static let requestTimeout: TimeInterval = 30
    /// Watches, logs and exec streams can stay idle for long periods; the server ends them, not the client.
    static let streamTimeout: TimeInterval = 24 * 60 * 60

    static func make(idleTimeout: TimeInterval, proxy: [AnyHashable: Any]?) -> URLSessionConfiguration {
        // Ephemeral: no cookies, cache or credentials written to disk.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = idleTimeout
        configuration.timeoutIntervalForResource = idleTimeout == requestTimeout ? 5 * 60 : streamTimeout
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        // Many concurrent watches per cluster when the server falls back to HTTP/1.1.
        configuration.httpMaximumConnectionsPerHost = 64
        configuration.connectionProxyDictionary = proxy
        return configuration
    }

    /// Maps kubeconfig `proxy-url` to a CFNetwork proxy dictionary.
    static func proxyDictionary(_ value: String?) throws -> [AnyHashable: Any]? {
        guard let value, !value.isEmpty else { return nil }
        guard let url = URL(string: value), let host = url.host, let scheme = url.scheme?.lowercased() else {
            throw KubeTransportError.invalidProxyURL(value)
        }
        switch scheme {
        case "http", "https":
            let port = url.port ?? (scheme == "https" ? 443 : 80)
            return [
                kCFNetworkProxiesHTTPEnable: true, kCFNetworkProxiesHTTPProxy: host, kCFNetworkProxiesHTTPPort: port,
                kCFNetworkProxiesHTTPSEnable: true, kCFNetworkProxiesHTTPSProxy: host, kCFNetworkProxiesHTTPSPort: port,
            ]
        case "socks5", "socks5h":
            return [
                kCFNetworkProxiesSOCKSEnable: true, kCFNetworkProxiesSOCKSProxy: host,
                kCFNetworkProxiesSOCKSPort: url.port ?? 1080,
            ]
        default:
            throw KubeTransportError.invalidProxyURL(value)
        }
    }
}
