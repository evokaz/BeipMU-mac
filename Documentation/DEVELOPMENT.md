# Development and testing

## Prerequisites

- macOS 14 or later
- Xcode 26 and its command-line tools
- Swift 6.2
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Python 3

The package uses only Apple frameworks and local targets; there are no remote
Swift package dependencies.

Check the selected tools with:

```sh
xcodebuild -version
swift --version
xcodegen --version
python3 --version
```

## Sources of truth

- `Package.swift` owns package modules, products, framework links, and package
  test targets.
- `project.yml` owns the application, embedded XPC service, UI test bundle,
  bundle identifiers, versions, deployment target, and Xcode build settings.
- `BeipMU.xcodeproj` is generated output. Regenerate it after changing
  `project.yml` or Xcode target composition.

Generate the project with:

```sh
./Scripts/generate-project.sh
```

## Correctness verification

Run all Swift package tests:

```sh
./Scripts/test.sh
```

The wrapper first verifies that the checked-in Milestone 10 scale fixtures
match `Scripts/generate-m10-fixtures.py`, then runs the complete suite with a
local module cache and explicit `--no-parallel`. This is the deterministic
correctness gate: it has no retry behavior and no hardware-speed budgets.
Functional deadlines are generous hang protection around observable state.
To intentionally regenerate the fixtures:

```sh
python3 Scripts/generate-m10-fixtures.py
./Scripts/test.sh
```

For a release candidate, require ten consecutive clean serial runs on both a
faster and a slower supported Mac.

## Parallel stress and isolation

Run the complete correctness suite repeatedly with four parallel workers:

```sh
./Scripts/test-stress.sh
```

This lane defaults to three iterations and looks for races, shared-state leaks,
temporary-file collisions, listener lifecycle bugs, and AppKit isolation
failures. It contains no performance thresholds. Its controls are:

| Variable | Default | Meaning |
| --- | ---: | --- |
| `BEIPMU_STRESS_ITERATIONS` | `3` | Number of complete parallel suite runs |
| `BEIPMU_STRESS_WORKERS` | `4` | Swift test worker count |

Use `Scripts/test.sh`, not this stress lane, as the required correctness gate.

Build the complete application and embedded XPC service:

```sh
./Scripts/generate-project.sh
xcodebuild -project BeipMU.xcodeproj -scheme BeipMU \
  -configuration Debug -derivedDataPath DerivedData build
```

## Test suites

| Suite | Main coverage |
| --- | --- |
| `BeipCoreTests` | Rendered lines, layout indexing, GMCP, media, WebViews |
| `BeipProtocolsTests` | Telnet, decoding, MCP, network/TLS resilience, connection scale |
| `BeipPersistenceTests` | Lossless config, backup recovery, crash journals, Atlas, scale |
| `BeipAutomationTests` | Matching, aliases, triggers, macros, commands, delays |
| `BeipScriptRuntimeTests` | JavaScript host API, XPC watchdog and recovery |
| `BeipUITests` | AppKit controllers, preferences, virtualization, live propagation |
| `BeipMUXCUITests` | Launched-app workflows, accessibility, screenshots, scale |

Run the launched-app UI suite after generating the Xcode project:

```sh
./Scripts/test-ui.sh
```

To update screenshot baselines intentionally:

```sh
BEIPMU_RECORD_BASELINES=1 ./Scripts/test-ui.sh
```

Review every changed PNG under `UITests/Baselines/`; baseline recording should
not be used merely to hide an unexpected visual regression.

Debug application builds use
`~/Library/Application Support/BeipMU-Debug/`, keeping developer profiles,
preferences, and `Recovery.dat` separate from the release app. XCUITests and
the full-app soak provide their own temporary state directory and `UserDefaults`
suite; do not point those overrides at the release directory.

Set `BEIPMU_EVIDENCE_DIR` to a new, nonexistent directory when UI, benchmark,
or soak artifacts must be retained. The scripts refuse to mix results into an
existing evidence subdirectory.

## Controlled performance verification

Absolute throughput, resident-memory, paint-candidate, and leak budgets are
enforced only by the release benchmark and full AppKit soak on designated
reference hardware. They are intentionally absent from ordinary XCTest runs.

Run the standalone workspace benchmark:

```sh
./Scripts/benchmark-workspace.sh
```

Its default resident-memory ceiling is 128 MiB. Override it only for an
intentional experiment with `BEIPMU_BENCHMARK_MAX_RSS_BYTES`.

Run the full AppKit output soak under Instruments and `leaks`:

```sh
./Scripts/profile-app-soak.sh
```

Defaults are 50,000 appended lines, a 10,000-line retained history, a 10-second
hold, and a 256 MiB resident-memory ceiling. The relevant controls are:

| Variable | Default | Meaning |
| --- | ---: | --- |
| `BEIPMU_APP_SOAK_LINES` | `50000` | Lines appended during the Instruments run |
| `BEIPMU_APP_SOAK_HISTORY_LIMIT` | `10000` | Expected bounded retained history |
| `BEIPMU_APP_SOAK_HOLD_SECONDS` | `10` | Hold before the app reports completion |
| `BEIPMU_APP_SOAK_MAX_RSS_BYTES` | `268435456` | Maximum allowed resident size |
| `BEIPMU_APP_LEAK_LINES` | `10000` | Lines appended during the leak scan |
| `BEIPMU_KEEP_APP_SOAK_ARTIFACTS` | `0` | Preserve temporary artifacts when set to `1` |

The verifier also requires no more than 200 paint candidates and rejects
unknown or app-owned leaks.

On other supported Macs, use report-only mode to collect the same timing,
throughput, paint, and RSS measurements without enforcing machine-dependent
speed or memory ceilings:

```sh
BEIPMU_PERFORMANCE_REPORT_ONLY=1 ./Scripts/benchmark-workspace.sh
BEIPMU_PERFORMANCE_REPORT_ONLY=1 ./Scripts/profile-app-soak.sh
```

Report-only mode still verifies structural correctness such as bounded
retention, soak completion, trace validity, and app-owned leak detection.

## Release verification

Create the default universal ZIP:

```sh
./Scripts/package-release.sh
```

Create a DMG or both formats:

```sh
./Scripts/package-release.sh --format dmg
./Scripts/package-release.sh --format both
```

The script regenerates the project, performs a Release build, applies an ad hoc
signature, and writes each artifact plus its SHA-256 file to `dist/`. It also
places `Documentation/DISTRIBUTION.md` in archives as `INSTALL.md`.

Before publishing, run package tests, app build, XCUITests, both performance
checks, and a clean-machine installation check. Distribution policy and user
instructions live in [DISTRIBUTION.md](DISTRIBUTION.md).

## Concurrency and platform boundaries

The Xcode targets enable complete Swift concurrency checking. Keep network,
session, trigger, delay, and scripting state actor-isolated. AppKit work must
remain on the main actor, while portable modules should not import AppKit.

When adding a feature, prefer a typed value or outcome in a lower module and a
small UI adapter in `BeipUI`. Add focused package tests at the owning layer,
then add an XCUITest only when the behavior depends on full application
composition or visual/accessibility state.
