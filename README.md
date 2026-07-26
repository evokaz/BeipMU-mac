# BeipMU for Mac

A native macOS MU* client targeting macOS 14 and later. The application is
distributed directly as an ad-hoc-signed universal archive; Apple silicon is
the supported architecture and the Intel slice is untested and unsupported.

## Build and test

```sh
swift test
./Scripts/test-ui.sh
./Scripts/profile-app-soak.sh
xcodegen generate
xcodebuild -project BeipMU.xcodeproj -scheme BeipMU \
  -configuration Debug -derivedDataPath DerivedData build
```

Run `Scripts/package-release.sh` after a Release build to create the direct
download ZIP and SHA-256 checksum. Releases are intentionally not notarized.

## Included functionality

The app includes native AppKit workspace and docking, profiles and lossless
legacy configuration editing, Telnet/GMCP/MCP/Pueblo/ANSI processing,
aliases/macros/triggers, JavaScriptCore scripting, Atlas maps, media, WebViews,
logging, accessibility accommodations, notifications, diagnostics, and
performance-tested output virtualization.

The local test suite covers protocol parsing, persistence round trips,
automation, scripting, WebView/media resilience, accessibility-facing UI,
large-workspace scale, performance, and release packaging.

## Distribution

See `Documentation/DISTRIBUTION.md` for installation, signing, supported
architectures, and shared `Config.txt` password warnings. Release highlights
are in `Documentation/RELEASE_NOTES.md`.
