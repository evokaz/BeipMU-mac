#!/usr/bin/env python3
"""Run, retain, and manifest the macOS 26 Sprint 10.5 closure gate."""

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
HOST = "macos26-apple-silicon"
SPRINT = "10.5"
COMMANDS = [
    "./Scripts/test.sh",
    "python3 Scripts/verify-reference-artifacts.py",
    "python3 Scripts/verify-ui-differentials.py",
    "./Scripts/test-ui.sh",
    "./Scripts/benchmark-workspace.sh",
    "BEIPMU_KEEP_APP_SOAK_ARTIFACTS=1 ./Scripts/profile-app-soak.sh",
    "git diff --check",
]
PACKAGE_COMMAND = "./Scripts/package-release.sh"
EXPECTED_SMOKE_CHECKS = {
    "atlas",
    "audio",
    "cleanShutdown",
    "connection",
    "launch",
    "restoration",
    "scriptService",
}


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


def slug(command: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", command.lower()).strip("-")[:72]


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


def load_smoke_checklist(path: Path) -> dict:
    try:
        checklist = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"smoke checklist is unreadable: {error}") from error
    checks = checklist.get("checks", {})
    observed_at = checklist.get("observedAt", "")
    try:
        parsed_observation = datetime.fromisoformat(observed_at.replace("Z", "+00:00"))
        dated_observation = parsed_observation.tzinfo is not None
    except (AttributeError, ValueError):
        dated_observation = False
    if (
        checklist.get("schemaVersion") != 1
        or checklist.get("host") != HOST
        or checklist.get("observedBy") not in {"user", "codex"}
        or not dated_observation
        or not isinstance(checks, dict)
        or set(checks) != EXPECTED_SMOKE_CHECKS
        or any(
            not isinstance(check, dict) or check.get("result") != "pass"
            or not str(check.get("notes", "")).strip()
            for check in checks.values()
        )
    ):
        raise ValueError(
            "smoke checklist must contain dated, operator-observed pass results "
            "and notes for every required check"
        )
    return checklist


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
    soak_match = re.search(
        r"^BEIPMU_SOAK_COMPLETE (?P<values>.+)$", app_output, re.MULTILINE
    )
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
    parser.add_argument("--smoke-checklist", required=True, type=Path)
    args = parser.parse_args()

    if platform.machine() != "arm64":
        print("Sprint 10.5 requires native arm64 execution", file=sys.stderr)
        return 2
    os_version = output("sw_vers", "-productVersion")
    if not os_version.startswith("26."):
        print(
            f"Sprint 10.5 requires macOS 26; this host is macOS {os_version}",
            file=sys.stderr,
        )
        return 2
    if output("git", "status", "--porcelain", "--untracked-files=no"):
        print("Sprint 10.5 capture requires a clean tracked checkout", file=sys.stderr)
        return 2
    try:
        smoke = load_smoke_checklist(args.smoke_checklist.expanduser().resolve())
    except ValueError as error:
        print(error, file=sys.stderr)
        return 2

    commit = output("git", "rev-parse", "HEAD")
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    contract = manifest["sprintContracts"][SPRINT]
    if contract["host"] != HOST or contract["commands"] != COMMANDS:
        print("Sprint 10.5 runner disagrees with the evidence contract", file=sys.stderr)
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
    smoke_path = evidence_dir / "smoke-checklist.json"
    smoke_path.write_text(
        json.dumps(smoke, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    command_results: list[dict[str, object]] = []
    command_files: list[tuple[Path, str, str]] = []
    overall_passed = True

    def run_command(index: int, command: str) -> None:
        nonlocal overall_passed
        started_at = utc_now()
        started = time.monotonic()
        stem = f"{index:02d}-{slug(command)}"
        stdout_path = logs_dir / f"{stem}.stdout.log"
        stderr_path = logs_dir / f"{stem}.stderr.log"
        result_path = logs_dir / f"{stem}.result.json"
        environment = os.environ.copy()
        if command in {
            "./Scripts/test-ui.sh",
            "./Scripts/benchmark-workspace.sh",
            "BEIPMU_KEEP_APP_SOAK_ARTIFACTS=1 ./Scripts/profile-app-soak.sh",
        }:
            environment["BEIPMU_EVIDENCE_DIR"] = str(evidence_dir)
        with stdout_path.open("wb") as stdout_stream, stderr_path.open(
            "wb"
        ) as stderr_stream:
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
        command_files.extend(
            [
                (stdout_path, "command-log", command),
                (stderr_path, "command-log", command),
                (result_path, "command-result", command),
            ]
        )
        if completed.returncode:
            overall_passed = False

    for index, command in enumerate(COMMANDS, start=1):
        run_command(index, command)
    run_command(len(COMMANDS) + 1, PACKAGE_COMMAND)
    if output("git", "status", "--porcelain", "--untracked-files=no"):
        print(
            "Package generation changed tracked files; closure evidence is not clean",
            file=sys.stderr,
        )
        overall_passed = False

    ui_status = next(
        item["result"]
        for item in command_results
        if item["command"] == "./Scripts/test-ui.sh"
    )
    archived_paths: list[tuple[Path, str, str]] = []
    for directory_name, role in (
        ("BeipMU-UI.xcresult", "xcuitest-result-bundle"),
        ("attachments", "xcuitest-attachments"),
    ):
        source = evidence_dir / "ui-tests" / directory_name
        if source.is_dir():
            archive = Path(
                shutil.make_archive(
                    str(evidence_dir / directory_name), "zip", source.parent, source.name
                )
            )
            shutil.rmtree(source)
            archived_paths.append((archive, role, "./Scripts/test-ui.sh"))
        else:
            overall_passed = False

    trace = evidence_dir / "app-soak" / "BeipMU-Time-Profiler.trace"
    trace_archive: Path | None = None
    if trace.is_dir():
        trace_archive = Path(
            shutil.make_archive(str(trace), "zip", trace.parent, trace.name)
        )
        shutil.rmtree(trace)
    else:
        overall_passed = False

    comparison_path = evidence_dir / "performance-comparison.json"
    try:
        comparison_path.write_text(
            json.dumps(
                build_comparison(manifest, evidence_dir), indent=2, sort_keys=True
            )
            + "\n",
            encoding="utf-8",
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

    slice_path = evidence_dir / "universal-slice-inspection.json"
    built_archive_path = ROOT / "dist" / "BeipMU-macOS-universal.zip"
    archive_path = evidence_dir / "BeipMU-macOS-universal.zip"
    if built_archive_path.is_file():
        shutil.copy2(built_archive_path, archive_path)
    binaries = [
        (
            "BeipMU",
            ROOT
            / "DerivedData"
            / "Build"
            / "Products"
            / "Release"
            / "BeipMU.app"
            / "Contents"
            / "MacOS"
            / "BeipMU",
        ),
        (
            "BeipScriptService",
            ROOT
            / "DerivedData"
            / "Build"
            / "Products"
            / "Release"
            / "BeipMU.app"
            / "Contents"
            / "XPCServices"
            / "BeipScriptService.xpc"
            / "Contents"
            / "MacOS"
            / "BeipScriptService",
        ),
    ]
    inspections = []
    slice_passed = archive_path.is_file()
    for name, binary in binaries:
        try:
            architectures = set(output("lipo", "-archs", str(binary)).split())
        except (OSError, subprocess.CalledProcessError):
            architectures = set()
        if architectures != {"arm64", "x86_64"}:
            slice_passed = False
        inspections.append(
            {
                "architectures": [
                    architecture
                    for architecture in ("arm64", "x86_64")
                    if architecture in architectures
                ],
                "name": name,
                "path": binary.relative_to(ROOT).as_posix(),
            }
        )
    slice_path.write_text(
        json.dumps(
            {
                "archivePath": archive_path.relative_to(ROOT).as_posix(),
                "archiveSHA256": sha256(archive_path) if archive_path.is_file() else "",
                "binaries": inspections,
                "inspectedAt": utc_now(),
                "intelExecuted": False,
                "intelSupport": "untested-and-unsupported",
                "result": "pass" if slice_passed else "fail",
                "schemaVersion": 1,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    overall_passed = overall_passed and slice_passed and ui_status == "pass"

    paths_and_roles: list[tuple[Path | None, str, str]] = [
        (metadata_path, "host-metadata", "system metadata capture"),
        (smoke_path, "smoke-checklist", "Sprint 10.5 focused smoke checks"),
        (
            evidence_dir / "workspace-benchmark" / "report.json",
            "benchmark-report",
            COMMANDS[4],
        ),
        (
            evidence_dir / "workspace-benchmark" / "time.txt",
            "resource-statistics",
            COMMANDS[4],
        ),
        (
            evidence_dir / "workspace-benchmark" / "leaks.txt",
            "benchmark-leaks",
            COMMANDS[4],
        ),
        (trace_archive, "instruments-trace", COMMANDS[5]),
        (
            evidence_dir / "app-soak" / "trace-toc.xml",
            "instruments-export",
            COMMANDS[5],
        ),
        (evidence_dir / "app-soak" / "BeipMU.stdout", "app-stdout", COMMANDS[5]),
        (evidence_dir / "app-soak" / "BeipMU.stderr", "app-stderr", COMMANDS[5]),
        (evidence_dir / "app-soak" / "leaks.txt", "app-leaks", COMMANDS[5]),
        (
            evidence_dir / "app-soak" / "verification.txt",
            "soak-verification",
            COMMANDS[5],
        ),
        (
            comparison_path,
            "performance-comparison",
            "compare with PERFORMANCE.md",
        ),
        (
            slice_path,
            "universal-slice-inspection",
            f"{PACKAGE_COMMAND}; lipo -archs",
        ),
        (archive_path, "universal-package", PACKAGE_COMMAND),
        *archived_paths,
        *command_files,
    ]
    result_by_command = {item["command"]: item["result"] for item in command_results}
    records = []
    for path, role, command in paths_and_roles:
        if path is None or not path.is_file():
            overall_passed = False
            continue
        if role in {
            "app-stderr",
            "app-stdout",
            "benchmark-leaks",
            "command-log",
            "instruments-export",
            "app-leaks",
            "resource-statistics",
            "soak-verification",
        }:
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
    print(f"Sprint 10.5 evidence captured at {evidence_dir}")
    return 0 if overall_passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
