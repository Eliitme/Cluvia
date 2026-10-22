import AppKit
import KubeKit

/// Opens Terminal with a cloud CLI sign-in command, run only after the user presses Return.
///
/// The script is the one place kubeconfig text reaches a shell, so every dynamic word is single-quoted and printed
/// with `printf '%s'` (never inside double quotes, where `$(…)` would run). It deletes itself first thing, exports
/// only account-selecting variables (never credentials from the kubeconfig), and runs a login tool, never the
/// credential plugin, so no token is printed.
enum LoginTerminalLauncher {
    static let filePrefix = "cluvia-login-"
    static let loginTools: Set<String> = ["aws", "gcloud", "az"]

    /// nil unless `executable` is a known login tool and every environment name is a plain shell name.
    static func script(context: String, executable: String, arguments: [String], env: [ExecEnvVar]) -> String? {
        guard loginTools.contains((executable as NSString).lastPathComponent),
              env.allSatisfy({ ExecLoginSuggestion.isValidEnvName($0.name) }) else { return nil }
        let quote = ExecLoginSuggestion.quoted
        let words = [executable] + arguments
        let exports = env.filter { ExecLoginSuggestion.passedEnvNames.contains($0.name) }
        var lines = [
            "#!/bin/zsh -l",
            #"rm -f -- "$0""#,
            "clear",
            "printf '%s\\n' \(quote("Cluvia: sign in for context")) \(quote(printable(context)))",
        ]
        // Everything that will happen is shown before the prompt.
        for variable in exports {
            lines.append("printf 'export %s=%s\\n' \(quote(variable.name)) \(quote(printable(variable.value)))")
        }
        lines += [
            "printf '$ %s\\n' \(quote(words.map { quote(printable($0)) }.joined(separator: " ")))",
            "read -r '?Press Return to run, Ctrl-C to cancel ' || exit 1",
        ]
        lines += exports.map { "export \($0.name)=\(quote($0.value))" }
        lines.append("\(words.map(quote).joined(separator: " ")) && printf '%s\\n' \(quote("Signed in. Return to Cluvia and press Retry."))")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Text shown in the terminal with control characters replaced, so escape sequences in a kubeconfig cannot
    /// retitle the window or overwrite the command line the user is approving.
    static func printable(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { $0.properties.generalCategory == .control ? "?" : $0 }))
    }

    /// Writes the script (owner-only) and runs it in Terminal, whatever app is set to open `.command` files.
    static func open(_ script: String) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(filePrefix)\(UUID().uuidString).command")
        guard FileManager.default.createFile(atPath: url.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o700]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        do {
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Terminal is not installed."])
            }
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Removes scripts that never ran (Terminal closed before reading them, or a crash).
    static func sweepLeftovers() {
        let directory = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(filePrefix) && name.hasSuffix(".command") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
