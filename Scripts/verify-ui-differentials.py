#!/usr/bin/env python3
"""Verify checksum-pinned Windows-to-macOS native UI differential evidence."""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
AUDIT_PATH = ROOT / "Documentation/UI_DIFFERENTIALS.json"
BASELINE_DIRECTORY = ROOT / "UITests/Baselines"


def fail(message: str) -> None:
    raise ValueError(message)


def load_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8-sig") as source:
        value = json.load(source)
    if not isinstance(value, dict):
        fail(f"expected JSON object: {path.relative_to(ROOT)}")
    return value


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_file(record: dict[str, Any], context: str) -> Path:
    relative = record.get("path")
    expected = record.get("sha256")
    if not isinstance(relative, str) or not isinstance(expected, str):
        fail(f"{context} requires path and sha256 strings")
    path = ROOT / relative
    if not path.is_file():
        fail(f"missing {context}: {relative}")
    actual = sha256(path)
    if actual != expected:
        fail(f"checksum mismatch for {relative}: expected {expected}, got {actual}")
    return path


def main() -> int:
    try:
        audit = load_json(AUDIT_PATH)
        if audit.get("schemaVersion") != 1:
            fail("unsupported UI differential schemaVersion")
        policy = audit.get("policy", {})
        if policy.get("mode") != "semantic-native" or not policy.get("rationale"):
            fail("audit must declare and explain the semantic-native policy")

        manifest_record = audit.get("windowsManifest")
        if not isinstance(manifest_record, dict):
            fail("missing windowsManifest")
        manifest_path = verify_file(manifest_record, "Windows manifest")
        golden_manifest = load_json(manifest_path)
        golden_hashes = {
            f"Tests/Golden/{artifact['path']}": artifact["sha256"]
            for artifact in golden_manifest.get("artifacts", [])
        }

        ui_test_path = ROOT / "UITests/BeipMUXCUITests.swift"
        test_sources = "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted((ROOT / "Tests").rglob("*.swift"))
        )
        ui_test_source = ui_test_path.read_text(encoding="utf-8")
        application_sources = "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted((ROOT / "Sources").rglob("*.swift"))
        )
        searchable_ui = application_sources + "\n" + ui_test_source

        baseline_records = audit.get("macOSBaselines")
        if not isinstance(baseline_records, list) or not baseline_records:
            fail("macOSBaselines must be a nonempty list")
        declared_baselines: dict[str, dict[str, Any]] = {}
        for record in baseline_records:
            if not isinstance(record, dict):
                fail("invalid macOS baseline record")
            verify_file(record, "macOS baseline")
            relative = record["path"]
            if relative in declared_baselines:
                fail(f"duplicate macOS baseline: {relative}")
            declared_baselines[relative] = record
            test = record.get("test")
            if not isinstance(test, str) or f"func {test}(" not in ui_test_source:
                fail(f"missing XCUITest method {test!r} for {relative}")

        disk_baselines = {
            str(path.relative_to(ROOT)) for path in BASELINE_DIRECTORY.glob("*.png")
        }
        if disk_baselines != set(declared_baselines):
            missing = sorted(disk_baselines - set(declared_baselines))
            stale = sorted(set(declared_baselines) - disk_baselines)
            fail(f"baseline inventory mismatch; undeclared={missing}, missing={stale}")

        differentials = audit.get("differentials")
        if not isinstance(differentials, list) or not differentials:
            fail("differentials must be a nonempty list")
        seen_ids: set[str] = set()
        assertion_count = 0
        difference_count = 0
        windows_count = 0
        for differential in differentials:
            if not isinstance(differential, dict):
                fail("invalid differential record")
            differential_id = differential.get("id")
            if not isinstance(differential_id, str) or differential_id in seen_ids:
                fail(f"missing or duplicate differential id: {differential_id!r}")
            seen_ids.add(differential_id)

            windows = differential.get("windows")
            if not isinstance(windows, dict):
                fail(f"{differential_id}: missing Windows evidence")
            verify_file(windows, f"{differential_id} Windows evidence")
            windows_count += 1
            if golden_hashes.get(windows["path"]) != windows["sha256"]:
                fail(f"{differential_id}: Windows evidence is not pinned by the golden manifest")

            macos = differential.get("macOS")
            if not isinstance(macos, dict):
                fail(f"{differential_id}: missing macOS evidence")
            referenced_baselines = [macos.get("baseline"), *macos.get("supportingBaselines", [])]
            for baseline in referenced_baselines:
                if baseline not in declared_baselines:
                    fail(f"{differential_id}: undeclared macOS baseline {baseline!r}")

            fixture = differential.get("protocolFixture")
            if fixture is not None:
                if not isinstance(fixture, dict):
                    fail(f"{differential_id}: invalid protocolFixture")
                verify_file(fixture, f"{differential_id} protocol fixture")
                if golden_hashes.get(fixture["path"]) != fixture["sha256"]:
                    fail(f"{differential_id}: protocol fixture is not pinned by the golden manifest")
                test = fixture.get("test")
                if not isinstance(test, str) or f"func {test}(" not in test_sources:
                    fail(f"{differential_id}: missing protocol test {test!r}")

            assertions = differential.get("semanticAssertions")
            if not isinstance(assertions, list) or not assertions:
                fail(f"{differential_id}: no semantic assertions")
            for assertion in assertions:
                assertion_count += 1
                if assertion.get("status") != "pass":
                    fail(f"{differential_id}/{assertion.get('id')}: semantic assertion does not pass")
                if not assertion.get("windowsEvidence") or not assertion.get("macOSEvidence"):
                    fail(f"{differential_id}/{assertion.get('id')}: missing evidence explanation")
                identifiers = assertion.get("accessibilityIdentifiers")
                if not isinstance(identifiers, list) or not identifiers:
                    fail(f"{differential_id}/{assertion.get('id')}: missing accessibility identifiers")
                for identifier in identifiers:
                    if not isinstance(identifier, str) or f'"{identifier}"' not in searchable_ui:
                        fail(f"{differential_id}/{assertion.get('id')}: UI identifier {identifier!r} is not wired")

            differences = differential.get("nativeDifferences")
            if not isinstance(differences, list):
                fail(f"{differential_id}: nativeDifferences must be a list")
            for difference in differences:
                difference_count += 1
                if difference.get("scopeDisposition") not in {
                    "native-equivalent", "deferred-out-of-scope"
                }:
                    fail(f"{differential_id}: invalid native difference disposition")
                if not difference.get("id") or not difference.get("rationale"):
                    fail(f"{differential_id}: undocumented native difference")

        print(
            "UI differential audit passed: "
            f"{windows_count} Windows references, "
            f"{len(declared_baselines)} macOS baselines, "
            f"{assertion_count} semantic assertions, "
            f"{difference_count} documented native differences."
        )
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"UI differential audit failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
