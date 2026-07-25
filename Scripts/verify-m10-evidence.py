#!/usr/bin/env python3
"""Verify the Milestone 10 evidence contract and captured host corpora."""

from __future__ import annotations

import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import sys
import zipfile


ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = ROOT / "Documentation" / "Evidence" / "M10" / "manifest.json"
SHA256 = re.compile(r"^[0-9a-f]{64}$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")
REQUIRED_ARTIFACT_FIELDS = {
    "architecture",
    "command",
    "gitCommit",
    "hardwareClass",
    "host",
    "osBuild",
    "osVersion",
    "path",
    "result",
    "role",
    "sha256",
    "sprint",
    "swiftVersion",
    "timestamp",
    "xcodeVersion",
}
FORBIDDEN_METADATA_KEYS = {"serial", "serialNumber", "deviceID", "deviceId", "udid"}


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def fail(errors: list[str], message: str) -> None:
    errors.append(message)


def validate_contract(manifest: dict, errors: list[str]) -> None:
    if manifest.get("contractVersion") != 1:
        fail(errors, "manifest: contractVersion must be 1")
    hosts = manifest.get("hosts")
    if not isinstance(hosts, dict) or set(hosts) != {
        "latest-macos-apple-silicon",
        "macos26-apple-silicon",
    }:
        fail(errors, "manifest: required Apple-silicon host coverage is incomplete")
    else:
        for host_id, host in hosts.items():
            if host.get("architecture") != "arm64":
                fail(errors, f"manifest: {host_id} must require arm64")
    budgets = manifest.get("performanceBudgets", {})
    expected_budgets = {
        "appOwnedLeaks": 0,
        "appSoakExpectedLines": 50_040,
        "appSoakRequestedLines": 50_000,
        "appSoakMaximumRSSBytes": 268_435_456,
        "historyLinesPerSecondMinimum": 250_000,
        "layoutLinesPerSecondMinimum": 250_000,
        "retainedHistoryLines": 10_000,
        "scaleScenarioMaximumRSSBytes": 268_435_456,
        "viewportCandidatesMaximum": 200,
        "viewportQueriesPerSecondMinimum": 500_000,
        "workspaceMaximumRSSBytes": 134_217_728,
    }
    if budgets != expected_budgets:
        fail(errors, "manifest: performance budgets differ from the M10 release contract")
    comparison = manifest.get("performanceComparison", {})
    if comparison != {
        "baseline": {
            "appRSSBytes": 148_471_808,
            "appSeconds": 17.397,
            "historyLinesPerSecond": 3_173_634,
            "layoutLinesPerSecond": 126_697_236,
            "viewportQueriesPerSecond": 10_127_736,
            "workspaceRSSBytes": 15_695_872,
        },
        "materialRegressionPercent": 20,
    }:
        fail(errors, "manifest: performance comparison baseline differs from PERFORMANCE.md")
    fixtures = manifest.get("fixtures", [])
    if {item.get("role") for item in fixtures if isinstance(item, dict)} != {
        "large-configuration",
        "large-atlas",
        "concurrent-connections",
    }:
        fail(errors, "manifest: deterministic scale fixture roles are incomplete")
    for fixture in fixtures:
        path = ROOT / fixture.get("path", "")
        if not path.is_file():
            fail(errors, f"fixture missing: {path}")
        elif digest(path) != fixture.get("sha256"):
            fail(errors, f"fixture hash mismatch: {path}")
    fixture_paths = {
        fixture.get("role"): ROOT / fixture.get("path", "") for fixture in fixtures
    }
    config_path = fixture_paths.get("large-configuration")
    if config_path and config_path.is_file():
        config = config_path.read_text(encoding="utf-8")
        if (
            config.count('"M10 World ') != 64
            or config.count('"Character ') != 256
            or config.count('Description="M10 trigger ') != 2_048
            or config.count('Description="M10 alias ') != 2_048
            or "M10TrailingUnknown=preserve-trailing" not in config
        ):
            fail(errors, "fixture: large configuration scale or preservation markers differ")
    atlas_path = fixture_paths.get("large-atlas")
    if atlas_path and atlas_path.is_file():
        try:
            with zipfile.ZipFile(atlas_path) as archive:
                atlas_xml = archive.read("Atlas.xml").decode()
            if (
                atlas_xml.count("<room ") != 400
                or atlas_xml.count("<exit ") != 760
                or "m10_unknown_root='preserve-root'" not in atlas_xml
            ):
                fail(errors, "fixture: large atlas scale or preservation markers differ")
        except (OSError, KeyError, UnicodeDecodeError, zipfile.BadZipFile) as error:
            fail(errors, f"fixture: large atlas is unreadable: {error}")
    connections_path = fixture_paths.get("concurrent-connections")
    if connections_path and connections_path.is_file():
        try:
            connections = json.loads(connections_path.read_text(encoding="utf-8"))
            sessions = connections["sessions"]
            if (
                connections.get("seed") != 10_010
                or connections.get("sessionCount") != 8
                or len(sessions) != 8
                or any(session.get("reconnects") != 2 for session in sessions)
                or any(
                    sum("styled payload" in action.get("send", "") for action in session["actions"])
                    != 250
                    for session in sessions
                )
            ):
                fail(errors, "fixture: concurrent connection scale contract differs")
        except (OSError, KeyError, TypeError, json.JSONDecodeError) as error:
            fail(errors, f"fixture: concurrent connection scenario is unreadable: {error}")
    contracts = manifest.get("sprintContracts", {})
    if set(contracts) != {"10.1", "10.2", "10.3", "10.4", "10.5"}:
        fail(errors, "manifest: later sprint contracts must cover 10.1 through 10.5")
    for sprint, contract in contracts.items():
        if contract.get("host") not in manifest.get("hosts", {}):
            fail(errors, f"manifest: sprint {sprint} names an unknown host")
        if not contract.get("commands"):
            fail(errors, f"manifest: sprint {sprint} has no exact commands")
        output = contract.get("outputDirectory", "")
        if output != f"Documentation/Evidence/M10/{contract.get('host')}/{sprint}":
            fail(errors, f"manifest: sprint {sprint} has a noncanonical output directory")
        if not contract.get("requiredRoles"):
            fail(errors, f"manifest: sprint {sprint} has no required artifact roles")
    if contracts.get("10.3", {}).get("planCommands") != [
        "BEIPMU_KEEP_APP_SOAK_ARTIFACTS=1 ./Scripts/profile-app-soak.sh"
    ]:
        fail(errors, "manifest: sprint 10.3 must retain the exact plan command")
    for relative_path in ("README.md", "Documentation/DISTRIBUTION.md"):
        path = ROOT / relative_path
        try:
            release_text = path.read_text(encoding="utf-8").lower()
        except OSError as error:
            fail(errors, f"release documentation is unreadable: {path}: {error}")
            continue
        if (
            "intel" not in release_text
            or "untested" not in release_text
            or "unsupported" not in release_text
        ):
            fail(
                errors,
                f"release documentation must label Intel untested and unsupported: {path}",
            )


