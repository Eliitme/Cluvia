import Foundation
import Testing
@testable import KubeKit

@Suite struct KubeConfigSetEditingTests {
    static let sample = """
    apiVersion: v1
    kind: Config
    preferences: {colors: true}
    current-context: dev
    clusters:
    - name: dev-cluster
      cluster:
        server: https://dev.example:6443
        certificate-authority-data: QUJD
        extensions:
        - name: vendor
          extension: {region: eu}
    users:
    - name: dev-user
      user:
        token: secret-token
    contexts:
    - name: dev
      context: {cluster: dev-cluster, user: dev-user, namespace: apps}
    - name: other
      context: {cluster: dev-cluster, user: dev-user}
    """

    static let pem = "-----BEGIN CERTIFICATE-----\nAAA\n-----END CERTIFICATE-----"

    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func file(_ text: String, named name: String = "config", in folder: URL? = nil) throws -> URL {
        let url = try (folder ?? directory()).appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    func set(_ text: String = sample) throws -> KubeConfigSet {
        KubeConfigSet(documents: [try KubeConfigDocument(url: URL(fileURLWithPath: "/tmp/x/config"), text: text, original: Data())])
    }

    func yaml(_ set: KubeConfigSet, _ index: Int = 0) throws -> String {
        try set.documents[index].serialized()
    }

    @Test func editKeepsUnmodeledFieldsUntouchedCAAndQuotesAmbiguousStrings() throws {
        var config = try set()
        var draft = try config.draft(forContext: "dev")
        #expect(draft.server == "https://dev.example:6443")
        draft.namespace = "true"
        try config.apply(draft, originalName: "dev")
        let text = try yaml(config)
        #expect(text.contains("region: eu"))
        #expect(text.contains("colors: true"))
        #expect(text.contains("certificate-authority-data: QUJD"))
        #expect(text.contains("token: secret-token"))
        // Other kubeconfig readers would take an unquoted `true` as a boolean.
        #expect(text.contains("namespace: 'true'"))
    }

    @Test func caTextWithLinesBeforeThePEMBlockIsEncoded() throws {
        var config = try set()
        var draft = try config.draft(forContext: "dev")
        draft.certificateAuthorityPEM = "subject=CN = ca\n" + Self.pem
        try config.apply(draft, originalName: "dev")
        let stored = try #require(config.field(.clusters, "dev-cluster", "certificate-authority-data"))
        #expect(String(decoding: try #require(Data(base64Encoded: stored)), as: UTF8.self).hasPrefix("subject=CN = ca\n-----BEGIN"))
        draft.certificateAuthorityPEM = "not a certificate"
        #expect(throws: KubeConfigEditError.self) { try config.apply(draft, originalName: "dev") }
    }

    @Test func renameFollowsCurrentContextAndRejectsDuplicatesAndMissingContexts() throws {
        var config = try set()
        var draft = try config.draft(forContext: "dev")
        draft.name = "other"
        #expect(throws: KubeConfigEditError.duplicateName(section: "context", name: "other")) { try config.apply(draft, originalName: "dev") }
        draft.name = "dev-renamed"
        try config.apply(draft, originalName: "dev")
        #expect(config.currentContext == "dev-renamed")
        #expect(config.names(in: .contexts) == ["dev-renamed", "other"])
        #expect(throws: KubeConfigEditError.notFound(section: "context", name: "ghost")) { try config.apply(draft, originalName: "ghost") }
        #expect(throws: KubeConfigEditError.self) { try config.removeContext("ghost", pruneUnused: true) }
    }

    @Test func newPluginUserSatisfiesClientGoValidationAndReplacesOtherMethods() throws {
        var config = try set()
        var draft = KubeContextDraft()
        (draft.name, draft.clusterName, draft.server, draft.userName) = ("prod", "prod-cluster", "https://prod", "dev-user")
        draft.certificateAuthorityPEM = Self.pem
        draft.credentials = .exec(command: "aws", arguments: ["eks", "get-token"], apiVersion: "client.authentication.k8s.io/v1")
        try config.apply(draft, originalName: nil)
        let user = config.documents[0].body(.users, "dev-user")
        #expect(user?["token"] == nil)
        #expect(user?["exec"]?.mapping?["interactiveMode"]?.string == "IfAvailable")
        draft.userName = "brand-new"
        draft.name = "prod2"
        draft.credentials = .unchanged
        #expect(throws: KubeConfigEditError.self) { try config.apply(draft, originalName: nil) }
    }

    @Test func entriesAreEditedInTheFileThatDefinesThem() throws {
        let folder = try directory()
        let first = try file("contexts:\n- name: b\n  context: {cluster: shared, user: shared}\n", named: "b.yaml", in: folder)
        let second = try file(Self.sample.replacingOccurrences(of: "dev-cluster", with: "shared").replacingOccurrences(of: "dev-user", with: "shared"), named: "a.yaml", in: folder)
        var config = try KubeConfigSet.load([first, second])
        var draft = try config.draft(forContext: "b")
        #expect(draft.server == "https://dev.example:6443")
        draft.namespace = "team"
        try config.apply(draft, originalName: "b")
        try config.save()
        let reloaded = try KubeConfigSet.load([first, second])
        #expect(reloaded.documents[0].names(in: .clusters).isEmpty)
        #expect(reloaded.documents[0].names(in: .users).isEmpty)
        #expect(reloaded.field(.contexts, "b", "namespace") == "team")
        #expect(reloaded.field(.users, "shared", "token") == "secret-token")

        // Set as current goes where kubectl reads it: the first file that sets current-context (a.yaml here).
        var current = reloaded
        current.setCurrentContext("b")
        #expect(current.documents[1].currentContext == "b")
        // Pruning considers contexts in every file.
        try current.removeContext("dev", pruneUnused: true)
        #expect(current.names(in: .clusters) == ["shared"])
    }

    @Test func importResolvesRelativePathsAndChecksAllFiles() throws {
        let source = try KubeConfigDocument(url: URL(fileURLWithPath: "/src/dir/config"), text: Self.sample.replacingOccurrences(
            of: "token: secret-token", with: "exec: {command: ./bin/auth, apiVersion: client.authentication.k8s.io/v1}"
        ), original: nil)
        var config = try set("")
        try config.importContexts(["dev"], from: source, replaceExisting: false)
        #expect(config.documents[0].body(.users, "dev-user")?["exec"]?.mapping?["command"]?.string == "/src/dir/bin/auth")
        #expect(throws: KubeConfigEditError.nameConflicts(["dev", "dev-cluster", "dev-user"])) {
            try config.importContexts(["dev"], from: source, replaceExisting: false)
        }
    }

