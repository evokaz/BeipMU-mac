#!/usr/bin/env python3
"""Run and manifest the reproducible M10.1 automated gate."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = ROOT / "Documentation" / "Evidence" / "M10" / "manifest.json"
COMMANDS = [
    "./Scripts/test.sh",
    "python3 Scripts/verify-reference-artifacts.py",
    "python3 Scripts/verify-ui-differentials.py",
    "./Scripts/test-ui.sh",
    "git diff --check",
]


def output(*arguments: str) -> str:
    return subprocess.check_output(arguments, cwd=ROOT, text=True).strip()


def timestamp() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def sha256(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def slug(command: str) -> str:
    value = re.sub(r"[^a-z0-9]+", "-", command.lower()).strip("-")
    return value[:72]


def sanitize_log(path: Path) -> None:
    """Remove host identity from text logs without changing gate output."""
    text = path.read_text(encoding="utf-8", errors="replace")
    text = text.replace(str(Path.home()), "$HOME")
    text = re.sub(r"(?<=\bid:)[^,}\s]+", "<redacted>", text)
    text = "\n".join(line.rstrip() for line in text.splitlines()) + (
        "\n" if text.endswith("\n") else ""
    )
    path.write_text(text, encoding="utf-8")


def host_metadata(host: str, commit: str) -> dict[str, object]:
    sw_vers = {
        line.split(":", 1)[0]: line.split(":", 1)[1].strip()
        for line in output("sw_vers").splitlines()
    }
    xcode = output("xcodebuild", "-version").splitlines()
    swift = output("swift", "--version").splitlines()[0]
    hardware = output("sysctl", "-n", "hw.model")
    return {
        "schemaVersion": 1,
        "host": host,
        "hardwareClass": hardware,
        "architecture": platform.machine(),
        "osVersion": sw_vers["ProductVersion"],
        "osBuild": sw_vers["BuildVersion"],
        "xcodeVersion": " / ".join(xcode),
        "swiftVersion": swift,
        "gitCommit": commit,
        "logsAreSanitized": True,
        "capturedAt": timestamp(),
        "privacy": "No serial number, device ID, or user account is recorded.",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--host",
        default="latest-macos-apple-silicon",
        choices=["latest-macos-apple-silicon"],
    )
    args = parser.parse_args()

    if platform.machine() != "arm64":
        print("M10.1 requires a native arm64 host", file=sys.stderr)
        return 2
    dirty = output("git", "status", "--porcelain", "--untracked-files=no")
    if dirty:
        print("M10.1 capture requires a clean tracked checkout", file=sys.stderr)
        return 2
    commit = output("git", "rev-parse", "HEAD")
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    contract = manifest["sprintContracts"]["10.1"]
    if contract["commands"] != COMMANDS or contract["host"] != args.host:
        print("M10.1 command contract does not match this runner", file=sys.stderr)
        return 2

    evidence_dir = ROOT / contract["outputDirectory"]
    if evidence_dir.exists():
        print(f"Evidence destination already exists: {evidence_dir}", file=sys.stderr)
        return 2
    logs_dir = evidence_dir / "commands"
    logs_dir.mkdir(parents=True)

    metadata = host_metadata(args.host, commit)
    metadata_path = evidence_dir / "host-metadata.json"
    metadata_path.write_text(
        json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    artifact_records: list[dict[str, object]] = []

    def add_artifact(
        path: Path, role: str, command: str, result: str, captured_at: str
    ) -> None:
        relative = path.relative_to(ROOT).as_posix()
        artifact_records.append(
            {
                "architecture": metadata["architecture"],
                "command": command,
                "gitCommit": commit,
                "hardwareClass": metadata["hardwareClass"],
                "host": args.host,
                "osBuild": metadata["osBuild"],
                "osVersion": metadata["osVersion"],
                "path": relative,
                "result": result,
                "role": role,
                "sha256": sha256(path),
                "sprint": "10.1",
                "swiftVersion": metadata["swiftVersion"],
                "timestamp": captured_at,
                "xcodeVersion": metadata["xcodeVersion"],
            }
        )

    add_artifact(
        metadata_path, "host-metadata", "system metadata capture", "pass", timestamp()
    )

    command_results: list[dict[str, object]] = []
    overall_passed = True
    ui_status = "failed"
    ui_timestamp = timestamp()
    for index, command in enumerate(COMMANDS, start=1):
        started_at = timestamp()
        start = time.monotonic()
        stem = f"{index:02d}-{slug(command)}"
        stdout_path = logs_dir / f"{stem}.stdout.log"
        stderr_path = logs_dir / f"{stem}.stderr.log"
        result_path = logs_dir / f"{stem}.result.json"
        environment = os.environ.copy()
        if command == "./Scripts/test-ui.sh":
            environment["BEIPMU_EVIDENCE_DIR"] = str(evidence_dir)
        with stdout_path.open("wb") as stdout_stream, stderr_path.open("wb") as stderr_stream:
            completed = subprocess.run(
                command,
                cwd=ROOT,
                env=environment,
                shell=True,
                executable="/bin/sh",
                stdout=stdout_stream,
                stderr=stderr_stream,
                check=False,
            )
        sanitize_log(stdout_path)
        sanitize_log(stderr_path)
        completed_at = timestamp()
        result = "pass" if completed.returncode == 0 else "fail"
        record = {
            "command": command,
            "completedAt": completed_at,
            "durationSeconds": round(time.monotonic() - start, 3),
            "exitCode": completed.returncode,
            "result": result,
            "startedAt": started_at,
        }
        result_path.write_text(
            json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        command_results.append(record)
        add_artifact(stdout_path, "command-log", command, result, completed_at)
        add_artifact(stderr_path, "command-log", command, result, completed_at)
        add_artifact(result_path, "command-result", command, result, completed_at)
        if command == "./Scripts/test-ui.sh":
            ui_status = result
            ui_timestamp = completed_at
        if completed.returncode:
            overall_passed = False

    ui_directory = evidence_dir / "ui-tests"
    for directory_name, role in (
        ("BeipMU-UI.xcresult", "xcuitest-result-bundle"),
        ("attachments", "xcuitest-attachments"),
    ):
        source = ui_directory / directory_name
        if source.is_dir():
            archive_base = evidence_dir / directory_name
            archive_path = Path(
                shutil.make_archive(str(archive_base), "zip", source.parent, source.name)
            )
            add_artifact(archive_path, role, "./Scripts/test-ui.sh", ui_status, ui_timestamp)
            shutil.rmtree(source)
        else:
            overall_passed = False

    summary_path = evidence_dir / "automated-gate-summary.json"
    summary_path.write_text(
        json.dumps(
            {
                "commands": command_results,
                "completedAt": timestamp(),
                "gitCommit": commit,
                "host": args.host,
                "result": "pass" if overall_passed else "fail",
                "schemaVersion": 1,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    add_artifact(
        summary_path,
        "automated-gate-summary",
        "M10.1 automated gate",
        "pass" if overall_passed else "fail",
        timestamp(),
    )

    manifest["artifacts"] = [
        record
        for record in manifest.get("artifacts", [])
        if not (
            record.get("host") == args.host and record.get("sprint") == "10.1"
        )
    ] + artifact_records
    MANIFEST_PATH.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(f"M10.1 evidence captured at {evidence_dir}")
    return 0 if overall_passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
