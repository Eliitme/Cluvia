import AppKit
import KubeKit

/// Kubeconfig changes made from the sidebar. Each change starts from the files as they are now on disk, writes only
/// the files it touched (backing each up) and reloads the catalog.
extension ClusterCatalogModel {
    /// The file defining a context, for "Show in Finder".
    func file(for context: String) -> URL? {
        contextSources[context]
    }

    /// Where new and imported contexts go: the first kubeconfig file that exists, as with kubectl.
    var primaryFile: URL? {
        files.first { FileManager.default.fileExists(atPath: $0.path) } ?? files.first
    }

    func loadConfigSet() throws -> KubeConfigSet {
        try KubeConfigSet.load(files)
    }

    func change(_ edit: (inout KubeConfigSet) throws -> Void) async throws {
        var config = try loadConfigSet()
        try edit(&config)
        try config.save()
        await reload()
        await checkAutomatically()
    }

    func setCurrentContext(_ name: String) async throws {
        try await change { $0.setCurrentContext(name) }
    }

    func deleteContext(_ name: String, pruneUnused: Bool, settings: AppSettingsStore) async throws {
        try await change { try $0.removeContext(name, pruneUnused: pruneUnused) }
        settings.moveContext(name, to: nil)
    }

    func revealInFinder(_ context: String) {
        guard let url = file(for: context) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url.resolvingSymlinksInPath()])
    }
}
