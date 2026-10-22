import Foundation
import Testing
@testable import KubeKit

struct ExecLoginSuggestionTests {
    static func config(_ command: String, _ args: [String], env: [String: String] = [:]) -> ExecConfig {
        ExecConfig(command: command, args: args, env: env.map { ExecEnvVar(name: $0.key, value: $0.value) })
    }

    @Test func knownLoginFlows() {
        let eks = ["eks", "get-token", "--cluster-name", "prod"]
        #expect(ExecLoginSuggestion.command(for: Self.config("aws", eks + ["--profile", "prod"])) == ["aws", "sso", "login", "--profile", "prod"])
        #expect(ExecLoginSuggestion.command(for: Self.config("/opt/homebrew/bin/aws", eks + ["--profile=dev"])) == ["aws", "sso", "login", "--profile", "dev"])
        #expect(ExecLoginSuggestion.command(for: Self.config("aws", eks, env: ["AWS_PROFILE": "ops"])) == ["aws", "sso", "login", "--profile", "ops"])
        #expect(ExecLoginSuggestion.command(for: Self.config("aws", eks)) == ["aws", "sso", "login"])
        #expect(ExecLoginSuggestion.command(for: Self.config("gke-gcloud-auth-plugin", [])) == ["gcloud", "auth", "login"])
        #expect(ExecLoginSuggestion.command(for: Self.config("kubelogin", ["get-token", "--login", "azurecli"])) == ["az", "login"])
    }

    @Test func unknownPluginsGetNoSuggestion() {
        #expect(ExecLoginSuggestion.command(for: Self.config("kubectl", ["oidc-login", "get-token"])) == nil)
        #expect(ExecLoginSuggestion.command(for: Self.config("kubelogin", ["get-token", "--login", "devicecode"])) == nil)
        #expect(ExecLoginSuggestion.command(for: Self.config("aws", ["sts", "get-caller-identity"])) == nil)
        #expect(ExecLoginSuggestion.command(for: Self.config("my-plugin", [])) == nil)
    }

    @Test func commandLineQuotesEveryWord() {
        let config = Self.config("/path with space/plugin", ["it's", "$(id)"])
        #expect(config.commandLine == #"'/path with space/plugin' 'it'\''s' '$(id)'"#)
    }

    @Test func credentialFlagValuesAreHiddenForDisplay() {
        let config = Self.config("kubelogin", ["get-token", "--client-secret", "s3cr3t", "--password=hunter2", "--server-id", "abc"])
        #expect(config.redactedCommandLine == "'kubelogin' 'get-token' '--client-secret' '<redacted>' '--password=<redacted>' '--server-id' 'abc'")
        #expect(config.commandLine.contains("s3cr3t"))
    }

    @Test func envNames() {
        #expect(ExecLoginSuggestion.isValidEnvName("AWS_PROFILE"))
        #expect(ExecLoginSuggestion.isValidEnvName("_x1"))
        for bad in ["", "1A", "A-B", "X=1;id", "A B", "É"] { #expect(!ExecLoginSuggestion.isValidEnvName(bad)) }
    }
}