def one_path(records: list[dict], role: str, errors: list[str]) -> Path | None:
    matches = [ROOT / item["path"] for item in records if item.get("role") == role]
    if len(matches) != 1:
        fail(errors, f"performance evidence: expected exactly one {role}, found {len(matches)}")
        return None
    return matches[0]


def validate_accessibility(records: list[dict], errors: list[str]) -> None:
    checklist_path = one_path(records, "accessibility-audio-checklist", errors)
    observation_path = one_path(records, "accessibility-observation", errors)
    trace_path = one_path(records, "media-server-trace", errors)
    confirmation_path = one_path(records, "human-audio-confirmation", errors)
    screenshot_paths = [
        ROOT / item["path"]
        for item in records
        if item.get("role") == "accessibility-screenshot"
    ]
    if not screenshot_paths:
        fail(errors, "accessibility evidence: no screenshots are registered")
    if not all(path.is_file() for path in screenshot_paths):
        fail(errors, "accessibility evidence: a registered screenshot is missing")
    if not all(
        path and path.is_file()
        for path in (
            checklist_path,
            observation_path,
            trace_path,
            confirmation_path,
        )
    ):
        return
    try:
        checklist = checklist_path.read_text(encoding="utf-8")
        if re.search(r"\b(?:incomplete|pending)\b", checklist, re.IGNORECASE):
            fail(errors, "accessibility evidence: checklist still contains pending work")
        required_checklist_phrases = {
            "Increase Contrast",
            "Differentiate Without Color",
            "Reduce Transparency",
            "Reduce Motion",
            "audible VoiceOver",
            "audible Client.Media",
            "audible selected-voice speech",
            "restored",
        }
        missing_phrases = required_checklist_phrases - set(
            phrase for phrase in required_checklist_phrases if phrase in checklist
        )
        if missing_phrases:
            fail(
                errors,
                "accessibility evidence: checklist is missing "
                + ", ".join(sorted(missing_phrases)),
            )

        observation = observation_path.read_text(encoding="utf-8")
        if (
            "VoiceOver" not in observation
            or "Client.Media" not in observation
            or "selected-voice speech" not in observation
        ):
            fail(errors, "accessibility evidence: observations omit an audible output")

        trace_events = [
            json.loads(line)
            for line in trace_path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
        if not any(
            event.get("event") == "request"
            and event.get("method") == "GET"
            and event.get("path") == "/Glass.aiff"
            and event.get("status") == 200
            and event.get("bytes", 0) > 0
            and SHA256.fullmatch(str(event.get("sha256", "")))
            for event in trace_events
        ):
            fail(errors, "accessibility evidence: successful Client.Media request is missing")

        confirmation = json.loads(confirmation_path.read_text(encoding="utf-8"))
        if (
            confirmation.get("schemaVersion") != 1
            or confirmation.get("voiceOverAudible") is not True
            or confirmation.get("clientMediaAudible") is not True
            or confirmation.get("selectedVoiceSpeechAudible") is not True
            or not confirmation.get("confirmedAt")
            or confirmation.get("confirmedBy") != "user"
        ):
            fail(errors, "accessibility evidence: all three human audio confirmations are required")
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
        fail(errors, f"accessibility evidence is unreadable: {error}")


def validate_performance(
    manifest: dict, records: list[dict], errors: list[str]
) -> None:
    budgets = manifest["performanceBudgets"]
    report_path = one_path(records, "benchmark-report", errors)
    time_path = one_path(records, "resource-statistics", errors)
    benchmark_leaks_path = one_path(records, "benchmark-leaks", errors)
    stdout_path = one_path(records, "app-stdout", errors)
    toc_path = one_path(records, "instruments-export", errors)
    app_leaks_path = one_path(records, "app-leaks", errors)
    verification_path = one_path(records, "soak-verification", errors)
    comparison_path = one_path(records, "performance-comparison", errors)
    if not all(
        path and path.is_file()
        for path in (
            report_path,
            time_path,
            benchmark_leaks_path,
            stdout_path,
            toc_path,
            app_leaks_path,
            verification_path,
            comparison_path,
        )
    ):
        return
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
        time_output = time_path.read_text(encoding="utf-8")
        peak_match = re.search(r"^\s*(\d+)\s+maximum resident set size$", time_output, re.MULTILINE)
        workspace_rss = int(peak_match.group(1)) if peak_match else 0
        if (
            report.get("passed") is not True
            or report.get("lineCount") != 250_000
            or report.get("historyLimit") != budgets["retainedHistoryLines"]
            or report.get("retainedLineCount") != budgets["retainedHistoryLines"]
            or report.get("historyLinesPerSecond", 0)
            < budgets["historyLinesPerSecondMinimum"]
            or report.get("layoutLinesPerSecond", 0)
            < budgets["layoutLinesPerSecondMinimum"]
            or report.get("queryOperationsPerSecond", 0)
            < budgets["viewportQueriesPerSecondMinimum"]
        ):
            fail(errors, "performance evidence: benchmark report violates a budget")
        if workspace_rss == 0 or workspace_rss > budgets["workspaceMaximumRSSBytes"]:
            fail(errors, "performance evidence: workspace RSS violates its budget")
        benchmark_leaks = benchmark_leaks_path.read_text(encoding="utf-8")
        if not re.search(r"0 leaks for 0 total leaked bytes", benchmark_leaks):
            fail(errors, "performance evidence: benchmark leak scan is not zero")

        app_stdout = stdout_path.read_text(encoding="utf-8")
        soak_match = re.search(r"^BEIPMU_SOAK_COMPLETE (?P<values>.+)$", app_stdout, re.MULTILINE)
        if not soak_match:
            fail(errors, "performance evidence: app completion report is missing")
            return
        soak_values = dict(
            component.split("=", 1)
            for component in soak_match.group("values").split()
            if "=" in component
        )
        if (
            int(soak_values.get("lines", 0)) != budgets["appSoakExpectedLines"]
            or int(soak_values.get("retained", 0)) != budgets["retainedHistoryLines"]
            or int(soak_values.get("rendered", 0)) != budgets["retainedHistoryLines"]
            or int(soak_values.get("paintCandidates", 0))
            > budgets["viewportCandidatesMaximum"]
            or int(soak_values.get("rssBytes", 0)) > budgets["appSoakMaximumRSSBytes"]
        ):
            fail(errors, "performance evidence: application soak violates a budget")
        toc = toc_path.read_text(encoding="utf-8")
        if "Time Profiler" not in toc or 'run number="1"' not in toc:
            fail(errors, "performance evidence: Instruments export is incomplete")
        verification = verification_path.read_text(encoding="utf-8")
        if (
            "BEIPMU_SOAK_COMPLETE" not in verification
            or "0 app-owned leaks" not in verification
            and "0 leaks / 0 bytes" not in verification
        ):
            fail(errors, "performance evidence: soak verification is incomplete")
        app_leaks = app_leaks_path.read_text(encoding="utf-8")
        if "BeipMU" in "\n".join(
            re.findall(r"STACK OF .*?(?=\nSTACK OF |\Z)", app_leaks, re.DOTALL)
        ):
            fail(errors, "performance evidence: app-owned leak stack is present")

        comparison = json.loads(comparison_path.read_text(encoding="utf-8"))
        current = comparison.get("current", {})
        if (
            comparison.get("baseline") != manifest["performanceComparison"]["baseline"]
            or comparison.get("materialRegressionPercent")
            != manifest["performanceComparison"]["materialRegressionPercent"]
            or current.get("historyLinesPerSecond") != report["historyLinesPerSecond"]
            or current.get("layoutLinesPerSecond") != report["layoutLinesPerSecond"]
            or current.get("viewportQueriesPerSecond") != report["queryOperationsPerSecond"]
            or current.get("workspaceRSSBytes") != workspace_rss
            or current.get("appRSSBytes") != int(soak_values["rssBytes"])
            or current.get("appSeconds") != float(soak_values["elapsedSeconds"])
            or not isinstance(comparison.get("measurements"), list)
        ):
            fail(errors, "performance evidence: baseline comparison disagrees with raw data")
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        fail(errors, f"performance evidence is unreadable: {error}")


def validate_plan_soak(
    manifest: dict, records: list[dict], errors: list[str]
) -> None:
    budgets = manifest["performanceBudgets"]
    stdout_path = one_path(records, "plan-command-app-stdout", errors)
    stderr_path = one_path(records, "plan-command-app-stderr", errors)
    toc_path = one_path(records, "plan-command-instruments-export", errors)
    trace_path = one_path(records, "plan-command-instruments-trace", errors)
    leaks_path = one_path(records, "plan-command-app-leaks", errors)
    verification_path = one_path(
        records, "plan-command-soak-verification", errors
    )
    if not all(
        path and path.is_file()
        for path in (
            stdout_path,
            stderr_path,
            toc_path,
            trace_path,
            leaks_path,
            verification_path,
        )
    ):
        return
    try:
        app_stdout = stdout_path.read_text(encoding="utf-8")
        soak_match = re.search(
            r"^BEIPMU_SOAK_COMPLETE (?P<values>.+)$", app_stdout, re.MULTILINE
        )
        if not soak_match:
            fail(errors, "plan-command soak: completion report is missing")
            return
        values = dict(
            component.split("=", 1)
            for component in soak_match.group("values").split()
            if "=" in component
        )
        if (
            int(values.get("lines", 0)) != budgets["appSoakExpectedLines"]
            or int(values.get("retained", 0)) != budgets["retainedHistoryLines"]
            or int(values.get("rendered", 0)) != budgets["retainedHistoryLines"]
            or int(values.get("paintCandidates", 0))
            > budgets["viewportCandidatesMaximum"]
            or int(values.get("rssBytes", 0)) > budgets["appSoakMaximumRSSBytes"]
        ):
            fail(errors, "plan-command soak: application budget violation")
        if stderr_path.read_text(encoding="utf-8"):
            fail(errors, "plan-command soak: application stderr is not empty")
        toc = toc_path.read_text(encoding="utf-8")
        if "Time Profiler" not in toc or 'run number="1"' not in toc:
            fail(errors, "plan-command soak: Instruments export is incomplete")
        with zipfile.ZipFile(trace_path) as archive:
            if not archive.namelist() or archive.testzip() is not None:
                fail(errors, "plan-command soak: Instruments archive is corrupt")
        verification = verification_path.read_text(encoding="utf-8")
        if "0 app-owned leaks" not in verification:
            fail(errors, "plan-command soak: leak verification is incomplete")
        leaks = leaks_path.read_text(encoding="utf-8")
        if "BeipMU" in "\n".join(
            re.findall(r"STACK OF .*?(?=\nSTACK OF |\Z)", leaks, re.DOTALL)
        ):
            fail(errors, "plan-command soak: app-owned leak stack is present")
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        zipfile.BadZipFile,
    ) as error:
        fail(errors, f"plan-command soak evidence is unreadable: {error}")


