import Foundation

/// The sign-in command that fixes a failing credential plugin, for the few plugins whose login flow is well known.
/// Anything else gets no suggestion: running an unknown plugin by hand would print its token to the terminal.
public enum ExecLoginSuggestion {
    /// Variables from the kubeconfig `env` that select an account or config and carry no secret.
    public static let passedEnvNames: Set<String> = ["AWS_PROFILE", "AWS_REGION", "AWS_DEFAULT_REGION", "KUBECONFIG", "CLOUDSDK_CONFIG"]

    public static func command(for config: ExecConfig) -> [String]? {
        let args = config.args ?? []
        switch (config.command as NSString).lastPathComponent {
        case "aws" where args.contains("eks") && args.contains("get-token"):
            let profile = value(of: "--profile", in: args) ?? config.env?.first { $0.name == "AWS_PROFILE" }?.value
            return ["aws", "sso", "login"] + (profile.map { ["--profile", $0] } ?? [])
        case "gke-gcloud-auth-plugin":
            return ["gcloud", "auth", "login"]
        case "kubelogin" where (value(of: "--login", in: args) ?? value(of: "-l", in: args)) == "azurecli":
            return ["az", "login"]
        default:
            return nil
        }
    }

    /// A shell variable name; anything else could not be exported safely.
    public static func isValidEnvName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || (first.isASCII && first.properties.isAlphabetic) else { return false }
        return name.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0))) }
    }

    /// POSIX single-quoted word: nothing inside is expanded by the shell.
    public static func quoted(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// `--flag value` or `--flag=value`.
    static func value(of flag: String, in args: [String]) -> String? {
        for (index, arg) in args.enumerated() {
            if arg == flag, args.indices.contains(index + 1) { return args[index + 1] }
            if arg.hasPrefix(flag + "=") { return String(arg.dropFirst(flag.count + 1)) }
        }
        return nil
    }
}

extension ExecConfig {
    static let redacted = "<redacted>"

    /// The plugin invocation as a shell would need it typed; environment values are left out.
    public var commandLine: String {
        ([command] + (args ?? [])).map(ExecLoginSuggestion.quoted).joined(separator: " ")
    }

    /// `commandLine` with the values of credential flags (`--client-secret`, `--token`, …) hidden, for display.
    public var redactedCommandLine: String {
        var words = [command]
        var hideNext = false
        for arg in args ?? [] {
            if hideNext {
                words.append(Self.redacted)
                hideNext = false
            } else if arg.hasPrefix("-"), let equals = arg.firstIndex(of: "="), Self.isCredentialFlag(String(arg[..<equals])) {
                words.append(arg[..<equals] + "=" + Self.redacted)
            } else {
                hideNext = arg.hasPrefix("-") && Self.isCredentialFlag(arg)
                words.append(arg)
            }
        }
        return words.map(ExecLoginSuggestion.quoted).joined(separator: " ")
    }

    static func isCredentialFlag(_ flag: String) -> Bool {
        let name = flag.lowercased()
        return ["secret", "token", "password", "passwd", "key"].contains { name.contains($0) }
    }
}

extension ExecPluginError {
    public var command: String {
        switch self {
        case let .notFound(command, _, _), let .failed(command, _, _), let .invalidOutput(command, _): command
        }
    }

    public var stderr: String? {
        if case let .failed(_, _, stderr) = self, !stderr.isEmpty { return stderr }
        return nil
    }
}
