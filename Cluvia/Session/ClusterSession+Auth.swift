import Foundation
import KubeKit

/// A failed run of the kubeconfig's credential plugin, with the plugin invocation for display.
struct ExecAuthFailure {
    let error: any Error
    let exec: ExecConfig
}

/// Following the credential plugin's failures so a sign-in that expires mid-session is reported once, with a way to
/// sign in again, instead of as a reconnect loop on every table.
extension ClusterSession {
    func watchAuthFailures(of credentials: any CredentialProvider) {
        guard let provider = credentials as? ExecCredentialProvider else { return }
        execProvider = provider
        let exec = provider.config
        authFailureTask = Task { [weak self] in
            for await failure in await provider.failures() {
                // An event already buffered when this provider was replaced must not land on the new connection.
                guard !Task.isCancelled, let self, self.execProvider === provider else { return }
                self.authFailure = failure.map { ExecAuthFailure(error: $0, exec: exec) }
            }
        }
    }

    func stopWatchingAuth() {
        authFailureTask?.cancel()
        authFailureTask = nil
        execProvider = nil
        authFailure = nil
    }

    /// Runs the plugin again now (after signing in), instead of waiting for its cooldown.
    func retryAfterSignIn(using catalog: ClusterCatalogModel) async {
        await execProvider?.reset()
        if state == .connected {
            // Run the plugin here once, so the button stays busy until it finishes and the tables then reuse
            // the result instead of each starting a run.
            _ = try? await execProvider?.credentials()
            refresh()
        } else {
            await catalog.connect(self)
        }
    }
}