def validate_scale(
    manifest: dict, records: list[dict], errors: list[str]
) -> None:
    config_path = one_path(records, "large-configuration-result", errors)
    atlas_path = one_path(records, "large-atlas-result", errors)
    connections_path = one_path(records, "concurrent-connections-result", errors)
    resource_path = one_path(records, "scale-resource-statistics", errors)
    observation_path = one_path(records, "scale-observation", errors)
    leaks_path = one_path(records, "scale-app-leaks", errors)
    leak_verification_path = one_path(
        records, "scale-leak-verification", errors
    )
    if not all(
        path and path.is_file()
        for path in (
            config_path,
            atlas_path,
            connections_path,
            resource_path,
            observation_path,
            leaks_path,
            leak_verification_path,
        )
    ):
        return
    try:
        config = json.loads(config_path.read_text(encoding="utf-8"))
        if config.get("result") != "pass" or config.get("assertions") != {
            "aliases": 2_048,
            "characters": 256,
            "triggers": 2_048,
            "unknownAndWindowsOnlySyntaxPreserved": True,
            "worlds": 64,
        }:
            fail(errors, "scale evidence: large configuration assertions differ")

        atlas = json.loads(atlas_path.read_text(encoding="utf-8"))
        if atlas.get("result") != "pass" or atlas.get("assertions") != {
            "editUndoRedoSaveReload": True,
            "exits": 760,
            "navigationTrackingPathfinding": True,
            "rooms": 400,
            "unknownXMLPreserved": True,
        }:
            fail(errors, "scale evidence: large atlas assertions differ")

        connections = json.loads(connections_path.read_text(encoding="utf-8"))
        assertions = connections.get("assertions", {})
        if (
            connections.get("result") != "pass"
            or assertions.get("sessions") != 8
            or assertions.get("reconnectsPerSession") != 2
            or assertions.get("styledLines") != 6_000
            or assertions.get("gmcpAndEORNegotiated") is not True
            or assertions.get("crossSessionContamination") is not False
            or assertions.get("activeSessionsAfterClose") != 0
            or assertions.get("openLogsAfterClose") != 0
        ):
            fail(errors, "scale evidence: concurrent connection assertions differ")

        resource = json.loads(resource_path.read_text(encoding="utf-8"))
        if (
            resource.get("result") != "pass"
            or resource.get("rssBudgetAppliesTo") != "appPeakRSSBytes"
            or not 0 < resource.get("appPeakRSSBytes", 0)
            <= manifest["performanceBudgets"]["scaleScenarioMaximumRSSBytes"]
            or resource.get("retainedRendererRows", 0) > 10_000
            or resource.get("activeSessionsAfterClose") != 0
            or resource.get("openLogsAfterClose") != 0
        ):
            fail(errors, "scale evidence: RSS, renderer retention, or cleanup failed")

        observation = observation_path.read_text(encoding="utf-8")
        for phrase in (
            "main window remained responsive",
            "Keyboard focus and command submission remained responsive",
            "No hang, crash, unexplained mutation, silent loss, or cross-session text",
        ):
            if phrase not in observation:
                fail(errors, f"scale evidence: observation omits {phrase!r}")

        leaks = leaks_path.read_text(encoding="utf-8")
        leak_verification = leak_verification_path.read_text(encoding="utf-8")
        leak_summary = re.search(
            r"(?P<count>\d+) leaks for (?P<bytes>\d+) total leaked bytes", leaks
        )
        stack_text = leaks.split("\nBinary Images:", 1)[0]
        stacks = re.findall(
            r"STACK OF .*?(?=\nSTACK OF |\Z)", stack_text, re.DOTALL
        )
        zero_total = "0 leaks for 0 total leaked bytes" in leaks
        known_system = (
            leak_summary is not None
            and leak_summary.group("count") == "288"
            and leak_summary.group("bytes") == "18816"
            and bool(stacks)
            and all("LNProcessInstanceRegistryClient" in stack for stack in stacks)
            and all("BeipMU" not in stack for stack in stacks)
        )
        if (
            not (zero_total or known_system)
            or "0 app-owned leaks" not in leak_verification
        ):
            fail(errors, "scale evidence: app-owned leak scan is not zero")
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        fail(errors, f"scale evidence is unreadable: {error}")


