import Foundation
import Yams

extension KubeConfigSet {
    /// Removes a context; with `pruneUnused`, also its cluster and user when no other context in any file uses them.
    public mutating func removeContext(_ name: String, pruneUnused: Bool) throws {
        guard let index = owner(.contexts, name) else { throw KubeConfigEditError.notFound(section: "context", name: name) }
        let cluster = field(.contexts, name, "cluster")
        let user = field(.contexts, name, "user")
        modify(index) { $0.remove(.contexts, name) }
        for (i, document) in documents.enumerated() where document.currentContext == name {
            modify(i) { $0.currentContext = nil }
        }
        guard pruneUnused else { return }
        if let cluster, contexts(referencing: .clusters, cluster).isEmpty, let owner = owner(.clusters, cluster) {
            modify(owner) { $0.remove(.clusters, cluster) }
        }
        if let user, contexts(referencing: .users, user).isEmpty, let owner = owner(.users, user) {
            modify(owner) { $0.remove(.users, user) }
        }
    }

    /// Copies contexts with their clusters and users into the primary file. Names already in effect (in any file)
    /// conflict unless `replaceExisting`. Relative file references and plugin paths are made absolute against the
    /// source's directory, since they would otherwise resolve against the target file.
    public mutating func importContexts(_ names: [String], from source: KubeConfigDocument, replaceExisting: Bool) throws {
        let clusters = Set(names.compactMap { source.field(.contexts, $0, "cluster") })
        let users = Set(names.compactMap { source.field(.contexts, $0, "user") })
        let wanted: [(KubeConfigSection, Set<String>)] = [(.contexts, Set(names)), (.clusters, clusters), (.users, users)]
        if !replaceExisting {
            let conflicts = wanted.flatMap { section, set in set.intersection(self.names(in: section)).sorted() }
            guard conflicts.isEmpty else { throw KubeConfigEditError.nameConflicts(conflicts) }
        }
        let base = source.url.resolvingSymlinksInPath().deletingLastPathComponent()
        let absolute = { (path: String) in path.hasPrefix("/") ? path : base.appendingPathComponent(path).standardizedFileURL.path }
        for (section, set) in wanted {
            for name in set.sorted() {
                guard var body = source.body(section, name) else { continue }
                for key in ["certificate-authority", "client-certificate", "client-key", "tokenFile"] {
                    if let path = body[key]?.string, !path.isEmpty { body[key] = .str(absolute(path)) }
                }
                if var exec = body["exec"]?.mapping, let command = exec["command"]?.string, command.contains("/") {
                    exec["command"] = .str(absolute(command))
                    body["exec"] = .mapping(exec)
                }
                modify(primary) { $0.setBody(section, name, body) }
            }
        }
    }
}
