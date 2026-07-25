#!/usr/bin/env python3
"""Run, compare, and manifest the Sprint 10.3 performance gate."""

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
HOST = "latest-macos-apple-silicon"
SPRINT = "10.3"
COMMANDS = [
    "BEIPMU_EVIDENCE_DIR=Documentation/Evidence/M10/latest-macos-apple-silicon/10.3 ./Scripts/benchmark-workspace.sh",
    "BEIPMU_EVIDENCE_DIR=Documentation/Evidence/M10/latest-macos-apple-silicon/10.3 ./Scripts/profile-app-soak.sh",
]


def output(*arguments: str) -> str:
    return subprocess.check_output(arguments, cwd=ROOT, text=True).strip()


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def sha256(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def sanitize_text(path: Path) -> None:
    text = path.read_text(encoding="utf-8", errors="replace")
    text = text.replace(str(Path.home()), "$HOME")
    text = re.sub(r"(?<=\bid:)[^,}\s]+", "<redacted>", text)
    text = "\n".join(line.rstrip() for line in text.splitlines()) + (
        "\n" if text.endswith("\n") else ""
    )
    path.write_text(text, encoding="utf-8")


def host_metadata(commit: str) -> dict[str, object]:
    sw_vers = {
        line.split(":", 1)[0]: line.split(":", 1)[1].strip()
        for line in output("sw_vers").splitlines()
    }
    return {
        "architecture": platform.machine(),
        "capturedAt": utc_now(),
        "gitCommit": commit,
        "hardwareClass": output("sysctl", "-n", "hw.model"),
        "host": HOST,
        "logsAreSanitized": True,
        "osBuild": sw_vers["BuildVersion"],
        "osVersion": sw_vers["ProductVersion"],
        "privacy": "No serial number, device ID, or user account is recorded.",
        "schemaVersion": 1,
        "swiftVersion": output("swift", "--version").splitlines()[0],
        "xcodeVersion": " / ".join(output("xcodebuild", "-version").splitlines()),
    }


def build_comparison(manifest: dict, evidence_dir: Path) -> dict:
    benchmark = json.loads(
        (evidence_dir / "workspace-benchmark" / "report.json").read_text(
            encoding="utf-8"
        )
    )
    time_output = (evidence_dir / "workspace-benchmark" / "time.txt").read_text(
        encoding="utf-8"
    )
    peak_match = re.search(
        r"^\s*(\d+)\s+maximum resident set size$", time_output, re.MULTILINE
    )
    if not peak_match:
        raise ValueError("workspace time output has no maximum resident set size")
    app_output = (evidence_dir / "app-soak" / "BeipMU.stdout").read_text(
        encoding="utf-8"
    )
    soak_match = re.search(r"^BEIPMU_SOAK_COMPLETE (?P<values>.+)$", app_output, re.MULTILINE)
    if not soak_match:
        raise ValueError("application output has no completion report")
    soak = dict(
        component.split("=", 1)
        for component in soak_match.group("values").split()
        if "=" in component
    )
    current = {
        "appRSSBytes": int(soak["rssBytes"]),
        "appSeconds": float(soak["elapsedSeconds"]),
        "historyLinesPerSecond": benchmark["historyLinesPerSecond"],
        "layoutLinesPerSecond": benchmark["layoutLinesPerSecond"],
        "viewportQueriesPerSecond": benchmark["queryOperationsPerSecond"],
        "workspaceRSSBytes": int(peak_match.group(1)),
    }
    baseline = manifest["performanceComparison"]["baseline"]
    threshold = manifest["performanceComparison"]["materialRegressionPercent"]
    higher_is_better = {
        "historyLinesPerSecond",
        "layoutLinesPerSecond",
        "viewportQueriesPerSecond",
    }
    measurements = []
    for name in sorted(current):
        baseline_value = baseline[name]
        current_value = current[name]
        if name in higher_is_better:
            regression = (baseline_value - current_value) / baseline_value * 100
        else:
            regression = (current_value - baseline_value) / baseline_value * 100
        measurements.append(
            {
                "baseline": baseline_value,
                "current": current_value,
                "materialRegression": regression >= threshold,
                "name": name,
                "regressionPercent": round(regression, 3),
            }
        )
    return {
        "baseline": baseline,
        "current": current,
        "materialRegressionPercent": threshold,
        "measurements": measurements,
        "schemaVersion": 1,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default=HOST, choices=[HOST])
    args = parser.parse_args()
    if platform.machine() != "arm64":
        print("Sprint 10.3 requires native arm64 execution", file=sys.stderr)
        return 2
    if output("git", "status", "--porcelain", "--untracked-files=no"):
        print("Sprint 10.3 capture requires a clean tracked checkout", file=sys.stderr)
        return 2
    commit = output("git", "rev-parse", "HEAD")
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    contract = manifest["sprintContracts"][SPRINT]
    if contract["host"] != args.host or contract["commands"] != COMMANDS:
        print("Sprint 10.3 runner disagrees with the evidence contract", file=sys.stderr)
        return 2
    evidence_dir = ROOT / contract["outputDirectory"]
    if evidence_dir.exists():
        print(f"Evidence destination already exists: {evidence_dir}", file=sys.stderr)
        return 2
    logs_dir = evidence_dir / "commands"
    logs_dir.mkdir(parents=True)

    metadata = host_metadata(commit)
    metadata_path = evidence_dir / "host-metadata.json"
    metadata_path.write_text(
        json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    command_results: list[dict[str, object]] = []
    overall_passed = True
    for index, command in enumerate(COMMANDS, start=1):
        started_at = utc_now()
        started = time.monotonic()
        stem = f"{index:02d}-{'benchmark' if index == 1 else 'app-soak'}"
        stdout_path = logs_dir / f"{stem}.stdout.log"
        stderr_path = logs_dir / f"{stem}.stderr.log"
        result_path = logs_dir / f"{stem}.result.json"
        environment = os.environ.copy()
        environment["BEIPMU_EVIDENCE_DIR"] = str(evidence_dir)
        executable = (
            "./Scripts/benchmark-workspace.sh"
            if index == 1
            else "./Scripts/profile-app-soak.sh"
        )
        with stdout_path.open("wb") as stdout_file, stderr_path.open("wb") as stderr_file:
            completed = subprocess.run(
                executable,
                cwd=ROOT,
                env=environment,
                shell=True,
                executable="/bin/sh",
                stdout=stdout_file,
                stderr=stderr_file,
                check=False,
            )
        sanitize_text(stdout_path)
        sanitize_text(stderr_path)
        completed_at = utc_now()
        result = {
            "command": command,
            "completedAt": completed_at,
            "durationSeconds": round(time.monotonic() - started, 3),
            "exitCode": completed.returncode,
            "result": "pass" if completed.returncode == 0 else "fail",
            "startedAt": started_at,
        }
        result_path.write_text(
            json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        command_results.append(result)
        if completed.returncode:
            overall_passed = False

    trace_path = evidence_dir / "app-soak" / "BeipMU-Time-Profiler.trace"
    trace_archive: Path | None = None
    if trace_path.is_dir():
        trace_archive = Path(
            shutil.make_archive(
                str(evidence_dir / "app-soak" / "BeipMU-Time-Profiler.trace"),
                "zip",
                trace_path.parent,
                trace_path.name,
            )
        )
        shutil.rmtree(trace_path)
    else:
        overall_passed = False

    comparison_path = evidence_dir / "performance-comparison.json"
    try:
        comparison = build_comparison(manifest, evidence_dir)
        comparison_path.write_text(
            json.dumps(comparison, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        overall_passed = False
        comparison_path.write_text(
            json.dumps(
                {"error": str(error), "result": "fail", "schemaVersion": 1},
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )

    summary_path = evidence_dir / "performance-gate-summary.json"
    summary_path.write_text(
        json.dumps(
            {
                "commands": command_results,
                "completedAt": utc_now(),
                "gitCommit": commit,
                "host": HOST,
                "result": "pass" if overall_passed else "fail",
                "schemaVersion": 1,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )

    paths_and_roles = [
        (metadata_path, "host-metadata", "system metadata capture"),
        (
            evidence_dir / "workspace-benchmark" / "report.json",
            "benchmark-report",
            COMMANDS[0],
        ),
        (
            evidence_dir / "workspace-benchmark" / "time.txt",
            "resource-statistics",
            COMMANDS[0],
        ),
        (
            evidence_dir / "workspace-benchmark" / "leaks.txt",
            "benchmark-leaks",
            COMMANDS[0],
        ),
        (trace_archive, "instruments-trace", COMMANDS[1]),
        (
            evidence_dir / "app-soak" / "trace-toc.xml",
            "instruments-export",
            COMMANDS[1],
        ),
        (
            evidence_dir / "app-soak" / "BeipMU.stdout",
            "app-stdout",
            COMMANDS[1],
        ),
        (
            evidence_dir / "app-soak" / "BeipMU.stderr",
            "app-stderr",
            COMMANDS[1],
        ),
        (evidence_dir / "app-soak" / "leaks.txt", "app-leaks", COMMANDS[1]),
        (
            evidence_dir / "app-soak" / "verification.txt",
            "soak-verification",
            COMMANDS[1],
        ),
        (comparison_path, "performance-comparison", "compare with PERFORMANCE.md"),
        (summary_path, "performance-gate-summary", "Sprint 10.3 performance gate"),
    ]
    for index, command in enumerate(COMMANDS, start=1):
        stem = f"{index:02d}-{'benchmark' if index == 1 else 'app-soak'}"
        paths_and_roles.extend(
            [
                (logs_dir / f"{stem}.stdout.log", "command-log", command),
                (logs_dir / f"{stem}.stderr.log", "command-log", command),
                (logs_dir / f"{stem}.result.json", "command-result", command),
            ]
        )

    records = []
    result_by_command = {item["command"]: item["result"] for item in command_results}
    for path, role, command in paths_and_roles:
        if path is None or not path.is_file():
            overall_passed = False
            continue
        if path.suffix in {".txt", ".xml", ".log"} or path.name.endswith(".stdout"):
            sanitize_text(path)
        result = result_by_command.get(command, "pass" if overall_passed else "fail")
        records.append(
            {
                "architecture": metadata["architecture"],
                "command": command,
                "gitCommit": commit,
                "hardwareClass": metadata["hardwareClass"],
                "host": HOST,
                "osBuild": metadata["osBuild"],
                "osVersion": metadata["osVersion"],
                "path": path.relative_to(ROOT).as_posix(),
                "result": result,
                "role": role,
                "sha256": sha256(path),
                "sprint": SPRINT,
                "swiftVersion": metadata["swiftVersion"],
                "timestamp": utc_now(),
                "xcodeVersion": metadata["xcodeVersion"],
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
    print(f"Sprint 10.3 evidence captured at {evidence_dir}")
    return 0 if overall_passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
