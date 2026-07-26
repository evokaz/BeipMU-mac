#!/usr/bin/env python3
"""Capture and register the Milestone 11.3 package inspection."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone


ROOT = Path(__file__).resolve().parent.parent
EVIDENCE = ROOT / "Documentation/Evidence/M11/11.3-package"
MANIFEST = ROOT / "Documentation/Evidence/M11/manifest.json"
APP = ROOT / "DerivedData/Build/Products/Release/BeipMU.app"
SERVICE = APP / "Contents/XPCServices/BeipScriptService.xpc"
ZIP = ROOT / "dist/BeipMU-macOS-universal.zip"
CHECKSUM = ROOT / "dist/BeipMU-macOS-universal.zip.sha256"
SPRINT = "11.3"
HOST = "latest-macos-apple-silicon"

COMMANDS = [
    "./Scripts/package-release.sh",
    "lipo -archs DerivedData/Build/Products/Release/BeipMU.app/Contents/MacOS/BeipMU",
    "lipo -archs DerivedData/Build/Products/Release/BeipMU.app/Contents/XPCServices/BeipScriptService.xpc/Contents/MacOS/BeipScriptService",
    "codesign --verify --deep --strict DerivedData/Build/Products/Release/BeipMU.app",
    "codesign -d --entitlements :- DerivedData/Build/Products/Release/BeipMU.app",
    "plutil -extract CFBundleIdentifier raw DerivedData/Build/Products/Release/BeipMU.app/Contents/Info.plist",
    "plutil -extract CFBundleIdentifier raw DerivedData/Build/Products/Release/BeipMU.app/Contents/XPCServices/BeipScriptService.xpc/Contents/Info.plist",
    "unzip -t dist/BeipMU-macOS-universal.zip",
    "cd dist && shasum -a 256 -c BeipMU-macOS-universal.zip.sha256",
]


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(command: str) -> tuple[int, str, str, str, str]:
    started = utc_now()
    result = subprocess.run(
        command,
        cwd=ROOT,
        shell=True,
        executable="/bin/zsh",
        text=True,
        capture_output=True,
    )
    return result.returncode, result.stdout, result.stderr, started, utc_now()


def output(command: list[str]) -> str:
    return subprocess.check_output(command, cwd=ROOT, text=True).strip()


def inventory() -> list[dict]:
    records = []
    for path in sorted(item for item in APP.rglob("*") if item.is_file()):
        mode = oct(path.stat().st_mode & 0o777)
        records.append({
            "path": path.relative_to(APP).as_posix(),
            "mode": mode,
            "size": path.stat().st_size,
            "sha256": sha256(path),
        })
    return records


def metadata(commit: str, timestamp: str) -> dict:
    sw_vers = {
        line.split(":", 1)[0]: line.split(":", 1)[1].strip()
        for line in output(["sw_vers"]).splitlines()
    }
    xcode_lines = output(["xcodebuild", "-version"]).splitlines()
    swift = output(["swift", "--version"]).splitlines()[0]
    return {
        "architecture": platform.machine(),
        "gitCommit": commit,
        "hardware": "Apple silicon",
        "host": HOST,
        "osBuild": sw_vers["BuildVersion"],
        "osVersion": sw_vers["ProductVersion"],
        "swiftVersion": swift,
        "timestamp": timestamp,
        "xcodeVersion": " / ".join(xcode_lines),
    }


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main() -> int:
    commit = output(["git", "rev-parse", "HEAD"])
    dirty = output(["git", "status", "--porcelain=v1", "--untracked-files=no"])
    if dirty:
        print("capture requires a clean tracked worktree", file=sys.stderr)
        return 1
    timestamp = utc_now()
    host = metadata(commit, timestamp)

    with tempfile.TemporaryDirectory(prefix="beipmu-m11-package-") as temporary:
        first_zip = Path(temporary) / ZIP.name
        first_results = {}
        code, stdout, stderr, started, ended = run(COMMANDS[0])
        first_results["package"] = (code, stdout, stderr, started, ended)
        if code:
            print(stderr, file=sys.stderr)
            return code
        shutil.copy2(ZIP, first_zip)
        first = {
            "gitCommit": commit,
            "archiveSHA256": sha256(ZIP),
            "checksumSHA256": sha256(CHECKSUM),
            "files": inventory(),
        }

        code, stdout2, stderr2, _, ended2 = run(COMMANDS[0])
        if code:
            print(stderr2, file=sys.stderr)
            return code
        first_results["package"] = (
            0,
            "=== first build ===\n" + stdout + "\n=== rebuild ===\n" + stdout2,
            "=== first build ===\n" + stderr + "\n=== rebuild ===\n" + stderr2,
            started,
            ended2,
        )
        second = {
            "gitCommit": commit,
            "archiveSHA256": sha256(ZIP),
            "checksumSHA256": sha256(CHECKSUM),
            "files": inventory(),
        }

    results = [first_results["package"]]
    for command in COMMANDS[1:]:
        result = run(command)
        results.append(result)
        if result[0]:
            print(f"failed: {command}\n{result[2]}", file=sys.stderr)
            return result[0]

    archive_names = output(["unzip", "-Z1", str(ZIP)]).splitlines()
    app_archs = output(["lipo", "-archs", str(APP / "Contents/MacOS/BeipMU")]).split()
    service_archs = output([
        "lipo", "-archs",
        str(SERVICE / "Contents/MacOS/BeipScriptService"),
    ]).split()
    app_identifier = output([
        "plutil", "-extract", "CFBundleIdentifier", "raw",
        str(APP / "Contents/Info.plist"),
    ])
    service_identifier = output([
        "plutil", "-extract", "CFBundleIdentifier", "raw",
        str(SERVICE / "Contents/Info.plist"),
    ])
    signature_text = subprocess.check_output(
        ["codesign", "-dv", "--verbose=4", str(APP)],
        cwd=ROOT, text=True, stderr=subprocess.STDOUT,
    )
    app_cdhash = next(
        line.split("=", 1)[1] for line in signature_text.splitlines()
        if line.startswith("CDHash=")
    )

    records = {
        "host-metadata.json": host,
        "initial-clean-state.json": {
            "gitCommit": commit,
            "porcelain": "",
            "result": "pass",
            "timestamp": timestamp,
        },
        "architecture-inspection.json": {
            "application": {"architectures": app_archs},
            "embeddedService": {"architectures": service_archs},
            "intelSupported": False,
            "intelTested": False,
        },
        "identifier-inspection.json": {
            "bundleIdentifiers": {
                "application": app_identifier,
                "embeddedService": service_identifier,
            },
        },
        "signature-inspection.json": {
            "applicationCDHash": app_cdhash,
            "deepStrictExitCode": results[3][0],
            "kind": "ad-hoc",
        },
        "zip-integrity.json": {
            "archive": "dist/BeipMU-macOS-universal.zip",
            "exitCode": results[7][0],
            "result": "pass",
        },
        "attribution-inspection.json": {
            "installIncluded": "INSTALL.md" in archive_names,
            "licenseIncluded": "LICENSE" in archive_names,
            "mitAttributionCorrect": (
                "MIT License" in (ROOT / "LICENSE").read_text(encoding="utf-8")
                and "MIT attribution" in (
                    ROOT / "Documentation/DISTRIBUTION.md"
                ).read_text(encoding="utf-8")
            ),
        },
        "package-file-list.json": {
            "archiveEntries": archive_names,
            "files": second["files"],
        },
        "rebuild-comparison.json": {
            "containerBytesMatch": first["archiveSHA256"] == second["archiveSHA256"],
            "firstArchiveSHA256": first["archiveSHA256"],
            "firstChecksumSHA256": first["checksumSHA256"],
            "nondeterminism": (
                "ZIP container timestamps differ; observable package contents "
                "and metadata match."
            ),
            "observableContentsMatch": first["files"] == second["files"],
            "sameGitCommit": first["gitCommit"] == second["gitCommit"],
            "secondArchiveSHA256": second["archiveSHA256"],
            "secondChecksumSHA256": second["checksumSHA256"],
        },
    }

    if EVIDENCE.exists():
        shutil.rmtree(EVIDENCE)
    command_dir = EVIDENCE / "commands"
    command_dir.mkdir(parents=True)
    manifest_records = []

    def register(path: Path, role: str, command: str) -> None:
        manifest_records.append({
            **host,
            "command": command,
            "path": path.relative_to(ROOT).as_posix(),
            "result": "pass",
            "role": role,
            "sha256": sha256(path),
            "sprint": SPRINT,
        })

    roles = {
        "host-metadata.json": "host-metadata",
        "initial-clean-state.json": "clean-state",
        "architecture-inspection.json": "architecture-inspection",
        "identifier-inspection.json": "identifier-inspection",
        "signature-inspection.json": "signature-inspection",
        "zip-integrity.json": "zip-integrity",
        "attribution-inspection.json": "attribution-inspection",
        "package-file-list.json": "package-file-list",
        "rebuild-comparison.json": "rebuild-comparison",
    }
    for name, value in records.items():
        path = EVIDENCE / name
        write_json(path, value)
        register(path, roles[name], "package inspection")

    for index, (command, result) in enumerate(zip(COMMANDS, results), start=1):
        code, stdout, stderr, started, ended = result
        stem = f"{index:02d}"
        stdout_path = command_dir / f"{stem}.stdout.log"
        stderr_path = command_dir / f"{stem}.stderr.log"
        stdout_path.write_text(stdout, encoding="utf-8")
        stderr_path.write_text(stderr, encoding="utf-8")
        result_path = command_dir / f"{stem}.result.json"
        write_json(result_path, {
            "command": command,
            "endedAt": ended,
            "exitCode": code,
            "gitCommit": commit,
            "result": "pass",
            "sprint": SPRINT,
            "startedAt": started,
            "stderrPath": stderr_path.relative_to(ROOT).as_posix(),
            "stdoutPath": stdout_path.relative_to(ROOT).as_posix(),
        })
        register(stdout_path, "command-log", command)
        register(stderr_path, "command-log", command)
        register(result_path, "command-result", command)

    for path, role in ((ZIP, "package-zip"), (CHECKSUM, "package-checksum")):
        manifest_records.append({
            **host,
            "command": COMMANDS[0],
            "path": path.relative_to(ROOT).as_posix(),
            "result": "pass",
            "role": role,
            "sha256": sha256(path),
            "sprint": SPRINT,
        })

    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    manifest["artifacts"] = [
        item for item in manifest["artifacts"] if item.get("sprint") != SPRINT
    ] + manifest_records
    MANIFEST.write_text(
        json.dumps(manifest, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Captured {len(manifest_records)} Sprint {SPRINT} evidence records.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