def validate_closure(records: list[dict], errors: list[str]) -> None:
    smoke_path = one_path(records, "smoke-checklist", errors)
    slices_path = one_path(records, "universal-slice-inspection", errors)
    if not all(path and path.is_file() for path in (smoke_path, slices_path)):
        return
    expected_checks = {
        "atlas",
        "audio",
        "cleanShutdown",
        "connection",
        "launch",
        "restoration",
        "scriptService",
    }
    try:
        smoke = json.loads(smoke_path.read_text(encoding="utf-8"))
        checks = smoke.get("checks", {})
        observed_at = smoke.get("observedAt", "")
        try:
            parsed_observation = datetime.fromisoformat(
                observed_at.replace("Z", "+00:00")
            )
            dated_observation = parsed_observation.tzinfo is not None
        except (AttributeError, ValueError):
            dated_observation = False
        if (
            smoke.get("schemaVersion") != 1
            or smoke.get("host") != "macos26-apple-silicon"
            or smoke.get("observedBy") not in {"user", "codex"}
            or not dated_observation
            or not isinstance(checks, dict)
            or set(checks) != expected_checks
            or any(
                not isinstance(check, dict) or check.get("result") != "pass"
                or not str(check.get("notes", "")).strip()
                for check in checks.values()
            )
        ):
            fail(errors, "closure evidence: smoke checklist is incomplete")

        slices = json.loads(slices_path.read_text(encoding="utf-8"))
        binaries = slices.get("binaries", [])
        if (
            slices.get("schemaVersion") != 1
            or slices.get("result") != "pass"
            or slices.get("intelExecuted") is not False
            or slices.get("intelSupport") != "untested-and-unsupported"
            or not isinstance(binaries, list)
            or len(binaries) != 2
            or any(not isinstance(item, dict) for item in binaries)
            or {item.get("name") for item in binaries}
            != {"BeipMU", "BeipScriptService"}
            or any(
                item.get("architectures") != ["arm64", "x86_64"]
                for item in binaries
            )
        ):
            fail(errors, "closure evidence: universal slice inspection failed")
        archive_path = ROOT / slices.get("archivePath", "")
        if (
            not archive_path.is_file()
            or archive_path.parent != smoke_path.parent
            or digest(archive_path) != slices.get("archiveSHA256")
        ):
            fail(errors, "closure evidence: universal archive hash mismatch")
    except (OSError, TypeError, json.JSONDecodeError) as error:
        fail(errors, f"closure evidence is unreadable: {error}")