    @Test func saveKeepsBackupsAndPermissionsAndRefusesConcurrentChanges() throws {
        let url = try file(Self.sample)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        var config = try KubeConfigSet.load([url])
        try config.removeContext("other", pruneUnused: false)
        try config.save()
        var again = try KubeConfigSet.load([url])
        again.setCurrentContext("dev")
        try again.save()
        let folder = url.deletingLastPathComponent()
        let backups = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("config.cluvia-backup-") }.sorted()
        #expect(backups.count == 2)
        #expect(try String(contentsOf: folder.appendingPathComponent(backups[0]), encoding: .utf8) == Self.sample)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o640)
        #expect(!FileManager.default.fileExists(atPath: url.path + ".lock"))

        var stale = try KubeConfigSet.load([url])
        stale.setCurrentContext("dev")
        try Data("apiVersion: v1\n".utf8).write(to: url)
        #expect(throws: KubeConfigEditError.changedOnDisk(path: url.path)) { try stale.save() }

        try Data().write(to: URL(fileURLWithPath: url.path + ".lock"))
        var locked = try KubeConfigSet.load([url])
        locked.setCurrentContext("x")
        #expect(throws: KubeConfigEditError.locked(path: url.path + ".lock")) { try locked.save() }
    }

    @Test func newContextsGoToTheFirstExistingFile() throws {
        let folder = try directory()
        let missing = folder.appendingPathComponent("missing.yaml")
        let existing = try file("", named: "existing.yaml", in: folder)
        var config = try KubeConfigSet.load([missing, existing])
        #expect(config.primaryFile == existing)
        var draft = KubeContextDraft()
        (draft.name, draft.clusterName, draft.userName, draft.server) = ("a", "a", "a", "https://a")
        draft.credentials = .token("t")
        try config.apply(draft, originalName: nil)
        try config.save()
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        #expect(try KubeConfigLoader.load(contentsOf: existing).contexts.map(\.name) == ["a"])
    }

    @Test func newClusterOrUserNamesMustBeUnused() throws {
        var config = try set()
        var draft = KubeContextDraft()
        (draft.name, draft.clusterName, draft.server, draft.userName) = ("new", "dev-cluster", "https://evil", "fresh")
        draft.createsCluster = true
        draft.createsUser = true
        draft.credentials = .token("t")
        #expect(throws: KubeConfigEditError.duplicateName(section: "cluster", name: "dev-cluster")) { try config.apply(draft, originalName: nil) }
        #expect(config.field(.clusters, "dev-cluster", "server") == "https://dev.example:6443")
    }

    @Test func insecureFlagReadsLikeKubectl() throws {
        let config = try set(Self.sample.replacingOccurrences(of: "certificate-authority-data: QUJD", with: "insecure-skip-tls-verify: True"))
        #expect(try config.draft(forContext: "dev").insecureSkipTLSVerify)
    }

    @Test func multiFileSaveWritesNothingWhenOneFileIsLocked() throws {
        let folder = try directory()
        let first = try file("current-context: other\n", named: "a.yaml", in: folder)
        let second = try file(Self.sample.replacingOccurrences(of: "current-context: dev\n", with: ""), named: "b.yaml", in: folder)
        var config = try KubeConfigSet.load([first, second])
        var draft = try config.draft(forContext: "dev")
        draft.name = "dev2"
        config.setCurrentContext("dev")
        try config.apply(draft, originalName: "dev")
        try Data().write(to: URL(fileURLWithPath: second.path + ".lock"))
        #expect(throws: KubeConfigEditError.locked(path: second.path + ".lock")) { try config.save() }
        #expect(try String(contentsOf: first, encoding: .utf8) == "current-context: other\n")
        #expect(FileManager.default.fileExists(atPath: second.path + ".lock"))
        #expect(!FileManager.default.fileExists(atPath: first.path + ".lock"))
    }
}
