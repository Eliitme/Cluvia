import Foundation
import KubeKit
import Testing
@testable import HelmKit

struct HelmLocatorTests {
    @Test func resolvesHelmFromLoginShellWhenInstalled() async {
        let shell = LoginShellEnvironment(baseEnvironment: [
            "HOME": NSHomeDirectory(), "SHELL": ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", "PATH": "/usr/bin:/bin",
        ])
        let helm = await HelmLocator.helmExecutable(shell: shell)
        let installed = ["/opt/homebrew/bin/helm", "/usr/local/bin/helm"].contains { FileManager.default.isExecutableFile(atPath: $0) }
        // Finder-style minimal PATH must still find a Homebrew-installed helm via the login shell.
        if installed { #expect(helm != nil) }
        if let helm { #expect(FileManager.default.isExecutableFile(atPath: helm.path)) }
    }
}
