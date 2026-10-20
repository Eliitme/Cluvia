import Foundation
import Testing
@testable import KubeKit

struct KubeConfigMergerTests {
    static let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
    static let fileA = fixtures.appendingPathComponent("multi/a/config")
    static let fileB = fixtures.appendingPathComponent("multi/b/config")

    static func merged() -> MergedKubeConfig {
        MergedKubeConfig(KubeConfigLoader.loadAll([fileA, fileB]).configs)
    }

    @Test func firstFileWinsPerNameAndForCurrentContext() throws {
        let config = Self.merged()
        #expect(config.clusters["shared"]?.server == "https://a.example:6443")
        #expect(config.users["shared-user"]?.token == nil)
        #expect(config.contexts["shared-ctx"]?.namespace == "team-a")
        #expect(config.currentContext == "shared-ctx")
        #expect(Set(config.contexts.keys) == ["shared-ctx", "a-only", "b-only", "broken"])
    }

    @Test func summariesSortedWithCurrentMarked() {
        let summaries = Self.merged().contextSummaries
        #expect(summaries.map(\.name) == ["a-only", "b-only", "broken", "shared-ctx"])
        #expect(summaries.filter(\.isCurrent).map(\.name) == ["shared-ctx"])
        #expect(summaries.first { $0.name == "b-only" }?.server == "https://only-b.example")
        #expect(summaries.first { $0.name == "broken" }?.server == nil)
    }

    @Test func relativePathsResolveAgainstDeclaringFile() throws {
        let dirA = Self.fileA.deletingLastPathComponent().standardizedFileURL.path
        let context = try Self.merged().resolve(contextNamed: "shared-ctx")
        #expect(context.cluster.certificateAuthority == dirA + "/certs/ca.pem")
        #expect(context.user.clientCertificate == dirA + "/certs/client.crt")
        #expect(context.user.clientKey == "/abs/client.key")
        #expect(context.user.tokenFile == dirA + "/token")

        let config = Self.merged()
        #expect(config.users["exec-user"]?.exec?.command == dirA + "/bin/plugin")
        #expect(config.users["bare-exec-user"]?.exec?.command == "aws")
    }

    @Test func decodesClusterAndExecFields() throws {
        let config = Self.merged()
        let onlyA = try #require(config.clusters["only-a"])
        #expect(onlyA.insecureSkipTLSVerify == true)
        #expect(onlyA.proxyURL == "socks5://127.0.0.1:1080")
        #expect(config.clusters["shared"]?.tlsServerName == "api.internal")
        let exec = try #require(config.users["exec-user"]?.exec)
        #expect(exec.args == ["--flag"])
        #expect(exec.env == [ExecEnvVar(name: "PROFILE", value: "dev")])
        #expect(exec.provideClusterInfo == true)
        #expect(exec.interactiveMode == "Never")
    }

    @Test func resolveReportsMissingReferences() {
        let config = Self.merged()
        #expect(throws: KubeConfigError.contextNotFound("nope")) { try config.resolve(contextNamed: "nope") }
        #expect(throws: KubeConfigError.clusterNotFound(context: "broken", cluster: "missing-cluster")) {
            try config.resolve(contextNamed: "broken")
        }
    }

    @Test func loaderSkipsMissingAndDuplicateFilesAndReportsInvalid() {
        let result = KubeConfigLoader.loadAll([
            Self.fileA, Self.fileA, Self.fixtures.appendingPathComponent("does-not-exist"),
            Self.fixtures.appendingPathComponent("empty-config"), Self.fixtures.appendingPathComponent("invalid-config"),
        ])
        #expect(result.configs.count == 2)
        #expect(result.configs.last == KubeConfig())
        #expect(result.errors.count == 1)
    }

    @Test func defaultFilesFollowKubeconfigVariable() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(KubeConfigLoader.defaultFileURLs(environment: [:], home: home).map(\.path) == ["/Users/someone/.kube/config"])
        #expect(KubeConfigLoader.defaultFileURLs(environment: ["KUBECONFIG": "/a::/b"], home: home).map(\.path) == ["/a", "/b"])
    }

    /// Context listing must match `kubectl config get-contexts` for the same file list.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/local/bin/kubectl")
        || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/kubectl")))
    func matchesKubectlContextListing() async throws {
        let kubectl = await LoginShellEnvironment.shared.resolveExecutable("kubectl")
        let result = try await ProcessRunner.run(
            try #require(kubectl), arguments: ["config", "get-contexts", "-o", "name"],
            environment: ["KUBECONFIG": "\(Self.fileA.path):\(Self.fileB.path)", "HOME": NSHomeDirectory()]
        )
        let expected = result.stdoutText.split(separator: "\n").map(String.init).sorted()
        #expect(Self.merged().contextSummaries.map(\.name) == expected)
    }
}

extension KubeConfigMergerTests {
    @Test func partialEntriesAreListedNotFatal() throws {
        let yaml = """
        clusters:
        - name: no-server
          cluster: {}
        contexts:
        - name: no-user
          context:
            cluster: no-server
        """
        let config = MergedKubeConfig([try KubeConfigLoader.decode(Data(yaml.utf8), path: "x", baseDirectory: URL(fileURLWithPath: "/"))])
        #expect(config.contextSummaries.map(\.name) == ["no-user"])
        #expect(throws: KubeConfigError.userNotFound(context: "no-user", user: "")) { try config.resolve(contextNamed: "no-user") }
    }

    @Test func parseErrorsNeverEchoSecrets() {
        let yaml = "users:\n- name: u\n  user:\n    token: s3cr3t-value\n   bad: [unclosed\n"
        do {
            _ = try KubeConfigLoader.decode(Data(yaml.utf8), path: "x", baseDirectory: URL(fileURLWithPath: "/"))
            Issue.record("expected failure")
        } catch {
            #expect(!error.localizedDescription.contains("s3cr3t"))
        }
    }
}
