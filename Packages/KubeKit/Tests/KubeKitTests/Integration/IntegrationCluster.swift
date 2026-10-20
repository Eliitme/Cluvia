import Foundation
import Testing
@testable import KubeKit

/// Access to a real cluster for integration tests. Enabled by `CLUVIA_IT_CONTEXT=<kubeconfig context>`.
enum IntegrationCluster {
    static let environment = ProcessInfo.processInfo.environment
    static var contextName: String? { environment["CLUVIA_IT_CONTEXT"] }
    static var isEnabled: Bool { contextName != nil }

    static func context() throws -> ResolvedContext {
        let urls = KubeConfigLoader.defaultFileURLs(environment: environment)
        return try MergedKubeConfig(KubeConfigLoader.loadAll(urls).configs).resolve(contextNamed: contextName ?? "")
    }

    static func transport() throws -> KubeTransport {
        try KubeTransport(context: try context())
    }

    /// Transport for the same cluster but authenticated by `credentials` instead of the kubeconfig user.
    static func transport(credentials: any CredentialProvider) throws -> KubeTransport {
        let cluster = try context().cluster
        return try KubeTransport(
            serverURL: URL(string: cluster.server)!, trust: try TrustPolicy.from(cluster), credentials: credentials
        )
    }

    static func json(_ transport: KubeTransport, _ request: KubeRequest) async throws -> [String: Any] {
        let (data, _) = try await transport.data(request)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func post(_ transport: KubeTransport, path: String, body: [String: Any]) async throws -> [String: Any] {
        try await json(transport, KubeRequest(
            method: "POST", path: path,
            body: try JSONSerialization.data(withJSONObject: body), contentType: "application/json"
        ))
    }

    /// Username the API server authenticated the transport as.
    static func authenticatedUser(_ transport: KubeTransport) async throws -> String? {
        let review = try await post(transport, path: "/apis/authentication.k8s.io/v1/selfsubjectreviews", body: [
            "apiVersion": "authentication.k8s.io/v1", "kind": "SelfSubjectReview",
        ])
        return ((review["status"] as? [String: Any])?["userInfo"] as? [String: Any])?["username"] as? String
    }

    /// Short-lived token for the `default` service account in `default`.
    static func serviceAccountToken(_ admin: KubeTransport) async throws -> String {
        let response = try await post(admin, path: "/api/v1/namespaces/default/serviceaccounts/default/token", body: [
            "apiVersion": "authentication.k8s.io/v1", "kind": "TokenRequest", "spec": ["expirationSeconds": 600],
        ])
        return try #require((response["status"] as? [String: Any])?["token"] as? String)
    }

    /// Ensures a long-running busybox pod exists and is Running; returns its name.
    static func ensureEchoPod(_ transport: KubeTransport) async throws -> String {
        let name = "cluvia-it-echo"
        let path = "/api/v1/namespaces/default/pods"
        do {
            _ = try await transport.data(KubeRequest(path: "\(path)/\(name)"))
        } catch let error as KubeAPIError where error.statusCode == 404 {
            _ = try await post(transport, path: path, body: [
                "apiVersion": "v1", "kind": "Pod",
                "metadata": ["name": name],
                "spec": ["containers": [["name": "echo", "image": "busybox:1.36", "command": ["sleep", "86400"]]]],
            ])
        }
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            let pod = try await json(transport, KubeRequest(path: "\(path)/\(name)"))
            if (pod["status"] as? [String: Any])?["phase"] as? String == "Running" { return name }
            try await Task.sleep(for: .seconds(2))
        }
        Issue.record("pod \(name) did not reach Running within 180s")
        throw CancellationError()
    }
}
