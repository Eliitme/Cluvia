import Foundation
import Testing
@testable import Cluvia

struct ReleaseNotesTests {
    static let changelog = """
    # Changelog

    ## [0.2.0](https://github.com/Eliitme/Cluvia/compare/v0.1.0...v0.2.0) (2026-11-02)


    ### Features

    * **logs:** highlight errors ([abc1234](https://github.com/Eliitme/Cluvia/commit/abc1234))
    * paste kubeconfig ([#12](https://github.com/Eliitme/Cluvia/issues/12)) ([def5678](https://github.com/Eliitme/Cluvia/commit/def5678))

    ### Bug Fixes

    * keep the header at the top ([0123456](https://github.com/Eliitme/Cluvia/commit/0123456))

    ## 0.1.0 (2026-10-21)

    ### Features

    * first release ([89abcde](https://github.com/Eliitme/Cluvia/commit/89abcde))
    """

    @Test func parsesReleasePleaseChangelog() throws {
        let notes = ReleaseNotes(markdown: Self.changelog)
        #expect(notes.releases.map(\.version) == ["0.2.0", "0.1.0"])
        let latest = try #require(notes.release("0.2.0"))
        #expect(latest.date == "2026-11-02")
        #expect(latest.sections.map(\.title) == ["Features", "Bug Fixes"])
        #expect(latest.sections[0].items == [
            "**logs:** highlight errors",
            "paste kubeconfig ([#12](https://github.com/Eliitme/Cluvia/issues/12))",
        ])
        #expect(notes.release("0.1.0")?.date == "2026-10-21")
    }

    @Test func whatsNewShowsOnceAfterAnUpdateAndNeverOnFirstInstall() throws {
        let defaults = try #require(UserDefaults(suiteName: "ReleaseNotesTests-\(UUID().uuidString)"))
        let notes = ReleaseNotes(markdown: Self.changelog)
        #expect(WhatsNew.releaseToShow(defaults: defaults, notes: notes, version: "0.1.0") == nil)
        #expect(WhatsNew.releaseToShow(defaults: defaults, notes: notes, version: "0.2.0")?.version == "0.2.0")
        #expect(WhatsNew.releaseToShow(defaults: defaults, notes: notes, version: "0.2.0") == nil)
    }
}
