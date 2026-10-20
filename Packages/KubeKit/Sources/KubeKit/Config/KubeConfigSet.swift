import Foundation

/// Every kubeconfig file in effect (the `KUBECONFIG` list or `~/.kube/config`), edited together with kubectl's
/// rules: the first file defining a name owns it, so edits go to that file; new entries go to the first existing
/// file; `current-context` lives in the first file that sets one. Only files that changed are written.
public struct KubeConfigSet {
    public private(set) var documents: [KubeConfigDocument]
    private var dirty: Set<Int> = []

    public static func load(_ urls: [URL]) throws -> KubeConfigSet {
        var seen = Set<String>()
        let unique = urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
        guard !unique.isEmpty else { throw KubeConfigEditError.missingValue("A kubeconfig file") }
        return KubeConfigSet(documents: try unique.map(KubeConfigDocument.load))
    }

    init(documents: [KubeConfigDocument]) {
        self.documents = documents
    }

    /// Where new entries are written: the first file that exists, else the first in the list.
    public var primaryFile: URL { documents[primary].url }

    var primary: Int { documents.firstIndex(where: \.exists) ?? 0 }

    /// Index of the file whose definition of `name` is in effect.
    func owner(_ section: KubeConfigSection, _ name: String) -> Int? {
        documents.firstIndex { $0.names(in: section).contains(name) }
    }

    public func file(of section: KubeConfigSection, _ name: String) -> URL? {
        owner(section, name).map { documents[$0].url }
    }

    /// Names in effect across all files, in file order.
    public func names(in section: KubeConfigSection) -> [String] {
        var seen = Set<String>()
        return documents.flatMap { $0.names(in: section) }.filter { seen.insert($0).inserted }
    }

    public func field(_ section: KubeConfigSection, _ name: String, _ key: String) -> String? {
        owner(section, name).flatMap { documents[$0].field(section, name, key) }
    }

    /// Contexts (in any file) pointing at the given cluster or user.
    public func contexts(referencing section: KubeConfigSection, _ name: String) -> [String] {
        let key = section == .clusters ? "cluster" : "user"
        return names(in: .contexts).filter { field(.contexts, $0, key) == name }
    }

    public var currentContext: String? {
        documents.lazy.compactMap(\.currentContext).first
    }

    /// Sets `current-context` where kubectl reads it from: the first file that sets one, else the primary file.
    public mutating func setCurrentContext(_ name: String) {
        let index = documents.firstIndex { $0.currentContext != nil } ?? primary
        modify(index) { $0.currentContext = name }
    }

    mutating func modify(_ index: Int, _ change: (inout KubeConfigDocument) throws -> Void) rethrows {
        try change(&documents[index])
        dirty.insert(index)
    }

    /// Writes every changed file as one change: all are validated, locked and checked for outside changes before
    /// any is written, and files already written are restored if a later one fails. Returns the files written.
    @discardableResult
    public mutating func save() throws -> [URL] {
        let indices = dirty.sorted()
        let prepared = try indices.map { try documents[$0].prepared() }
        let saved = try KubeConfigFileWriter.withLocks(indices.map { documents[$0].url }) { () throws -> [KubeConfigDocument] in
            for index in indices { try documents[index].verifyUnchanged() }
            var saved: [KubeConfigDocument] = []
            do {
                for (index, data) in zip(indices, prepared) { saved.append(try documents[index].commit(data)) }
            } catch {
                for index in indices.prefix(saved.count) { documents[index].restoreOriginal() }
                throw error
            }
            return saved
        }
        for (index, document) in zip(indices, saved) { documents[index] = document }
        dirty.removeAll()
        return saved.map(\.url)
    }
}
