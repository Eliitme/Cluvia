# Cluvia

Native macOS app for working with Kubernetes clusters.

Requires macOS 14+, Xcode 26+.

## Layout

```
Cluvia/              SwiftUI app target
Packages/KubeKit/    kubeconfig, auth, transport (no kubectl required)
Packages/HelmKit/    optional helm CLI integration
project.yml          Xcode project definition (XcodeGen)
```

## Build

```sh
brew install xcodegen
xcodebuild -downloadComponent MetalToolchain   # once; the terminal renderer ships Metal shaders
xcodegen generate
open Cluvia.xcodeproj                          # trust the SwiftTerm build plugin when Xcode asks
```

Command-line builds need `-skipPackagePluginValidation` for the same plugin:

```sh
xcodebuild -project Cluvia.xcodeproj -scheme Cluvia -skipPackagePluginValidation build
```

`Cluvia.xcodeproj` is generated and not committed; edit `project.yml` instead.

## Tests

```sh
cd Packages/KubeKit && swift test
cd Packages/HelmKit && swift test
```

Integration tests run against a real cluster when `CLUVIA_IT_CONTEXT` names a kubeconfig context:

```sh
kind create cluster --name cluvia-dev
cd Packages/KubeKit
CLUVIA_IT_CONTEXT=kind-cluvia-dev swift test
# long watch check (default 20s)
CLUVIA_IT_CONTEXT=kind-cluvia-dev CLUVIA_IT_WATCH_SECONDS=310 swift test --filter watchStreamStaysOpen
```

The integration suite creates a `cluvia-it-echo` busybox pod in `default` and objects in the `cluvia-it` namespace.

Opt-in checks:

```sh
# API server restart recovery (kind only; restarts the node container, run it alone)
CLUVIA_IT_CONTEXT=kind-cluvia-dev CLUVIA_IT_DISRUPT=1 swift test --filter recoversAfterApiServerRestart
# memory of 5 idle shells + 5 port-forwards
CLUVIA_IT_CONTEXT=kind-cluvia-dev CLUVIA_IT_FOOTPRINT=1 swift test -c release --filter StreamingFootprint
# 5k-pod list/memory budget against a namespace holding ~5000 pods
CLUVIA_IT_CONTEXT=kind-cluvia-dev CLUVIA_IT_SCALE_NAMESPACE=cluvia-scale swift test -c release --filter WatchCacheScale
```