def validate_artifacts(manifest: dict, sprint: str | None, errors: list[str]) -> None:
    contracts = manifest.get("sprintContracts", {})
    selected = [sprint] if sprint else sorted(contracts)
    artifacts = manifest.get("artifacts", [])
    for selected_sprint in selected:
        contract = contracts.get(selected_sprint)
        if not contract:
            fail(errors, f"unknown sprint: {selected_sprint}")
            continue
        host = contract["host"]
        records = [
            item
            for item in artifacts
            if item.get("sprint") == selected_sprint and item.get("host") == host
        ]
        roles = {item.get("role") for item in records}
        missing_roles = set(contract["requiredRoles"]) - roles
        if missing_roles:
            fail(
                errors,
                f"sprint {selected_sprint}: missing artifact roles "
                + ", ".join(sorted(missing_roles)),
            )
        command_results = [
            item for item in records if item.get("role") == "command-result"
        ]
        result_commands = {item.get("command") for item in command_results}
        log_commands = {
            item.get("command") for item in records if item.get("role") == "command-log"
        }
        expected_commands = set(contract["commands"]) | set(
            contract.get("planCommands", [])
        )
        missing_commands = expected_commands - result_commands
        if selected_sprint in {"10.1", "10.3", "10.5"} and missing_commands:
            fail(
                errors,
                f"sprint {selected_sprint}: missing command results "
                + ", ".join(sorted(missing_commands)),
            )
        if (
            selected_sprint in {"10.1", "10.3", "10.5"}
            and expected_commands - log_commands
        ):
            fail(errors, f"sprint {selected_sprint}: command logs are incomplete")
        for record in records:
            missing_fields = REQUIRED_ARTIFACT_FIELDS - record.keys()
            if missing_fields:
                fail(
                    errors,
                    f"artifact {record.get('path', '<unknown>')}: missing fields "
                    + ", ".join(sorted(missing_fields)),
                )
                continue
            if FORBIDDEN_METADATA_KEYS & record.keys():
                fail(errors, f"artifact {record['path']}: contains sensitive host identity")
            if record["architecture"] != "arm64":
                fail(errors, f"artifact {record['path']}: architecture is not arm64")
            if record["result"] != "pass":
                fail(errors, f"artifact {record['path']}: result is {record['result']!r}")
            if not COMMIT.fullmatch(record["gitCommit"]):
                fail(errors, f"artifact {record['path']}: invalid Git commit")
            if not SHA256.fullmatch(record["sha256"]):
                fail(errors, f"artifact {record['path']}: invalid SHA-256")
            path = ROOT / record["path"]
            if not path.is_file():
                fail(errors, f"artifact missing: {path}")
            elif digest(path) != record["sha256"]:
                fail(errors, f"artifact hash mismatch: {path}")
            elif record["role"] == "command-log":
                log = path.read_text(encoding="utf-8", errors="replace")
                if re.search(r"/Users/[^/ ]+|\bid:[A-Fa-f0-9-]{8,}", log):
                    fail(errors, f"artifact {record['path']}: unsanitized host identity")
            elif record["role"] == "command-result":
                try:
                    command_result = json.loads(path.read_text(encoding="utf-8"))
                    if (
                        command_result.get("command") != record["command"]
                        or command_result.get("exitCode") != 0
                        or command_result.get("result") != "pass"
                    ):
                        fail(errors, f"artifact {record['path']}: command result did not pass")
                except (OSError, json.JSONDecodeError) as error:
                    fail(errors, f"artifact {record['path']}: unreadable result: {error}")
            elif record["role"] in {
                "instruments-trace",
                "plan-command-instruments-trace",
                "universal-package",
                "xcuitest-result-bundle",
                "xcuitest-attachments",
            }:
                try:
                    with zipfile.ZipFile(path) as archive:
                        if not archive.namelist() or archive.testzip() is not None:
                            fail(errors, f"artifact {record['path']}: invalid ZIP archive")
                except zipfile.BadZipFile:
                    fail(errors, f"artifact {record['path']}: invalid ZIP archive")
            if selected_sprint == "10.5" and not record["osVersion"].startswith("26."):
                fail(errors, f"artifact {record['path']}: macOS 26 host required")
        if selected_sprint == "10.2":
            validate_accessibility(records, errors)
        if selected_sprint in {"10.3", "10.5"}:
            validate_performance(manifest, records, errors)
        if selected_sprint == "10.3":
            validate_plan_soak(manifest, records, errors)
        if selected_sprint == "10.4":
            validate_scale(manifest, records, errors)
        if selected_sprint == "10.5":
            validate_closure(records, errors)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--contract-only", action="store_true")
    parser.add_argument("--sprint", choices=["10.1", "10.2", "10.3", "10.4", "10.5"])
    args = parser.parse_args()
    if args.contract_only and args.sprint:
        parser.error("--contract-only and --sprint are mutually exclusive")
    try:
        manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"M10 manifest unreadable: {error}", file=sys.stderr)
        return 1
    errors: list[str] = []
    validate_contract(manifest, errors)
    if not args.contract_only:
        validate_artifacts(manifest, args.sprint, errors)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    if args.contract_only:
        print("M10 evidence contract verified")
    elif args.sprint:
        print(f"M10 sprint {args.sprint} evidence verified")
    else:
        print("M10 evidence corpus verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
