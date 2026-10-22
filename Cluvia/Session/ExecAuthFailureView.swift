import KubeKit
import SwiftUI

/// What went wrong with the credential plugin: the exact command, its error output, and the ways out
/// (retry, copy the command, or sign in through Terminal for the cloud CLIs that have a known login command).
struct ExecAuthFailureView: View {
    let failure: ExecAuthFailure
    let contextName: String
    let retry: () async -> Void
    @State private var loginScript: String?
    @State private var loginCommand: String?
    @State private var openError: String?
    @State private var retrying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: "person.badge.key").font(.title3.weight(.semibold))
            Text("Context \(contextName) signs in by running:").foregroundStyle(.secondary)
            Text(failure.exec.redactedCommandLine)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            ScrollView {
                Text(details)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            if let openError { Label(openError, systemImage: "xmark.octagon").foregroundStyle(.red) }
            HStack {
                // The full command may carry a client secret, so it goes on the clipboard like a secret value.
                Button("Copy Command") { SecretPasteboard.copy(failure.exec.commandLine) }
                    .help("Copies the full command, including hidden values; the clipboard clears in a minute")
                if let loginScript, let loginCommand {
                    Button("Sign In with \(loginCommand)…") {
                        Task {
                            do { try await LoginTerminalLauncher.open(loginScript) } catch { openError = error.localizedDescription }
                        }
                    }
                    .help("Opens Terminal; the command runs after you press Return there")
                }
                Spacer()
                Button("Retry") {
                    retrying = true
                    Task { await retry(); retrying = false }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(retrying)
            }
        }
        .padding(20)
        .frame(maxWidth: 640)
        .task { await prepareLogin() }
    }

    private var title: String {
        switch failure.error {
        case ExecPluginError.notFound: "Sign-in plugin not found"
        case ExecPluginError.invalidOutput: "Sign-in plugin returned invalid output"
        case ProcessRunnerError.timedOut: "Sign-in plugin timed out"
        default: "Sign-in failed"
        }
    }

    /// Error output only; the plugin's standard output (the credential itself) is never shown.
    private var details: String {
        if let plugin = failure.error as? ExecPluginError, let stderr = plugin.stderr { return stderr }
        return failure.error.localizedDescription
    }

    private func prepareLogin() async {
        guard let suggestion = ExecLoginSuggestion.command(for: failure.exec), let tool = suggestion.first,
              let executable = await LoginShellEnvironment.shared.resolveExecutable(tool) else { return }
        loginScript = LoginTerminalLauncher.script(
            context: contextName, executable: executable.path, arguments: Array(suggestion.dropFirst()), env: failure.exec.env ?? []
        )
        loginCommand = suggestion.prefix(3).joined(separator: " ")
    }
}
