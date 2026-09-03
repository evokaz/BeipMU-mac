# BeipMU for Mac

BeipMU is a native macOS client for MUDs and other MU* servers. It combines a
multi-window AppKit workspace with Telnet and MUD protocol support, profile and
automation editors, JavaScript scripting, maps, media, logging, and diagnostic
tools.

This project is a native macOS reimplementation of
[BeipMU](https://github.com/BeipDev/BeipMU), the Windows MU* client created by
Bennet. It aims to preserve compatibility with BeipMU's configuration format
and core functionality while providing a native AppKit interface.

This macOS reimplementation is maintained independently. Please report issues
with BeipMU for Mac to this project rather than seeking support from the
original BeipMU Windows developer.

The current app targets macOS 14 or later. Releases are built as universal
macOS applications, although Apple silicon is the supported and tested
architecture; the Intel slice is currently untested.

> [!CAUTION]
> This project contains features that have not been fully tested. Keep backups
> of important configuration and use the client with appropriate caution.

## Highlights

- Native AppKit windows, tabs, split sidebars, dockable tools, scoped display
  settings, themes, keyboard customization, and accessibility-aware behavior.
- Telnet negotiation, GMCP, MCP, Pueblo, ANSI/256/true color, NAWS, TLS, and
  multiple text encodings.
- Worlds, characters, and puppets backed by a lossless BeipMU v331-compatible
  `Config.txt` workspace.
- Scoped aliases, triggers, macros, variables, delayed commands, spawn windows,
  and automation diagnostics.
- JavaScriptCore scripting in an XPC service with a watchdog/reset boundary.
- Atlas maps, WebViews, images, audio, speech, session logging, Restore Logs,
  connection statistics, and network debugging.
- Virtualized output with dedicated scale, UI, performance, and leak checks.

## Build the app

You need:

- macOS 14 or later
- Xcode 26 with Swift 6.2
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Python 3 for fixture, UI-baseline, and verification scripts

Depending on the active developer directory, you may need to select Xcode’s
command-line tools before building:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

Create a release build and a ZIP under `dist/`:

```sh
./Scripts/package-release.sh
```

The built application is also available at
`DerivedData/Build/Products/Release/BeipMU.app`. To create a DMG or both
archive formats, use `--format dmg` or `--format both`.

For day-to-day development:

```sh
./Scripts/generate-project.sh
./Scripts/test.sh
./Scripts/test-ui.sh
xcodebuild -project BeipMU.xcodeproj -scheme BeipMU \
  -configuration Debug -derivedDataPath DerivedData build
```

`BeipMU.xcodeproj` is generated from `project.yml`; edit the specification and
regenerate instead of treating the generated project as the source of truth.
`test.sh` is the complete deterministic package-test gate. During
scale-specific work, use the quicker focused lane:

```sh
./Scripts/test-scale.sh
```

It covers large-fixture, connection, rendering, and automation-editor scale
tests. The development guide also documents parallel stress, benchmark, soak,
and baseline-recording workflows.

## First run

1. Open BeipMU and choose **Connection → Connect…**.
2. Enter a host and port, or create a saved world and character in
   **Connection → Worlds & Characters…**.
3. Type server commands in the input field. Client-side commands begin with
   `/`; use `/help` for the built-in list and `//text` to send text beginning
   with a slash.

BeipMU stores its live configuration in
`~/Library/Application Support/BeipMU/`. The portable `Config.txt` format may
contain character passwords in plaintext, while the
Restore Logs journal can contain session output and typed input. Treat the
live data directory, automatic backup, and exported copies as sensitive.

See the [user guide](Documentation/USER_GUIDE.md) for profiles, automation,
scripting, logs, and data locations.

## Project layout

| Path | Responsibility |
| --- | --- |
| `App/` | Minimal application entry point and asset catalog |
| `ScriptService/` | Embedded XPC service hosting JavaScriptCore |
| `Sources/BeipCore/` | Shared models, session actor, output history, logging, media, and GMCP state |
| `Sources/BeipProtocols/` | Network transport and Telnet/ANSI/MCP/Pueblo pipeline |
| `Sources/BeipAutomation/` | Aliases, triggers, macros, matching, delays, and slash commands |
| `Sources/BeipPersistence/` | Lossless configuration, Restore Logs, sidecar state, and Atlas files |
| `Sources/BeipScriptRuntime/` | JavaScript host API and XPC client contract |
| `Sources/BeipUI/` | AppKit application, workspace, editors, tools, and rendering |
| `Tests/` | Swift package unit, integration, resilience, scale, and performance tests |
| `UITests/` | XCUITest flows and screenshot baselines |
| `Benchmarks/` | Standalone output-workspace benchmark |
| `Scripts/` | Project generation, tests, profiling, fixtures, and release packaging |

The [architecture guide](Documentation/ARCHITECTURE.md) explains how these
modules interact. The [development guide](Documentation/DEVELOPMENT.md) covers
the complete verification workflow.

## Documentation

- [User guide](Documentation/USER_GUIDE.md)
- [Atlas mapping guide](Documentation/MAPPING.md)
- [Architecture](Documentation/ARCHITECTURE.md)
- [Development and testing](Documentation/DEVELOPMENT.md)
- [Distribution and installation](Documentation/DISTRIBUTION.md)

## License

BeipMU is available under the [MIT License](LICENSE).
