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

Milestone 4 is complete, including hierarchical aliases, macros, triggers and
their portable v331 actions, deterministic delays, logging/autolog/restore,
native automation/debug panels, and the isolated JavaScriptCore runtime.

Milestone 5 is complete. Its first vertical slice adds incremental
`beip.stats`, `beip.id` avatars, typed `room.info`, Hex/Base64/compressed
tilemap decoding with zoomable native panes, `/tilemap`, and a native image
viewer. Its second slice adds rich standalone/grouped trigger spawns with
targeted clear, ShowTab/unread state, close/reorder, `/switchtab`, accessible
controls, and per-profile restoration. Its third slice turns `.atlas` into a
lossless read/write model and accessible native editor with every planned map
object, selection, pan/zoom, undo/redo/find, location tracking, path/speed-run,
`room.info`, per-profile view restoration, all four map commands, contextual
property editing, clipboard fragments, and PNG/PDF export. Its fourth
slice adds authenticated MCP 2.1 negotiation and bundled status/ping/client/
SimpleEdit packages, native SimpleEdit upload, profile-gated Client.Media
download/cache/play/loop/stop, `/mcmp`, `/silence`, and complete per-tab local
mute behavior. Its fifth slice adds `/webview`, per-world GMCP WebView policy,
validated URL/source/update/close requests, accessible native WebKit windows,
and the documented page client bridge with connection, text, alias, history,
display/capture, property, and GMCP callbacks. Its sixth slice
completes all 157 portable v331 scripting members: timers, DNS, native TCP
clients/listeners, live connection/window hooks, mutable rich lines, logging
and profile proxies, named inputs/spawn tabs, and accessible native
text/fixed/graphics windows. ActiveX/COM and HWND remain the two declared
Windows-only exceptions. Its seventh slice generalizes the recursive dock tree
for live WebViews and standalone/grouped spawns, adds safe per-world URL-pane
restoration, floating Dock controls and embedded Pop Out controls, selectable
speech voices, a native offline help window, and additional hostile-page,
clipboard, persistence, and accessibility tests. Windows advanced-surface
captures and the final release-wide audit remain. Its eighth slice completes
the portable debugger set, adds repair-capable `/restoreinfo`, honors native
contrast/non-color/transparency/motion settings, and adds deterministic
keyboard accessibility, seeded parser/persistence properties, concurrent and
fragmented fake-server sessions, and the signed universal release package.
Its ninth and final slice lands the two closing Windows gates on the
designated `win11-dev` VM: a successful Client.Media trace (real loopback
GMCP negotiation, composed default-URL WAV download with HTTP 200, and
`/mcmp info` showing the cached sound playing with its decoded duration) and
the release-wide replay corpus (`Tests/Golden/windows-v331-replay-*`) whose
fragmented-ANSI rendering, gag/spawn/send triggers, wire-level alias
expansion, Windows-written plain/HTML logs, `/@ SetOnReceive` callback
ordering, and post-session configuration save are replayed through the
portable engines by `WindowsReplayDifferentialTests`. All 230 Swift tests,
six XCUITests, six visual baselines, performance/leak gates, and 750
generated parity rows pass. Assisted VoiceOver/audio/device gates pass on the
latest Apple-silicon device, with macOS 14 Intel accepted as an explicit
assumption for this task.

This is an executable foundation rather than a parity release. Milestone status
is recorded in `Documentation/MILESTONES.md`; remaining compatibility work and
its required differential evidence are tracked in `Documentation/PARITY.md`.
The ordered working roadmap to the full-parity release is
`Documentation/PARITY_RELEASE_PLAN.md`.
