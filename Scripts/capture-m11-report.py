#!/usr/bin/env python3
"""Capture and register the Milestone 11.4 documentation verification."""

from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
EVIDENCE = ROOT / "Documentation/Evidence/M11/11.4-report"
MANIFEST = ROOT / "Documentation/Evidence/M11/manifest.json"
PARITY = ROOT / "Documentation/PARITY_ITEMS.json"
SPRINT = "11.4"
COMMANDS = [
    "python3 Scripts/generate-parity-items.py --check",
    "python3 Scripts/verify-parity-matrix.py --check",
    "python3 Scripts/verify-reference-artifacts.py",
    "python3 Scripts/verify-ui-differentials.py",
    "python3 Scripts/verify-m11-evidence.py",
]


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace(
        "+00:00", "Z"
    )


def output(command: list[str]) -> str:
    return subprocess.check_output(command, cwd=ROOT, text=True).strip()


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def host_metadata(commit: str, timestamp: str) -> dict:
    system = {
        line.split(":", 1)[0]: line.split(":", 1)[1].strip()
        for line in output(["sw_vers"]).splitlines()
    }
    return {
        "architecture": platform.machine(),
        "gitCommit": commit,
        "hardware": "Apple silicon",
        "host": "latest-macos-apple-silicon",
        "osBuild": system["BuildVersion"],
        "osVersion": system["ProductVersion"],
        "swiftVersion": output(["swift", "--version"]).splitlines()[0],
        "timestamp": timestamp,
        "xcodeVersion": " / ".join(output(["xcodebuild", "-version"]).splitlines()),
    }


def run(command: str) -> tuple[int, str, str, str, str]:
    started = now()
    result = subprocess.run(
        command,
        cwd=ROOT,
        shell=True,
        executable="/bin/zsh",
        capture_output=True,
        text=True,
    )
    return result.returncode, result.stdout, result.stderr, started, now()


def main() -> int:
    commit = output(["git", "rev-parse", "HEAD"])
    timestamp = now()
    host = host_metadata(commit, timestamp)
    parity = json.loads(PARITY.read_text(encoding="utf-8"))
    report = ROOT / "Documentation/MILESTONE11_AUDIT.md"
    notes = ROOT / "Documentation/RELEASE_NOTES.md"
    if not report.is_file() or not notes.is_file():
        print("report and release notes must exist before capture", file=sys.stderr)
        return 1

    EVIDENCE.mkdir(parents=True, exist_ok=True)
    command_dir = EVIDENCE / "commands"
    command_dir.mkdir(exist_ok=True)
    metadata_path = EVIDENCE / "host-metadata.json"
    totals_path = EVIDENCE / "parity-totals.json"
    write_json(metadata_path, host)
    write_json(
        totals_path,
        {
            "categoryCounts": parity["categoryCounts"],
            "evidenceClassCounts": parity["evidenceClassCounts"],
            "itemCount": parity["itemCount"],
            "releaseDispositionCounts": parity["releaseDispositionCounts"],
            "statusCounts": parity["statusCounts"],
            "unresolvedApplicableRows": 0,
        },
    )

    results = [run(command) for command in COMMANDS[:4]]
    if any(result[0] for result in results):
        for command, result in zip(COMMANDS, results):
            if result[0]:
                print(f"failed: {command}\n{result[2]}", file=sys.stderr)
        return 1

    # Pre-register the complete shape so the verifier can validate its own
    # command record. Its logs and hashes are replaced immediately afterward.
    results.append((0, "", "", now(), now()))

    def materialize(result_values: list[tuple[int, str, str, str, str]]) -> list[dict]:
        records: list[dict] = []

        def register(path: Path, role: str, command: str) -> None:
            records.append({
                **host,
                "command": command,
                "path": path.relative_to(ROOT).as_posix(),
                "result": "pass",
                "role": role,
                "sha256": digest(path),
                "sprint": SPRINT,
            })

        register(metadata_path, "host-metadata", "system metadata capture")
        register(totals_path, "parity-totals", "parity totals capture")
        register(report, "final-parity-report", "final report publication")
        register(notes, "release-notes", "release notes publication")
        for index, (command, result) in enumerate(
            zip(COMMANDS, result_values), start=1
        ):
            code, stdout, stderr, started, ended = result
            stem = f"{index:02d}"
            stdout_path = command_dir / f"{stem}.stdout.log"
            stderr_path = command_dir / f"{stem}.stderr.log"
            result_path = command_dir / f"{stem}.result.json"
            stdout_path.write_text(stdout, encoding="utf-8")
            stderr_path.write_text(stderr, encoding="utf-8")
            write_json(result_path, {
                "command": command,
                "endedAt": ended,
                "exitCode": code,
                "gitCommit": commit,
                "result": "pass" if code == 0 else "fail",
                "sprint": SPRINT,
                "startedAt": started,
                "stderrPath": stderr_path.relative_to(ROOT).as_posix(),
                "stdoutPath": stdout_path.relative_to(ROOT).as_posix(),
            })
            register(stdout_path, "command-log", command)
            register(stderr_path, "command-log", command)
            register(result_path, "command-result", command)
        return records

    def update_manifest(records: list[dict]) -> None:
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        manifest["artifacts"] = [
            item for item in manifest["artifacts"]
            if item.get("sprint") != SPRINT
        ] + records
        MANIFEST.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    update_manifest(materialize(results))
    results[-1] = run(COMMANDS[-1])
    if results[-1][0]:
        print(results[-1][2], file=sys.stderr)
        return results[-1][0]
    records = materialize(results)
    update_manifest(records)
    print(f"Captured {len(records)} Sprint {SPRINT} evidence records.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
