#!/usr/bin/env python3
"""Validate, hash, and register the completed Sprint 10.2 evidence bundle."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = ROOT / "Documentation" / "Evidence" / "M10" / "manifest.json"
HOST = "latest-macos-apple-silicon"
SPRINT = "10.2"
EVIDENCE_DIR = ROOT / "Documentation" / "Evidence" / "M10" / HOST / SPRINT
COMMIT = re.compile(r"^[0-9a-f]{40}$")


def output(*arguments: str) -> str:
    return subprocess.check_output(arguments, cwd=ROOT, text=True).strip()


def timestamp() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def role(path: Path) -> str:
    roles = {
        "accessibility-observations.md": "accessibility-observation",
        "checklist.md": "accessibility-audio-checklist",
        "human-audio-confirmation.json": "human-audio-confirmation",
        "media-server-trace.log": "media-server-trace",
    }
    if path.name in roles:
        return roles[path.name]
    if path.suffix.lower() == ".png":
        return "accessibility-screenshot"
    return "accessibility-supporting-evidence"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-commit", required=True)
    arguments = parser.parse_args()
    if platform.machine() != "arm64":
        print("Sprint 10.2 requires native arm64 execution", file=sys.stderr)
        return 2
    if not COMMIT.fullmatch(arguments.source_commit):
        print("--source-commit must be a full 40-character commit", file=sys.stderr)
        return 2
    subprocess.run(
        ["git", "cat-file", "-e", f"{arguments.source_commit}^{{commit}}"],
        cwd=ROOT,
        check=True,
    )

    required = {
        "accessibility-observations.md",
        "checklist.md",
        "human-audio-confirmation.json",
        "media-server-trace.log",
    }
    present = {path.name for path in EVIDENCE_DIR.iterdir() if path.is_file()}
    missing = required - present
    if missing:
        print("Missing evidence: " + ", ".join(sorted(missing)), file=sys.stderr)
        return 2
    if not any(path.suffix.lower() == ".png" for path in EVIDENCE_DIR.iterdir()):
        print("At least one accessibility screenshot is required", file=sys.stderr)
        return 2

    checklist = (EVIDENCE_DIR / "checklist.md").read_text(encoding="utf-8")
    if re.search(r"\b(?:incomplete|pending)\b", checklist, re.IGNORECASE):
        print("Checklist still contains incomplete or pending work", file=sys.stderr)
        return 2
    confirmation = json.loads(
        (EVIDENCE_DIR / "human-audio-confirmation.json").read_text(encoding="utf-8")
    )
    if not all(
        confirmation.get(field) is True
        for field in (
            "voiceOverAudible",
            "clientMediaAudible",
            "selectedVoiceSpeechAudible",
        )
    ):
        print("All three audible outputs require explicit confirmation", file=sys.stderr)
        return 2

    manifest_original = MANIFEST_PATH.read_text(encoding="utf-8")
    manifest = json.loads(manifest_original)
    contract = manifest["sprintContracts"][SPRINT]
    if contract["host"] != HOST or ROOT / contract["outputDirectory"] != EVIDENCE_DIR:
        print("Sprint 10.2 evidence contract disagrees with this runner", file=sys.stderr)
        return 2

    sw_vers = {
        line.split(":", 1)[0]: line.split(":", 1)[1].strip()
        for line in output("sw_vers").splitlines()
    }
    metadata = {
        "architecture": platform.machine(),
        "gitCommit": arguments.source_commit,
        "hardwareClass": output("sysctl", "-n", "hw.model"),
        "host": HOST,
        "osBuild": sw_vers["BuildVersion"],
        "osVersion": sw_vers["ProductVersion"],
        "swiftVersion": output("swift", "--version").splitlines()[0],
        "xcodeVersion": " / ".join(output("xcodebuild", "-version").splitlines()),
    }
    records = []
    for path in sorted(EVIDENCE_DIR.iterdir()):
        if not path.is_file():
            continue
        records.append(
            {
                **metadata,
                "command": "Sprint 10.2 physical accessibility and audio audit",
                "path": path.relative_to(ROOT).as_posix(),
                "result": "pass",
                "role": role(path),
                "sha256": digest(path),
                "sprint": SPRINT,
                "timestamp": timestamp(),
            }
        )
    manifest["artifacts"] = [
        item
        for item in manifest.get("artifacts", [])
        if not (item.get("host") == HOST and item.get("sprint") == SPRINT)
    ] + records
    MANIFEST_PATH.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    verified = subprocess.run(
        [sys.executable, "Scripts/verify-m10-evidence.py", "--sprint", SPRINT],
        cwd=ROOT,
        check=False,
    )
    if verified.returncode:
        MANIFEST_PATH.write_text(manifest_original, encoding="utf-8")
        print("Registration rolled back because verification failed", file=sys.stderr)
        return verified.returncode
    print(f"Registered {len(records)} Sprint 10.2 artifacts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
