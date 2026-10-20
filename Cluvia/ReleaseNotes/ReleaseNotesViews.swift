import SwiftUI

/// One release: its sections (Features, Bug Fixes, …) as bulleted lists.
struct ReleaseView: View {
    let release: ReleaseNotes.Release

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(release.sections, id: \.title) { section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title).font(.headline)
                    ForEach(section.items, id: \.self) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(.secondary)
                            Text((try? AttributedString(markdown: item)) ?? AttributedString(item))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Help › Release Notes: every release in the bundled changelog.
struct ReleaseNotesWindow: View {
    private let notes = ReleaseNotes.bundled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if notes.releases.isEmpty {
                    ContentUnavailableView("No Release Notes Yet", systemImage: "doc.text",
                                           description: Text("Notes appear here once the first release is published."))
                }
                ForEach(notes.releases) { release in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Cluvia \(release.version)").font(.title2.weight(.semibold))
                            if release.version == ReleaseNotes.appVersion {
                                Text("Installed").font(.caption.weight(.medium)).foregroundStyle(Color.brandTeal)
                            }
                            Spacer()
                            if let date = release.date { Text(date).foregroundStyle(.secondary) }
                        }
                        ReleaseView(release: release)
                    }
                    Divider()
                }
            }
            .padding(24)
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}

/// Shown once after updating to a version with release notes.
struct WhatsNewSheet: View {
    let release: ReleaseNotes.Release
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image("BrandMark").resizable().scaledToFit().frame(width: 56)
                Text("What's New in Cluvia \(release.version)").font(.title2.weight(.semibold))
            }
            .padding(24)
            Divider()
            ScrollView { ReleaseView(release: release).padding(24) }
            Divider()
            HStack {
                Button("All Release Notes") { openWindow(id: "release-notes") }
                Spacer()
                Button("Continue") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 480)
    }
}

/// Help menu entry for the release notes window.
struct ReleaseNotesCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Release Notes") { openWindow(id: "release-notes") }
        }
    }
}
