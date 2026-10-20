import KubeKit
import SwiftUI

/// What the main window's sidebar can select: a cluster, or one of its resource kinds or Helm releases.
enum SidebarItem: Hashable {
    case context(String)
    case kind(String, ResourceKind)
    case helm(String)
}

/// One line of the sidebar. The tree is flattened into rows with stable ids (indentation and chevrons are drawn by
/// hand): a nested outline of disclosure groups redraws unreliably while counts and connection state change,
/// leaving stale rows on screen.
enum SidebarRow: Identifiable {
    case context(ContextSummary, expanded: Bool)
    case category(String, ResourceCategory, ClusterSession)
    case kind(String, ResourceKind, ClusterSession)
    case helm(String)

    var id: String {
        switch self {
        case let .context(context, _): "c:\(context.name)"
        case let .category(name, category, _): "g:\(name):\(category.rawValue)"
        case let .kind(name, kind, _): "k:\(name):\(kind.id)"
        case let .helm(name): "h:\(name)"
        }
    }

    /// Rows for contexts in order; a connected, expanded cluster lists its groups, and open groups their kinds.
    @MainActor static func rows(for contexts: [ContextSummary], sessions: [String: ClusterSession], expanded: Set<String>) -> [SidebarRow] {
        var rows: [SidebarRow] = []
        for context in contexts {
            let session = sessions[context.name]
            let open = expanded.contains(context.name) && session?.state == .connected
            rows.append(.context(context, expanded: open))
            guard open, let session else { continue }
            for category in ResourceCategory.allCases {
                let kinds = session.kinds.filter { $0.category == category }
                guard !kinds.isEmpty else { continue }
                rows.append(.category(context.name, category, session))
                if session.expandedCategories.contains(category) {
                    rows += kinds.map { .kind(context.name, $0, session) }
                }
            }
            rows.append(.helm(context.name))
        }
        return rows
    }
}

/// Group and kind rows under a cluster. Context rows are drawn by `ContextRow`.
struct SidebarChildRow: View {
    let row: SidebarRow

    var body: some View {
        switch row {
        case let .category(_, category, session):
            let open = session.expandedCategories.contains(category)
            HStack(spacing: 6) {
                Chevron(open: open)
                Label(category.rawValue, systemImage: category.symbol)
                Spacer()
            }
            .padding(.leading, 14)
            .contentShape(Rectangle())
            .onTapGesture {
                if open { session.expandedCategories.remove(category) } else { session.expandedCategories.insert(category) }
            }
        case let .kind(name, kind, session):
            let count = session.counts[kind.gvr]
            HStack {
                Text(kind.title).lineLimit(1)
                Spacer()
                if let count { Text("\(count)").monospacedDigit().foregroundStyle(.secondary).font(.callout) }
            }
            .padding(.leading, 46)
            // Empty kinds recede so the ones with objects stand out.
            .opacity(count == 0 ? 0.45 : 1)
            .help(kind.category == .customResources ? "\(kind.kind) (\(kind.gvr.groupVersion))" : kind.kind)
            .tag(SidebarItem.kind(name, kind))
        case let .helm(name):
            Label("Helm Releases", systemImage: "shippingbox.fill")
                .padding(.leading, 32)
                .tag(SidebarItem.helm(name))
        case .context:
            EmptyView()
        }
    }
}

struct Chevron: View {
    let open: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(open ? 90 : 0))
            .frame(width: 12)
    }
}
