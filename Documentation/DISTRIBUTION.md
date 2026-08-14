# Installing and distributing BeipMU

## Supported systems

BeipMU requires macOS 14 or later. Release artifacts contain both Apple
silicon (`arm64`) and Intel (`x86_64`) slices. Apple silicon is the supported
and tested architecture; the Intel slice is currently untested and provided
without support.

Releases are distributed directly by the project as ad hoc-signed archives.
They are not signed with an Apple Developer ID and are not notarized by Apple.
There is no automatic updater.

BeipMU for Mac is an independent reimplementation. Support requests and bug
reports for this macOS application should be directed to this project, not to
the developer of the original BeipMU for Windows.

## Install from a ZIP

1. Verify the downloaded checksum as described below.
2. Expand `BeipMU-macOS-universal.zip`.
3. Drag `BeipMU.app` to the Applications folder.
4. Open the app. If macOS blocks the first launch, control-click the app in
   Finder, choose **Open**, and confirm that you want to open this specific
   copy. Depending on the macOS version, the corresponding **Open Anyway**
   control may appear in **System Settings → Privacy & Security**.

Do not disable Gatekeeper globally. If you did not obtain the archive from a
source you trust, do not override the warning.

For a DMG, verify its checksum, open it, and drag BeipMU to the Applications
shortcut before following the same first-launch procedure.

## Verify an artifact

Each release artifact has a neighboring `.sha256` file. Keep both files in the
same directory and run, for example:

```sh
shasum -a 256 -c BeipMU-macOS-universal.zip.sha256
```

For a DMG:

```sh
shasum -a 256 -c BeipMU-macOS-universal.dmg.sha256
```

A successful check prints `OK`. A checksum only proves that the artifact
matches the published digest; obtain the digest through a channel you trust.

## Application data and passwords

BeipMU stores its live data under:

```text
~/Library/Application Support/BeipMU/
```

The portable `Config.txt` format can include world addresses, character login
commands, passwords, AI endpoint settings, and automation in plaintext. Its
automatic `Config.backup.txt` and manually exported configurations contain the
same class of sensitive data. The Restore Logs file `Recovery.dat` can contain server output, sent
input, input history, and protocol state from interrupted sessions. Passwords
are not moved to macOS Keychain.

Before sharing a configuration, diagnostic collection, computer backup, or
user account, inspect and redact these files. Protect the entire application
data directory and its backups with encryption appropriate to their
destination.

Network connections are plaintext unless TLS is enabled for the world. Keep
certificate verification enabled for normal TLS connections.

Debug builds store their data separately under
`~/Library/Application Support/BeipMU-Debug/`; release builds do not use that
directory.

## Build release artifacts

Maintainers need macOS 14 or later, Xcode 26 with Swift 6.2, XcodeGen, and
Python 3. From the repository root, run:

```sh
./Scripts/package-release.sh [--format zip|dmg|both]
```

The default format is `zip`. The script:

1. generates `BeipMU.xcodeproj` from `project.yml`;
2. builds a universal Release app in `DerivedData/`;
3. applies an ad hoc signature to the app and embedded content;
4. copies this document into the archive as `INSTALL.md`;
5. writes ZIP and/or DMG artifacts to `dist/`; and
6. creates a SHA-256 file beside every artifact.

Expected output names are:

```text
dist/BeipMU-macOS-universal.zip
dist/BeipMU-macOS-universal.zip.sha256
dist/BeipMU-macOS-universal.dmg
dist/BeipMU-macOS-universal.dmg.sha256
```

Only the selected archive format and checksum are created. Existing BeipMU
release artifacts with these names are replaced by the packaging script.
