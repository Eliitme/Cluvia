import Foundation
import KubeKit

/// Finds the user's `helm` binary. Helm features are optional: when it is missing the UI hides them.
public enum HelmLocator {
    public static func helmExecutable(shell: LoginShellEnvironment = .shared) async -> URL? {
        await shell.resolveExecutable("helm")
    }
}
