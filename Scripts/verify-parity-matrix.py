#!/usr/bin/env python3
"""Validate the Milestone 6 parity inventory and its checked-in summaries."""

from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import sys


REPOSITORY = Path(__file__).resolve().parent.parent
MATRIX_PATH = REPOSITORY / "Documentation" / "PARITY_ITEMS.json"
SUMMARY_DOCUMENTS = (
    REPOSITORY / "Documentation" / "PARITY.md",
    REPOSITORY / "Documentation" / "UPSTREAM_INVENTORY.md",
    REPOSITORY / "Documentation" / "PARITY_RELEASE_PLAN.md",
)
SUMMARY_PREFIX = "<!-- parity-matrix-summary:"
ALLOWED_STATUSES = {
    "implemented",
    "preserved",
    "implementation-gap",
    "compile-time-excluded",
    "release-excluded",
    "platform-exception",
}
ALLOWED_DISPOSITIONS = {
    "implemented",
    "preservation-only",
    "implementation-gap",
    "compile-time-excluded",
    "release-excluded",
    "platform-exception",
}
ALLOWED_EVIDENCE_CLASSES = {
    "unit",
    "integration",
    "ui",
    "differential",
    "round-trip",
    "device",
    "performance",
    "milestone-audit",
}
REQUIRED_ITEM_KEYS = {
    "category",
    "identifier",
    "upstreamReference",
    "expectedBehavior",
    "windowsReference",
    "macStatus",
    "releaseDisposition",
    "evidence",
    "differentialFixture",
}


def summary_marker(matrix: dict) -> str:
    statuses = "; ".join(
        f"{key}={matrix['statusCounts'][key]}" for key in sorted(matrix["statusCounts"])
    )
    dispositions = "; ".join(
        f"{key}={matrix['releaseDispositionCounts'][key]}"
        for key in sorted(matrix["releaseDispositionCounts"])
    )
    return f"{SUMMARY_PREFIX} itemCount={matrix['itemCount']}; macStatus={statuses}; releaseDisposition={dispositions} -->"


def fail(message: str, errors: list[str]) -> None:
    errors.append(message)


def validate(matrix: dict) -> list[str]:
    errors: list[str] = []
    items = matrix.get("items")
    if not isinstance(items, list):
        return ["matrix.items must be an array"]
    if matrix.get("schemaVersion") != 2:
        fail("matrix schemaVersion must be 2", errors)
    if matrix.get("itemCount") != len(items):
        fail(f"itemCount={matrix.get('itemCount')} but found {len(items)} items", errors)

    statuses = Counter()
    dispositions = Counter()
    evidence_classes = Counter()
    seen: set[tuple[str, str]] = set()
    for index, item in enumerate(items):
        label = f"items[{index}]"
        missing = REQUIRED_ITEM_KEYS - item.keys()
        if missing:
            fail(f"{label} missing keys: {', '.join(sorted(missing))}", errors)
            continue
        identity = (item["category"], item["identifier"])
        if identity in seen:
            fail(f"duplicate matrix row: {identity[0]} {identity[1]}", errors)
        seen.add(identity)

        status = item["macStatus"]
        disposition = item["releaseDisposition"]
        statuses[status] += 1
        dispositions[disposition] += 1
        if status not in ALLOWED_STATUSES:
            fail(f"{label} has unresolved/stale macStatus {status!r}", errors)
        if disposition not in ALLOWED_DISPOSITIONS:
            fail(f"{label} has invalid releaseDisposition {disposition!r}", errors)
        expected_disposition = {
            "implemented": "implemented",
            "preserved": "preservation-only",
            "implementation-gap": "implementation-gap",
            "compile-time-excluded": "compile-time-excluded",
            "release-excluded": "release-excluded",
            "platform-exception": "platform-exception",
        }.get(status)
        if disposition != expected_disposition:
            fail(f"{label} maps {status!r} to {disposition!r}, expected {expected_disposition!r}", errors)

        evidence = item["evidence"]
        if not isinstance(evidence, dict):
            fail(f"{label}.evidence must be an object", errors)
            continue
        evidence_class = evidence.get("class")
        evidence_classes[evidence_class] += 1
        if evidence_class not in ALLOWED_EVIDENCE_CLASSES:
            fail(f"{label} has invalid evidence class {evidence_class!r}", errors)
        if evidence.get("status") != "accepted":
            fail(f"{label} evidence is not accepted", errors)
        paths = evidence.get("paths")
        if not isinstance(paths, list) or not paths:
            fail(f"{label} must name at least one evidence path", errors)
        else:
            for path in paths:
                if not isinstance(path, str) or not path:
                    fail(f"{label} contains an invalid evidence path", errors)
                elif not (REPOSITORY / path).exists():
                    fail(f"{label} evidence path does not exist: {path}", errors)
        if status == "preserved" and evidence_class != "round-trip":
            fail(f"{label} preservation-only row must use round-trip evidence", errors)
        if status == "implementation-gap":
            if evidence_class != "milestone-audit" or evidence.get("targetMilestone") != 7:
                fail(f"{label} gap must be assigned to Milestone 7 with audit evidence", errors)
        if status != "implementation-gap" and "pending" in item["differentialFixture"].lower():
            fail(f"{label} has pending fixture text", errors)

    if dict(statuses) != matrix.get("statusCounts"):
        fail(f"statusCounts disagree: generated {dict(statuses)}, stored {matrix.get('statusCounts')}", errors)
    if dict(dispositions) != matrix.get("releaseDispositionCounts"):
        fail(
            f"releaseDispositionCounts disagree: generated {dict(dispositions)}, stored {matrix.get('releaseDispositionCounts')}",
            errors,
        )
    if dict(evidence_classes) != matrix.get("evidenceClassCounts"):
        fail(f"evidenceClassCounts disagree: generated {dict(evidence_classes)}, stored {matrix.get('evidenceClassCounts')}", errors)

    marker = summary_marker(matrix)
    for document in SUMMARY_DOCUMENTS:
        text = document.read_text(encoding="utf-8") if document.exists() else ""
        if marker not in text:
            fail(f"{document.relative_to(REPOSITORY)} is missing the canonical matrix summary", errors)
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="validate the checked-in matrix")
    args = parser.parse_args()
    if not args.check:
        parser.error("use --check")
    try:
        matrix = json.loads(MATRIX_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"cannot read {MATRIX_PATH}: {error}", file=sys.stderr)
        return 1
    errors = validate(matrix)
    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"verified {matrix['itemCount']} parity rows; {summary_marker(matrix)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
