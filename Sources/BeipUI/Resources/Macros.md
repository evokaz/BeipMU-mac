# Keyboard Macros

Keyboard macros use the portable Windows `Config.txt` key spelling. A macro
may use Control, Option, and Shift modifiers and can be bound to letters, digits,
function keys, arrows, navigation keys, Return, Tab, Escape, Space, editing
keys, or numeric-keypad keys. The underlying Windows-compatible Config.txt
format stores Option using the legacy `Alt` name.

The Description is shown in the tree. If it is empty, the tree displays the
shortcut; an empty shortcut is shown as `(No Key)`. Folders organize macros and
run their children in depth-first order without having a shortcut of their own.

`Type into Input Window` inserts the macro text into the current command input.
Otherwise each non-empty line is submitted to the active connection. Command
shortcuts are reserved by macOS and are not available to macros.

Apply commits the staged changes to the live configuration. OK applies and
closes the window. Cancel discards edits made since the last Apply.
