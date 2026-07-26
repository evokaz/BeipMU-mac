#!/usr/bin/env python3
"""Verify the Milestone 11 release contract and evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = ROOT / "Documentation" / "Evidence" / "M11" / "manifest.json"
SHA256 = re.compile(r"^[0-9a-f]{64}$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")
TIMESTAMP = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$")
FORBIDDEN_METADATA_KEYS = {"serial", "serialNumber", "deviceID", "deviceId", "udid"}
ARTIFACT_FIELDS = {
    "architecture", "command", "gitCommit", "host", "osBuild", "osVersion",
    "path", "result", "role", "sha256", "sprint", "swiftVersion",
    "timestamp", "xcodeVersion",
}
EXPECTED_COMMANDS = {
    "11.1": [
        "./Scripts/audit-upstream.sh",
        "python3 Scripts/generate-parity-items.py --check",
        "python3 Scripts/verify-parity-matrix.py --check",
    ],
    "11.2": [
        "./Scripts/audit-upstream.sh",
        "python3 Scripts/generate-parity-items.py --check",
        "python3 Scripts/verify-parity-matrix.py --check",
        "python3 Scripts/verify-reference-artifacts.py",
        "python3 Scripts/verify-ui-differentials.py",
        "swift test",
        "./Scripts/test-ui.sh",
        "./Scripts/benchmark-workspace.sh",
        "BEIPMU_KEEP_APP_SOAK_ARTIFACTS=1 ./Scripts/profile-app-soak.sh",
        "git diff --check",
    ],
    "11.3": [
        "./Scripts/package-release.sh",
        "lipo -archs DerivedData/Build/Products/Release/BeipMU.app/Contents/MacOS/BeipMU",
        "lipo -archs DerivedData/Build/Products/Release/BeipMU.app/Contents/XPCServices/BeipScriptService.xpc/Contents/MacOS/BeipScriptService",
        "codesign --verify --deep --strict DerivedData/Build/Products/Release/BeipMU.app",
        "codesign -d --entitlements :- DerivedData/Build/Products/Release/BeipMU.app",
        "plutil -extract CFBundleIdentifier raw DerivedData/Build/Products/Release/BeipMU.app/Contents/Info.plist",
        "plutil -extract CFBundleIdentifier raw DerivedData/Build/Products/Release/BeipMU.app/Contents/XPCServices/BeipScriptService.xpc/Contents/Info.plist",
        "unzip -t dist/BeipMU-macOS-universal.zip",
        "cd dist && shasum -a 256 -c BeipMU-macOS-universal.zip.sha256",
    ],
    "11.4": [
        "python3 Scripts/generate-parity-items.py --check",
        "python3 Scripts/verify-parity-matrix.py --check",
        "python3 Scripts/verify-reference-artifacts.py",
        "python3 Scripts/verify-ui-differentials.py",
        "python3 Scripts/verify-m11-evidence.py",
    ],
    "11.5": [
        "python3 Scripts/generate-parity-items.py --check",
        "python3 Scripts/verify-parity-matrix.py --check",
        "python3 Scripts/verify-reference-artifacts.py",
        "python3 Scripts/verify-ui-differentials.py",
        "./Scripts/package-release.sh",
        "python3 Scripts/verify-m11-evidence.py",
    ],
}


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def fail(errors: list[str], message: str) -> None:
    errors.append(message)


def walk_keys(value: object):
    if isinstance(value, dict):
        for key, child in value.items():
            yield key
            yield from walk_keys(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk_keys(child)


def validate_contract(manifest: dict, errors: list[str]) -> None:
    if manifest.get("contractVersion") != 1:
        fail(errors, "manifest: contractVersion must be 1")
    release = manifest.get("release", {})
    if release.get("version") != "v331-mac.1" or release.get("tag") != "v331-mac.1":
        fail(errors, "manifest: release version and tag must be v331-mac.1")
    if release.get("branch") != "codex/m11-release-candidate":
        fail(errors, "manifest: release branch differs from the sprint plan")
    reference = release.get("windowsReference", {})
    if reference != {
        "commit": "3d43fe9327e18dcc30a38b2f7422f558b95a4c3c",
        "version": "v331",
    }:
        fail(errors, "manifest: supported Windows v331 identity differs")
    if release.get("bundleIdentifiers") != {
        "application": "org.beipmu.BeipMU",
        "embeddedService": "org.beipmu.BeipMU.ScriptService",
    }:
        fail(errors, "manifest: required bundle identifiers differ")
    host = release.get("supportedHost", {})
    if host != {"architecture": "arm64", "hardware": "Apple silicon", "osMajor": 26}:
        fail(errors, "manifest: release host must be Apple silicon on macOS 26")
    names = release.get("artifactNames", {})
    expected_names = {
        "application": "BeipMU.app",
        "checksum": "BeipMU-macOS-universal.zip.sha256",
        "embeddedService": "BeipScriptService.xpc",
        "handoffKit": "BeipMU-v331-mac.1-manual-handoff",
        "releaseNotes": "RELEASE_NOTES.md",
        "report": "MILESTONE11_AUDIT.md",
        "zip": "BeipMU-macOS-universal.zip",
    }
    if names != expected_names:
        fail(errors, "manifest: artifact names differ from the release contract")

    contracts = manifest.get("sprintContracts", {})
    if set(contracts) != set(EXPECTED_COMMANDS):
        fail(errors, "manifest: later sprint contracts must cover 11.1 through 11.5")
    for sprint, commands in EXPECTED_COMMANDS.items():
        contract = contracts.get(sprint, {})
        if contract.get("commands") != commands:
            fail(errors, f"manifest: sprint {sprint} commands differ from the plan")
        expected_output = {
            "11.1": "Documentation/Evidence/M11/11.1-baseline-freeze",
            "11.2": "Documentation/Evidence/M11/11.2-clean-verification",
            "11.3": "Documentation/Evidence/M11/11.3-package",
            "11.4": "Documentation/Evidence/M11/11.4-report",
            "11.5": "Documentation/Evidence/M11/11.5-final",
        }[sprint]
        if contract.get("outputDirectory") != expected_output:
            fail(errors, f"manifest: sprint {sprint} output directory differs")
        if not contract.get("inputs") or not contract.get("requiredRoles"):
            fail(errors, f"manifest: sprint {sprint} inputs or roles are empty")

    for relative in (
        "Documentation/Evidence/M11/README.md",
        "Documentation/Evidence/M11/CLEAN_CHECKOUT.md",
        "Documentation/Evidence/M11/MANUAL_HANDOFF_CHECKLIST.md",
        "Documentation/DISTRIBUTION.md",
        "LICENSE",
    ):
        if not (ROOT / relative).is_file():
            fail(errors, f"contract file missing: {relative}")
    if FORBIDDEN_METADATA_KEYS.intersection(walk_keys(manifest)):
        fail(errors, "manifest: stable device identifiers are forbidden")


def validate_artifact(record: dict, release_commit: str, errors: list[str]) -> None:
    missing = ARTIFACT_FIELDS - set(record)
    if missing:
        fail(errors, f"artifact missing fields: {', '.join(sorted(missing))}")
        return
    label = f"{record.get('sprint')}:{record.get('role')}:{record.get('path')}"
    if record.get("result") != "pass":
        fail(errors, f"{label}: result must be pass")
    if not COMMIT.fullmatch(str(record.get("gitCommit", ""))):
        fail(errors, f"{label}: Git commit must be 40 lowercase hex")
    if record.get("sprint") == "11.5" and record.get("gitCommit") != release_commit:
        fail(errors, f"{label}: final evidence Git commit differs from releaseCommit")
    if not SHA256.fullmatch(str(record.get("sha256", ""))):
        fail(errors, f"{label}: invalid SHA-256")
    if not TIMESTAMP.fullmatch(str(record.get("timestamp", ""))):
        fail(errors, f"{label}: timestamp must be UTC ISO-8601")
    if not all(record.get(field) for field in (
        "architecture", "command", "host", "osBuild", "osVersion",
        "swiftVersion", "xcodeVersion",
    )):
        fail(errors, f"{label}: host/toolchain metadata is incomplete")
    if record.get("architecture") != "arm64":
        fail(errors, f"{label}: producer architecture must be arm64")
    path_text = str(record.get("path", ""))
    if path_text.startswith("/") or ".." in Path(path_text).parts:
        fail(errors, f"{label}: path must be repository-relative")
        return
    path = ROOT / path_text
    if path.is_file() and digest(path) != record.get("sha256"):
        fail(errors, f"{label}: file hash mismatch")
    elif not path.is_file() and not path_text.startswith("dist/"):
        fail(errors, f"{label}: checked-in artifact is missing")


def record_json(records: list[dict], role: str, errors: list[str]) -> dict | None:
    matches = [ROOT / item["path"] for item in records if item.get("role") == role]
    if not matches:
        return None
    for path in matches:
        if path.suffix == ".json" and path.is_file():
            try:
                return json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as error:
                fail(errors, f"evidence: unreadable {role}: {error}")
                return None
    return None


def validate_semantics(manifest: dict, records: list[dict], errors: list[str]) -> None:
    release = manifest["release"]
    commit = release["releaseCommit"]
    freeze = record_json(records, "upstream-freeze", errors)
    if freeze and (
        freeze.get("windowsVersion") != "v331"
        or freeze.get("upstreamCommit") != release["windowsReference"]["commit"]
        or freeze.get("immutable") is not True
    ):
        fail(errors, "upstream freeze does not identify immutable Windows v331")

    for result_record in [
        ROOT / item["path"] for item in records if item.get("role") == "command-result"
    ]:
        try:
            result = json.loads(result_record.read_text(encoding="utf-8"))
            matching = next(
                (item for item in records if ROOT / item["path"] == result_record),
                {},
            )
            if (
                result.get("command") not in EXPECTED_COMMANDS.get(result.get("sprint"), [])
                or result.get("exitCode") != 0
                or result.get("result") != "pass"
                or result.get("gitCommit") != matching.get("gitCommit")
                or not result.get("stdoutPath")
                or not result.get("stderrPath")
            ):
                fail(errors, f"command result is incomplete or failed: {result_record}")
        except (OSError, json.JSONDecodeError):
            fail(errors, f"command result is unreadable: {result_record}")

    architecture = record_json(records, "architecture-inspection", errors)
    if architecture:
        for component in ("application", "embeddedService"):
            if set(architecture.get(component, {}).get("architectures", [])) != {
                "arm64", "x86_64"
            }:
                fail(errors, f"architecture inspection: {component} is not universal")
        if architecture.get("intelTested") is not False or architecture.get("intelSupported") is not False:
            fail(errors, "architecture inspection: Intel must be untested and unsupported")
    identifiers = record_json(records, "identifier-inspection", errors)
    if identifiers and identifiers.get("bundleIdentifiers") != release["bundleIdentifiers"]:
        fail(errors, "identifier inspection: bundle identifiers differ")
    signature = record_json(records, "signature-inspection", errors)
    if signature and (
        signature.get("deepStrictExitCode") != 0 or signature.get("kind") != "ad-hoc"
    ):
        fail(errors, "signature inspection: deep strict ad-hoc validation did not pass")
    attribution = record_json(records, "attribution-inspection", errors)
    if attribution and not all(
        attribution.get(key) is True
        for key in ("licenseIncluded", "installIncluded", "mitAttributionCorrect")
    ):
        fail(errors, "attribution inspection is incomplete")
    rebuild = record_json(records, "rebuild-comparison", errors)
    if rebuild and (
        rebuild.get("sameGitCommit") is not True
        or rebuild.get("observableContentsMatch") is not True
        or rebuild.get("containerBytesMatch") not in (True, False)
    ):
        fail(errors, "rebuild comparison is incomplete")

    report_paths = [
        ROOT / item["path"] for item in records if item.get("role") == "final-parity-report"
    ]
    if report_paths:
        report = report_paths[-1].read_text(encoding="utf-8")
        required = (
            "v331", release["windowsReference"]["commit"], "v331-mac.1",
            "Milestone 8", "Milestone 9", "Milestone 10", "Intel",
            "untested", "unsupported",
        )
        if any(value not in report for value in required):
            fail(errors, "final report is missing a required release identity or disclosure")
        if COMMIT.fullmatch(str(commit or "")) and commit not in report:
            fail(errors, "final report is missing the final release commit")
        if re.search(
            r"\b(?:TODO|TBD)\b|(?<!no )\bunresolved required\b",
            report,
            re.IGNORECASE,
        ):
            fail(errors, "final report contains unresolved placeholder text")

    checklist_paths = [
        ROOT / item["path"] for item in records if item.get("role") == "manual-handoff-checklist"
    ]
    if checklist_paths:
        checklist = checklist_paths[-1].read_text(encoding="utf-8")
        if "- [ ]" in checklist or "<" in checklist or commit not in checklist:
            fail(errors, "manual handoff checklist is incomplete")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--contract-only", action="store_true")
    parser.add_argument("--sprint", choices=sorted(EXPECTED_COMMANDS))
    args = parser.parse_args()
    try:
        manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"M11 evidence verification failed: {error}", file=sys.stderr)
        return 1

    errors: list[str] = []
    validate_contract(manifest, errors)
    if not args.contract_only:
        release_commit = manifest.get("release", {}).get("releaseCommit")
        release_commit_required = args.sprint == "11.5"
        if release_commit_required and not COMMIT.fullmatch(str(release_commit or "")):
            fail(errors, "manifest: releaseCommit must be set to 40 lowercase hex")
        records = manifest.get("artifacts")
        if not isinstance(records, list) or not records:
            fail(errors, "manifest: no release evidence is registered")
            records = []
        selected = [
            item for item in records
            if isinstance(item, dict)
            and (args.sprint is None or item.get("sprint") == args.sprint)
        ]
        required_sprints = [args.sprint] if args.sprint else sorted(
            sprint for sprint in EXPECTED_COMMANDS
            if sprint != "11.5" or COMMIT.fullmatch(str(release_commit or ""))
        )
        for sprint in required_sprints:
            sprint_records = [item for item in selected if item.get("sprint") == sprint]
            roles = {item.get("role") for item in sprint_records}
            missing = set(manifest["sprintContracts"][sprint]["requiredRoles"]) - roles
            if missing:
                fail(errors, f"sprint {sprint}: missing roles {', '.join(sorted(missing))}")
            result_commands = {
                item.get("command") for item in sprint_records
                if item.get("role") == "command-result"
            }
            missing_commands = set(EXPECTED_COMMANDS[sprint]) - result_commands
            if missing_commands:
                fail(errors, f"sprint {sprint}: missing command results")
        for record in selected:
            validate_artifact(record, str(release_commit or ""), errors)
        validate_semantics(manifest, selected, errors)

    if errors:
        print("M11 evidence verification failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    if args.contract_only:
        mode = "contract"
    elif args.sprint:
        mode = args.sprint
    elif COMMIT.fullmatch(str(manifest.get("release", {}).get("releaseCommit") or "")):
        mode = "complete release"
    else:
        mode = "through 11.4"
    print(f"M11 evidence verification passed ({mode}).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
