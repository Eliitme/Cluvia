import Foundation

/// Row shown in the cluster catalog; mirrors `kubectl config get-contexts`.
public struct ContextSummary: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let clusterName: String
    public let userName: String
    public let namespace: String?
    public let server: String?
    public let isCurrent: Bool
}

/// A context with its cluster and user looked up, ready to build a transport.
public struct ResolvedContext: Sendable {
    public let name: String
    public let clusterName: String
    public let cluster: Cluster
    public let userName: String
    public let user: AuthInfo
    public let namespace: String?
}

public enum KubeConfigError: Error, LocalizedError, Sendable, Equatable {
    case contextNotFound(String)
    case clusterNotFound(context: String, cluster: String)
    case userNotFound(context: String, user: String)

    public var errorDescription: String? {
        switch self {
        case let .contextNotFound(name): "Context \"\(name)\" not found in any kubeconfig"
        case let .clusterNotFound(context, cluster): "Context \"\(context)\" references missing cluster \"\(cluster)\""
        case let .userNotFound(context, user): "Context \"\(context)\" references missing user \"\(user)\""
        }
    }
}

/// Union of several kubeconfig files with kubectl's precedence: the first file defining a name wins,
/// and the first non-empty `current-context` wins.
public struct MergedKubeConfig: Sendable {
    public private(set) var clusters: [String: Cluster] = [:]
    public private(set) var users: [String: AuthInfo] = [:]
    public private(set) var contexts: [String: KubeContext] = [:]
    public private(set) var currentContext: String?

    public init(_ configs: [KubeConfig]) {
        for config in configs {
            for entry in config.clusters where clusters[entry.name] == nil { clusters[entry.name] = entry.cluster }
            for entry in config.users where users[entry.name] == nil { users[entry.name] = entry.user }
            for entry in config.contexts where contexts[entry.name] == nil { contexts[entry.name] = entry.context }
            if currentContext == nil { currentContext = config.currentContext }
        }
    }

    public var contextSummaries: [ContextSummary] {
        contexts.keys.sorted().map { name in
            let context = contexts[name]!
            return ContextSummary(
                name: name,
                clusterName: context.cluster,
                userName: context.user,
                namespace: context.namespace,
                server: clusters[context.cluster]?.server,
                isCurrent: name == currentContext
            )
        }
    }

    public func resolve(contextNamed name: String) throws -> ResolvedContext {
        guard let context = contexts[name] else { throw KubeConfigError.contextNotFound(name) }
        guard let cluster = clusters[context.cluster] else {
            throw KubeConfigError.clusterNotFound(context: name, cluster: context.cluster)
        }
        guard let user = users[context.user] else { throw KubeConfigError.userNotFound(context: name, user: context.user) }
        return ResolvedContext(
            name: name, clusterName: context.cluster, cluster: cluster,
            userName: context.user, user: user, namespace: context.namespace
        )
    }
}
