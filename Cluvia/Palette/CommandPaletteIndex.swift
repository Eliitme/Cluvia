import Foundation
import KubeKit

struct PaletteItem: Identifiable {
    enum Command {
        case selectKind(ResourceKind)
        case selectNamespace(String?)
        case openContext(String)
        case reveal(ResourceKind, ObjectKey)
        case action(ResourceAction, ResourceKind, ObjectKey)
        case create(ResourceKind)
    }

    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let command: Command
}

/// Everything the palette can jump to or run, built from the session's current state.
@MainActor
enum CommandPaletteIndex {
    static let resultLimit = 60

    static func items(session: ClusterSession, contexts: [String]) -> [PaletteItem] {
        var items: [PaletteItem] = []
        if let selectedKind = session.selectedKind, let key = session.selectedObject {
            items += ResourceAction.available(for: selectedKind).map {
                PaletteItem(id: "action:\($0.rawValue)", title: "\($0.title(for: selectedKind).replacingOccurrences(of: "…", with: "")) \(key.name)",
                            subtitle: selectedKind.kind, symbol: $0.symbol, command: .action($0, selectedKind, key))
            }
        }
        items += session.kinds.map {
            PaletteItem(id: "kind:\($0.id)", title: $0.title, subtitle: $0.category.rawValue, symbol: $0.category.symbol, command: .selectKind($0))
        }
        if let kind = session.selectedKind {
            items.append(PaletteItem(id: "create", title: "New \(kind.kind)", subtitle: "Create from template", symbol: "plus", command: .create(kind)))
        }
        items.append(PaletteItem(id: "ns:all", title: "All Namespaces", subtitle: "Namespace", symbol: "square.stack.3d.up", command: .selectNamespace(nil)))
        items += session.namespaces.map {
            PaletteItem(id: "ns:\($0)", title: $0, subtitle: "Namespace", symbol: "square.stack.3d.up", command: .selectNamespace($0))
        }
        items += contexts.filter { $0 != session.contextName }.map {
            PaletteItem(id: "ctx:\($0)", title: $0, subtitle: "Open cluster", symbol: "server.rack", command: .openContext($0))
        }
        for (gvr, _, store) in session.registry?.activeStores ?? [] where gvr != .namespaces {
            guard let kind = session.kind(for: gvr) else { continue }
            items += store.items.map { row in
                PaletteItem(id: "obj:\(gvr):\(row.id)", title: row.object.name, subtitle: "\(kind.kind)\(row.object.namespace.map { " · \($0)" } ?? "")",
                            symbol: "doc.text", command: .reveal(kind, row.id))
            }
        }
        return items
    }

    static func search(_ query: String, in items: [PaletteItem]) -> [PaletteItem] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return Array(items.prefix(resultLimit)) }
        return items
            .compactMap { item in FuzzyMatcher.score(query, in: item.title).map { (item, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(resultLimit)
            .map(\.0)
    }
}
