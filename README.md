# BeipMU for Mac

A native macOS reimplementation of the BeipMU MU* client. The project targets
macOS 14 and later on Apple silicon and Intel.

The Windows source at `../BeipMU-win` is a read-only behavioral reference. Do
not edit it, change its checkout, fetch into it, or push from it.

## Build and test

```sh
swift test
./Scripts/test-ui.sh
./Scripts/profile-app-soak.sh
xcodegen generate
xcodebuild -workspace BeipMU.xcodeproj/project.xcworkspace -scheme BeipMU \
  -configuration Debug -derivedDataPath DerivedData build
```

Run `Scripts/package-release.sh` after a Release build to create the direct
download ZIP and SHA-256 checksum. Releases are intentionally not notarized.

## Current state

Milestones 1 and 2 are complete. The executable parity specification,
headless connection engine, legacy persistence, Telnet/GMCP and ANSI/Pueblo
pipeline, command registry, and compatibility fixtures are covered by the
automated suite.

Milestone 3 is complete. The native AppKit client now has bounded and
pauseable output history, timestamp/tooltips, plain and regular-expression
find, styled link/send actions, plain/HTML copy, fan-fold backgrounds, unread
and Dock activity, plus multiline input with history, prefixes, sticky mode,
completion, spell checking, guarded multiline paste, `%R`/`%T`/`%B`
conversion tools, native secondary input/edit windows, and persisted
configurable shortcuts. Custom output
virtualization is now backed by a line-height index and a visible-range Core
Text view, with native selection/copy, split output, markers, wrapped indents,
blink handling, and asynchronous inline/animated assets. Native detachable
session tabs, four-side/floating panes, recursive split/tab workspace layouts
with saved divider proportions, character notes, diagnostics, tab
colors/muting, unread activity, and Dock badges are now wired. Profile
management now includes a native world/character/puppet editor, lossless
Config.txt add/edit/delete writeback, import/save/save-as/export workflows,
saved-profile connections, and selected-config restoration. Five isolated
XCUITests now cover the main workspace keyboard/accessibility path, a normalized
Windows-golden session, recursive Split Sidebars persistence, the theme dialog,
live connection statistics, and six checked-in visual baselines. A
checksum-pinned semantic audit maps the native macOS surfaces to both Windows
v331 captures. A reproducible Release-app Time Profiler/RSS/leak gate exercises
50,000 styled lines through the real workspace. System/light/dark/custom themes now apply
across the workspace, and native logging controls drive concurrent plain-text
or HTML logs with history, input, timestamps, and wrapping options.
Release throughput/RSS/leak budgets and Debug sustained-renderer lifecycle
checks are reproducible with `Scripts/benchmark-workspace.sh` and
`Scripts/profile-app-soak.sh`; native UI
comparisons run through `Scripts/test-ui.sh`.

This is an executable foundation rather than a parity release. Milestone status
is recorded in `Documentation/MILESTONES.md`; remaining compatibility work and
its required differential evidence are tracked in `Documentation/PARITY.md`.
