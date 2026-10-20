import Foundation
import os

/// Answers TLS challenges for one cluster: server trust from the cluster policy, client certificate from the
/// current credentials. The identity can change at runtime (exec plugins rotate certs), hence the lock.
final class TransportSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let policy: TrustPolicy
    private let identity = OSAllocatedUnfairLock<ClientIdentity?>(initialState: nil)
    /// Last rejected server certificate; URLSession only reports a generic cancellation for it.
    private let trustFailure = OSAllocatedUnfairLock<String?>(initialState: nil)

    init(policy: TrustPolicy) {
        self.policy = policy
    }

    func setIdentity(_ newValue: ClientIdentity?) {
        identity.withLock { $0 = newValue }
    }

    func takeTrustFailure() -> String? {
        trustFailure.withLock { value in
            defer { value = nil }
            return value
        }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let (disposition, credential) = answer(challenge)
        completionHandler(disposition, credential)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let (disposition, credential) = answer(challenge)
        completionHandler(disposition, credential)
    }

    private func answer(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust else { return (.cancelAuthenticationChallenge, nil) }
            if let reason = TrustEvaluator.failureReason(trust, host: challenge.protectionSpace.host, policy: policy) {
                trustFailure.withLock { $0 = reason }
                return (.cancelAuthenticationChallenge, nil)
            }
            return (.useCredential, URLCredential(trust: trust))
        case NSURLAuthenticationMethodClientCertificate:
            guard let current = identity.withLock({ $0 }) else { return (.performDefaultHandling, nil) }
            return (.useCredential, current.urlCredential)
        default:
            return (.performDefaultHandling, nil)
        }
    }
}
