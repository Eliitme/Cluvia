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

```sh
DEVELOPMENT_TEAM=<team id> NOTARY_PROFILE=<notarytool keychain profile> scripts/build-release.sh
```

Produces `build/release/Cluvia-<version>.dmg`, signed with a Developer ID, notarized and stapled
(`SKIP_NOTARIZE=1` signs and packages without notarizing). Signing material stays in the keychain; nothing secret
lives in the repository.
