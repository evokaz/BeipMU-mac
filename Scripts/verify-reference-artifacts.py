#!/usr/bin/env python3
"""Verify that out-of-tree reference artifacts match the checked-in manifest."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys


REPOSITORY = Path(__file__).resolve().parent.parent
MANIFEST = REPOSITORY / "Documentation" / "REFERENCE_ARTIFACTS.json"
GOLDEN_MANIFEST = REPOSITORY / "Tests" / "Golden" / "manifest.json"
REQUIRED_GOLDEN_ROLES = {
    "startup-screenshot",
    "session-screenshot",
    "normalized-byte-trace",
    "post-session-configuration",
    "post-session-restore-log",
}


def main() -> int:
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    failures: list[str] = []
    for artifact in manifest["artifacts"]:
        path = (REPOSITORY / artifact["pathRelativeToRepository"]).resolve()
        if not path.is_file():
            failures.append(f"missing: {path}")
            continue
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != artifact["sha256"]:
            failures.append(f"checksum mismatch: {path}")
        expected_size = artifact.get("sizeBytes")
        if expected_size is not None and path.stat().st_size != expected_size:
            failures.append(f"size mismatch: {path}")
        print(f"verified {artifact['role']}: {path}")

    golden = json.loads(GOLDEN_MANIFEST.read_text(encoding="utf-8"))
    roles = {artifact["role"] for artifact in golden["artifacts"]}
    for missing_role in sorted(REQUIRED_GOLDEN_ROLES - roles):
        failures.append(f"missing golden role: {missing_role}")
    if golden["referenceBinarySHA256"] != manifest["artifacts"][0]["sha256"]:
        failures.append("golden corpus references a different Windows binary")
    for artifact in golden["artifacts"]:
        path = GOLDEN_MANIFEST.parent / artifact["path"]
        if not path.is_file():
            failures.append(f"missing golden: {path}")
            continue
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != artifact["sha256"]:
            failures.append(f"golden checksum mismatch: {path}")
        print(f"verified golden {artifact['role']}: {path}")

    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
