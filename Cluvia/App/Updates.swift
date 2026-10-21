import Combine
import Sparkle
import SwiftUI

/// In-app updates through Sparkle: the feed (`SUFeedURL`) is the latest GitHub release's appcast.xml, and every
/// update must carry an EdDSA signature matching `SUPublicEDKey`. Sparkle asks the user on the second launch whether
/// to check automatically, then checks daily.
enum Updates {
    /// Off in Debug builds (an update would replace the development build) and until a signing key is configured.
    static var enabled: Bool {
        #if DEBUG
        return false
        #else
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        return !key.isEmpty && key != "PENDING"
        #endif
    }
}

/// Mirrors the updater's `canCheckForUpdates`, which is false while a check is already running.
@MainActor
final class CheckForUpdatesModel: ObservableObject {
    @Published private(set) var canCheck = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }
}

/// Cluvia › Check for Updates…
struct CheckForUpdatesCommand: View {
    let updater: SPUUpdater
    @ObservedObject var model: CheckForUpdatesModel

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!model.canCheck)
    }
}
