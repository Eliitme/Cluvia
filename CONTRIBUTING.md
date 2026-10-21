# Contributing to Cluvia

Thanks for helping make Cluvia better! Bug reports, ideas, docs fixes and code are all welcome.

By contributing you agree that your contribution is licensed under the project's
[PolyForm Noncommercial 1.0.0](LICENSE) license, and you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Ways to help

- **Report a bug** with the [bug report form](https://github.com/Eliitme/Cluvia/issues/new?template=bug_report.yml).
  Include your macOS version, Cluvia version and, if you can, the Kubernetes version and how you authenticate
  (client certificate, token, credential plugin). Never paste tokens, keys or kubeconfig secrets.
- **Suggest a feature** with the [feature request form](https://github.com/Eliitme/Cluvia/issues/new?template=feature_request.yml).
- **Ask a question** in [Discussions](https://github.com/Eliitme/Cluvia/discussions).
- **Report a security issue** privately, as described in [SECURITY.md](SECURITY.md).

## Development setup

Requirements: macOS 14 or later, Xcode 26 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodebuild -downloadComponent MetalToolchain   # once; the terminal renderer ships Metal shaders
xcodegen generate                              # Cluvia.xcodeproj is generated, never committed
open Cluvia.xcodeproj                          # trust the SwiftTerm build plugin when Xcode asks
```

Command-line builds need `-skipPackagePluginValidation` for the same plugin:

```sh
xcodebuild -project Cluvia.xcodeproj -scheme Cluvia -skipPackagePluginValidation build
```

Edit `project.yml`, not the generated project.

### Layout

```
Cluvia/              SwiftUI app (sidebar, resource browser, detail panel, logs, terminal, Helm)
CluviaTests/         app unit tests
Packages/KubeKit/    kubeconfig, auth, transport, watch cache, exec/port-forward (no kubectl needed)
Packages/HelmKit/    optional helm CLI integration
Brand/               logo, app icon and palette
scripts/             release packaging and app icon rendering
```

## Tests

```sh
cd Packages/KubeKit && swift test --skip Integration
cd Packages/HelmKit && swift test
xcodebuild -project Cluvia.xcodeproj -scheme Cluvia -skipPackagePluginValidation test
```

Integration tests run against a real cluster when `CLUVIA_IT_CONTEXT` names a kubeconfig context. They create a
`cluvia-it-echo` pod in `default` and objects in the `cluvia-it` namespace, so use a throwaway cluster:

```sh
kind create cluster --name cluvia-dev
cd Packages/KubeKit
CLUVIA_IT_CONTEXT=kind-cluvia-dev swift test
```

Opt-in checks:

```sh
# API server restart recovery (kind only; restarts the node container, run it alone)
CLUVIA_IT_CONTEXT=kind-cluvia-dev CLUVIA_IT_DISRUPT=1 swift test --filter recoversAfterApiServerRestart
# memory of 5 idle shells + 5 port-forwards
CLUVIA_IT_CONTEXT=kind-cluvia-dev CLUVIA_IT_FOOTPRINT=1 swift test -c release --filter StreamingFootprint
# 5k-pod list/memory budget against a namespace holding ~5000 pods
CLUVIA_IT_CONTEXT=kind-cluvia-dev CLUVIA_IT_SCALE_NAMESPACE=cluvia-scale swift test -c release --filter WatchCacheScale
```

CI (`.github/workflows/ci.yml`) runs the unit tests and the app build on every push and pull request.
`.github/workflows/integration.yml` runs the cluster suites on a self-hosted macOS runner with Docker.

## Pull requests

1. Fork the repository and branch off `main` (`feat/…`, `fix/…`).
2. Keep changes focused; one topic per pull request.
3. Follow the existing style: Swift 6 strict concurrency, small files (under ~200 lines), comments that explain
   *why* rather than *what*.
4. Add or update tests for behavior changes, and make sure the commands above pass.
5. Use [Conventional Commits](https://www.conventionalcommits.org/) for commit messages, e.g.
   `fix: keep the detail header at the top`.
6. Fill in the pull request template, including screenshots for UI changes.

Changes that touch the user's kubeconfig must keep fields Cluvia does not model, back up the file before writing,
and never log or display credentials.

## Releases

Versions follow [Semantic Versioning](https://semver.org/) and are tagged `vMAJOR.MINOR.PATCH`
(pre-releases: `v0.3.0-beta.1`). They are derived from commit messages, so use Conventional Commits:

| Commit | Bump (before 1.0) | Bump (from 1.0) |
|---|---|---|
| `fix: …` | patch | patch |
| `feat: …` | minor | minor |
| `feat!: …` or a `BREAKING CHANGE:` footer | minor | major |

Only `feat`, `fix`, `perf` and `revert` appear in the changelog; `docs`, `chore`, `ci`, `test`, `refactor`
and `build` do not.

How a release happens ([`.github/workflows/release.yml`](.github/workflows/release.yml)):

1. On every push to `main`, [release-please](https://github.com/googleapis/release-please) keeps a
   "chore(main): release X.Y.Z" pull request up to date. It bumps `MARKETING_VERSION` in `project.yml` and adds the
   release to `CHANGELOG.md`; edit the notes in that pull request if needed.
2. Merging it tags `vX.Y.Z` and creates the GitHub Release.
3. The build job archives the app, signs it with Developer ID, notarizes and staples it, and attaches
   `Cluvia-X.Y.Z.dmg` and its `.sha256` to the release.
4. The homebrew job updates the version and checksum in the
   [Homebrew cask](https://github.com/Eliitme/homebrew-tap/blob/main/Casks/cluvia.rb).

`CHANGELOG.md` is bundled into the app: it shows "What's New" once after an update and lists every release under
**Help › Release Notes**.

### Signing secrets

Add these under **Settings › Secrets and variables › Actions**. Without the certificate, the workflow still publishes
an ad-hoc signed DMG that Gatekeeper asks users to approve; without the notary key, the DMG is signed but not
notarized.

| Secret | Value |
|---|---|
| `DEVELOPER_ID_CERTIFICATE_P12` | "Developer ID Application" certificate and key exported from Keychain Access as `.p12`, base64-encoded: `base64 -i cert.p12 \| pbcopy` |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password chosen when exporting the `.p12` |
| `DEVELOPMENT_TEAM` | Apple team ID |
| `NOTARY_API_KEY_P8` | Contents of an App Store Connect API key (`AuthKey_XXXX.p8`, Developer role) |
| `NOTARY_API_KEY_ID` | That key's ID |
| `NOTARY_API_ISSUER_ID` | Issuer ID shown on the App Store Connect API keys page |
| `HOMEBREW_TAP_TOKEN` | Fine-grained token with **Contents: Read and write** on `Eliitme/homebrew-tap`, used to point the cask at each new release (optional) |

To rebuild the assets of an existing release, run the Release workflow manually with its tag.

### Building a release locally

```sh
DEVELOPMENT_TEAM=<team id> NOTARY_PROFILE=<notarytool keychain profile> scripts/build-release.sh
```

Produces `build/release/Cluvia-<version>.dmg` and its `.sha256`, signed with a Developer ID, notarized and stapled.
`SKIP_NOTARIZE=1` signs without notarizing; `UNSIGNED=1` builds an ad-hoc signed DMG. Signing material stays in the
keychain; nothing secret lives in the repository.
