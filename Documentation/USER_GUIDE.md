# User guide

## Connect to a server

Use **Connection → Connect…** for a one-off connection. A connection needs a
host and a port; TLS, certificate verification, text encoding, MCP, Pueblo,
and other protocol options can be configured on a saved world.

For repeat connections, open **Settings…** and create this hierarchy:

```text
World
└── Character
    └── Puppet (optional)
```

A world holds connection and protocol settings. A character holds the login
command and character-specific behavior. A puppet routes matched server output
to its own session while communicating through its character connection.

The app restores open tab groups between launches. Quick Connect reuses an
already open matching profile when possible.

## Work with the workspace

Use the BeipMU menu for new tabs, windows, secondary input or edit windows,
input history, images, maps, and character notes. The Tools menu opens the
alias, trigger, and macro editors as well as their diagnostic windows.

Useful default shortcuts include:

| Action | Shortcut |
| --- | --- |
| New tab | Control-T |
| New window | Command-N |
| Toggle input history | Control-H |
| Edit triggers | Control-Shift-T |
| Edit aliases | Control-Shift-A |
| Edit macros | Control-Shift-M |
| Smart Paste | Control-Shift-V |
| Logging | Command-L |

Shortcuts can be customized and are saved in the macOS sidecar configuration.

## Client commands

Text beginning with `/` is handled as a client command. Type `/help` for the
authoritative command list in the running build. Quoted arguments may contain
spaces, and a backslash escapes the next character. Use `//` to send a literal
leading slash to the server.

Common commands include:

| Command | Purpose |
| --- | --- |
| `/connect host:port` | Connect directly to a server |
| `/disconnect` and `/reconnect` | Control the current connection; add `all` to affect all windows |
| `/clear` | Clear displayed output |
| `/recall count "text"` | Search recent output |
| `/repeat count "command"` | Repeat a command |
| `/delay 5s "command"` | Run a command later; time also accepts `m` and `h` |
| `/stats` and `/connectioninfo` | Show session and socket information |
| `/log filename` and `/stoplogs` | Start or stop session logging |
| `/set name=value`, `/unset name`, `/printenv` | Manage session variables |
| `/script JavaScript` or `/@ JavaScript` | Evaluate JavaScript |
| `/shelp` | Show scripting help |
| `/debugaliases`, `/debugtriggers`, `/debugnetwork` | Open diagnostic tools |
| `/new`, `/newtab`, `/newinput`, `/newedit` | Open workspace windows |

`/silent/<command>` suppresses informational output from a client command.
The exact syntax for advanced commands such as `/delay`, `/newedit`, `/naws`,
and `/webview` is available through `/help` and command-specific diagnostics.

## Automation and scripting

Aliases transform outgoing input. Triggers match incoming rendered lines and
can send commands, change presentation, gag or spawn output, update statistics,
play media, and call scripts. Macros bind configured key combinations to text
or commands. Automation can be scoped globally or to a world, character, or
puppet.

JavaScript runs in the embedded `BeipScriptService` XPC service. Each main
window communicates with the service through a host snapshot and a controlled
set of output operations. A three-second watchdog can abandon a stuck request;
resetting scripting creates a fresh XPC connection and runtime.

Scripts are trusted local automation. They can send and receive text, run
client commands, work with files and sounds through the exposed host API, and
open connections through supported scripting objects. Review imported scripts
before running them.

## Logging, media, and maps

- **Logging:** Open **Logging…** or use `/log`. Plain text and HTML output are
  supported, with optional history, timestamps, date-based names, and daily
  rollover.
- **Media:** MCP/GMCP media can display images, play audio, and speak text.
  Remote media URLs are restricted to HTTP and HTTPS.
- **Maps:** Atlas files preserve rooms, exits, shapes, images, labels, palettes,
  and unknown compatible XML content. Map commands can add rooms and exits or
  infer a location from recent output.
- **WebViews:** Server WebViews are controlled by the configured per-world
  policy. Review a world's policy before allowing server-initiated content.

## Configuration and backups

The app-owned data directory is:

```text
~/Library/Application Support/BeipMU/
├── Config.txt
├── Config.backup.txt
└── Config.mac.json
```

- `Config.txt` is the portable v331 configuration. The editor preserves
  comments, ordering, and unknown platform-specific fields while updating
  supported values.
- `Config.backup.txt` is the previous live configuration, written before an
  atomic update. If the live file cannot be restored, BeipMU attempts recovery
  from this backup.
- `Config.mac.json` stores Mac-only state such as customized shortcuts and
  restored tab groups.

The configuration manager can import or export `Config.txt`. Import is parsed
and projected before it replaces live state, so an invalid file is rejected.

> [!IMPORTANT]
> Character connection strings may include passwords in plaintext. The app
> does not store those passwords in Keychain. Protect `Config.txt`,
> `Config.backup.txt`, exported configurations, diagnostic bundles, and any
> release or cloud backup that contains them.

For transport security, enable TLS and leave certificate verification enabled.
Disabling certificate verification accepts any certificate and should only be
used for a server you understand and trust.
