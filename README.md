# BeipMU for Mac

A native macOS reimplementation of the BeipMU MU* client. The project targets
macOS 14 and later on Apple silicon and Intel.

The Windows source at `../BeipMU-win` is a read-only behavioral reference. Do
not edit it, change its checkout, fetch into it, or push from it.

## Build and test

```sh
swift test
xcodegen generate
xcodebuild -workspace BeipMU.xcodeproj/project.xcworkspace -scheme BeipMU \
  -configuration Debug -derivedDataPath DerivedData build
```

Run `Scripts/package-release.sh` after a Release build to create the direct
download ZIP and SHA-256 checksum. Releases are intentionally not notarized.

## Current state

The first vertical slice includes the module boundaries, immutable session
model, Telnet/GMCP and ANSI pipeline, lossless legacy configuration parser,
atlas reader, aliases/triggers, Network.framework transport, an AppKit client
window, a JavaScriptCore XPC service, and automated tests. This is an
executable foundation rather than a parity release: remaining work and its
required differential evidence are tracked in `Documentation/PARITY.md`.
