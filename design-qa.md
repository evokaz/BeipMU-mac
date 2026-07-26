**Source visual truth**

- `**REDACTED**`
- 1680 × 1471 pixels, Windows desktop Character Configuration state.

**Implementation**

- Native AppKit window at a 900 × 680 point content size.
- State: character selected, password hidden, idle behavior disabled.
- Automated control evidence: `ConfigurationManagerWindowControllerTests.testCharacterFormUsesAccessibleNativeControls`.
- Primary interactions checked in code and automated control inspection: character selection, password reveal control, idle enable state, and Apply Changes wiring.

**Findings**

- [P1] The first native capture showed vertically stretched Account and Connection Behavior cards whose contents overlapped.
  - Fix: the card content now uses an explicitly constrained container with required vertical hugging and compression resistance.
- [P2] The sidebar action row clipped the “+ World” button.
  - Fix: creation actions and removal now use two compact rows that fit the fixed-width sidebar.
- [P1] The second native capture showed the complete root split view shifted and compressed, with form controls escaping their cards.
  - Root cause: the root stack had replaced `window.contentView` and was then constrained to that same view, producing self-referential constraints.
  - Fix: the window now owns a separate content container with the root stack pinned to all four edges. Card content uses `NSBox` content margins and an explicit content-driven height.
- [P1] The later capture was structurally sound but still used grouped settings cards instead of the original window’s dense, flat Character form.
  - Fix: the Character pane now follows the original field order and flat presentation: Name, Password with Show, Connect String, Info, idle behavior, startup connection, log file, and date suffix.
  - Portable Info and automatic-log settings now round-trip through Config.txt instead of appearing as visual-only controls.
- The Windows information architecture has been retained for the portable character fields while being translated to BeipMU’s native macOS settings language.
- Typography uses the app’s existing system-font hierarchy; spacing uses the same 24–28 point page margins and 9–16 point control rhythm as nearby BeipMU settings windows.
- Colors use semantic AppKit tokens (`labelColor`, `secondaryLabelColor`, `separatorColor`, and `controlBackgroundColor`) so the screen follows the app’s current light/dark appearance.
- No raster imagery is present in the character detail pane. Profile icons continue to use the app’s existing SF Symbols treatment.
- Copy was adapted to describe BeipMU behavior and the supported portable fields. Windows-only statistics and unsupported character metadata were not fabricated.

**Open Questions**

- A browser-style screenshot comparison is not applicable to this native AppKit window.
- The desktop-control capture remained intercepted by an open macOS menu after the configuration window opened, so a clean rendered screenshot could not be captured for side-by-side comparison.

**Implementation Checklist**

- [x] Preserve editable character name, password, connect text, startup, and idle settings.
- [x] Add native grouped sections and app-consistent hierarchy.
- [x] Add multiline connect text and password reveal affordances.
- [x] Disable idle fields until idle behavior is enabled.
- [x] Add accessibility coverage for all character controls.
- [x] Pass the full Swift test suite and targeted UI-controller test.
- [ ] Capture the rebuilt native window to confirm the original-style flat form and full-width field sizing.

**Follow-up Polish**

- None recorded until a clean native capture is available.

final result: blocked
