# BeipMU for Mac

A native macOS MU* client targeting macOS 14 and later. The application is
distributed directly as an ad-hoc-signed universal archive; Apple silicon is
the supported architecture and the Intel slice is untested and unsupported.

## Build and test

Building requires macOS 14 or later, Xcode 26 with Swift 6.2, and XcodeGen.
The complete test and profiling workflow also requires Python 3 for its fixture,
baseline, and verification scripts.

To compile a Release app for normal use, only run:

```sh
./Scripts/package-release.sh
```

The script generates the Xcode project, builds and ad-hoc signs the universal
Release app, and creates a ZIP and SHA-256 checksum under `dist`. The compiled
app is also available at `DerivedData/Build/Products/Release/BeipMU.app` and can
be launched from Finder. No separate Xcode build is required.

For development and local verification, generate the project before running
the Xcode-based build or test scripts:

```sh
./Scripts/generate-project.sh
./Scripts/test.sh
xcodebuild -project BeipMU.xcodeproj -scheme BeipMU \
  -configuration Debug -derivedDataPath DerivedData build
./Scripts/test-ui.sh
./Scripts/profile-app-soak.sh
```

Pass `--format dmg` to `Scripts/package-release.sh` for a DMG instead, or
`--format both` to create both formats. The default format is ZIP. Releases are
intentionally not notarized.

## Included functionality

The app includes native AppKit workspace and docking, profiles and lossless
legacy configuration editing, Telnet/GMCP/MCP/Pueblo/ANSI processing,
aliases/macros/triggers, JavaScriptCore scripting, Atlas maps, media, WebViews,
logging, accessibility accommodations, notifications, diagnostics, and
performance-tested output virtualization.

The local test suite covers protocol parsing, persistence round trips,
automation, scripting, WebView/media resilience, accessibility-facing UI,
large-workspace scale, performance, and release packaging.

> **Note:** Not all features have been fully tested. Use with appropriate caution.

## Distribution

See `Documentation/DISTRIBUTION.md` for installation, signing, supported
architectures, and plaintext configuration-backup password warnings. Release
highlights are in `Documentation/RELEASE_NOTES.md`.
