#!/usr/bin/env python3
"""Verify the Windows M8 native-capture manifest from any Git checkout."""

from __future__ import annotations

import hashlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / "Documentation" / "Evidence" / "M8" / "win11-dev"
MANIFEST = EVIDENCE / "windows-m8-native-captures-hashes.sha256"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> int:
    failures: list[str] = []
    normalized = 0
    entries = 0

    for line in MANIFEST.read_text(encoding="utf-8").splitlines():
        if not line:
            continue
        expected, filename = line.split(maxsplit=1)
        path = EVIDENCE / filename
        entries += 1
        if not path.is_file():
            failures.append(f"{filename}: missing")
            continue

        data = path.read_bytes()
        if sha256(data) == expected:
            continue

        # Git stores these Windows-authored text artifacts with LF endings.
        # The manifest intentionally pins their original Windows CRLF bytes.
        windows_bytes = data.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
        if sha256(windows_bytes) == expected:
            normalized += 1
            continue

        failures.append(f"{filename}: checksum mismatch")

    if failures:
        for failure in failures:
            print(failure)
        return 1

    print(
        f"verified {entries} M8 native-capture artifacts "
        f"({normalized} text files reconstructed with Windows CRLF endings)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
