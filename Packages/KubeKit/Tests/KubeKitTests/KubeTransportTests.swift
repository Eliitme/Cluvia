import CFNetwork
import Foundation
import Testing
@testable import KubeKit

struct KubeTransportTests {
    static func transport(_ server: String) throws -> KubeTransport {
        try KubeTransport(
            serverURL: URL(string: server)!, trust: TrustPolicy(),
            credentials: StaticCredentialProvider(user: AuthInfo(token: "t"))
        )
    }

    @Test func urlKeepsServerPathPrefixAndEncodesPlus() throws {
        let transport = try Self.transport("https://gw.example/k8s/clusters/c-1/")
        let url = try transport.url(
            path: "/api/v1/pods", query: [URLQueryItem(name: "labelSelector", value: "a+b=c")], webSocket: false
        )
        #expect(url.path == "/k8s/clusters/c-1/api/v1/pods")
        #expect(url.query?.contains("a%2Bb") == true)
        let decoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        #expect(decoded == [URLQueryItem(name: "labelSelector", value: "a+b=c")])

        let command = try transport.url(path: "/x", query: [
            URLQueryItem(name: "command", value: "echo err >&2; a=b"), URLQueryItem(name: "command", value: "x y"),
        ], webSocket: false)
        #expect(URLComponents(url: command, resolvingAgainstBaseURL: false)?.queryItems == [
            URLQueryItem(name: "command", value: "echo err >&2; a=b"), URLQueryItem(name: "command", value: "x y"),
        ])
    }

    @Test func webSocketUrlSwitchesScheme() throws {
        #expect(try Self.transport("https://h:6443").url(path: "/x", query: [], webSocket: true).scheme == "wss")
        #expect(try Self.transport("http://h:8080").url(path: "/x", query: [], webSocket: true).scheme == "ws")
    }

    @Test func proxyDictionaries() throws {
        #expect(try TransportSessionConfiguration.proxyDictionary(nil) == nil)
        let http = try #require(try TransportSessionConfiguration.proxyDictionary("http://proxy.local:3128"))
        #expect(http[kCFNetworkProxiesHTTPSProxy] as? String == "proxy.local")
        #expect(http[kCFNetworkProxiesHTTPSPort] as? Int == 3128)
        let socks = try #require(try TransportSessionConfiguration.proxyDictionary("socks5://127.0.0.1"))
        #expect(socks[kCFNetworkProxiesSOCKSPort] as? Int == 1080)
        #expect(throws: KubeTransportError.self) { try TransportSessionConfiguration.proxyDictionary("ftp://x") }
    }

    @Test func apiErrorDecodesStatusObject() {
        let body = Data(#"{"kind":"Status","status":"Failure","message":"pods \"x\" not found","reason":"NotFound","code":404}"#.utf8)
        let error = KubeAPIError(statusCode: 404, body: body)
        #expect(error.reason == "NotFound")
        #expect(error.message == "pods \"x\" not found")
        #expect(KubeAPIError(statusCode: 406, body: Data("406: Not Acceptable".utf8)).message == "406: Not Acceptable")
    }

    @Test func trustPolicyFromInlineCAData() async throws {
        let material = try await ClientIdentityFactoryTests.makeCertificate(keyArgs: ["genrsa", "2048"])
        var cluster = ExecCredentialDecodingTests.cluster
        cluster.certificateAuthorityData = material.cert.base64EncodedString()
        cluster.insecureSkipTLSVerify = true
        let policy = try TrustPolicy.from(cluster)
        #expect(policy.anchors.count == 1)
        #expect(policy.insecureSkipVerify)
        #expect(policy.serverName == "api.internal")

        cluster.certificateAuthorityData = Data("not a certificate".utf8).base64EncodedString()
        #expect(throws: CredentialError.self) { try TrustPolicy.from(cluster) }
    }

    @Test func staticProviderRereadsTokenFileAndRejectsHalfCertificate() async throws {
        let tokenFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tokenFile) }
        try "first\n".write(to: tokenFile, atomically: true, encoding: .utf8)
        var user = AuthInfo()
        user.tokenFile = tokenFile.path
        let provider = StaticCredentialProvider(user: user)
        #expect(try await provider.credentials().bearerToken == "first")
        try "second".write(to: tokenFile, atomically: true, encoding: .utf8)
        #expect(try await provider.credentials().bearerToken == "second")

        user.token = "inline"
        #expect(try await StaticCredentialProvider(user: user).credentials().bearerToken == "second")
        try "".write(to: tokenFile, atomically: true, encoding: .utf8)
        user.token = nil
        #expect(try await StaticCredentialProvider(user: user).credentials().bearerToken == nil)

        var halfCert = AuthInfo()
        halfCert.clientCertificateData = "Zm9v"
        await #expect(throws: CredentialError.self) { try await StaticCredentialProvider(user: halfCert).credentials() }
    }
}

extension KubeTransportTests {
    @Test func unsupportedAuthIsReportedNotSentAnonymously() async throws {
        let yaml = """
        users:
        - name: legacy
          user:
            auth-provider:
              name: oidc
        """
        let config = try KubeConfigLoader.decode(Data(yaml.utf8), path: "x", baseDirectory: URL(fileURLWithPath: "/"))
        let provider = StaticCredentialProvider(user: try #require(config.users.first?.user))
        await #expect(throws: CredentialError.self) { try await provider.credentials() }
    }
}
