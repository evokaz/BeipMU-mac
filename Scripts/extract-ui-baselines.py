#!/usr/bin/env python3
"""Copy named screenshot attachments from an xcresult export into UI baselines."""

from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path
from typing import Any, Iterator


EXPECTED_ATTACHMENTS = {
    "workspace-main",
    "workspace-command-error",
    "workspace-split-sidebars",
    "settings-window",
    "statistics-panel",
}


def attachment_records(value: Any) -> Iterator[dict[str, Any]]:
    if isinstance(value, dict):
        if "exportedFileName" in value:
            yield value
        for child in value.values():
            yield from attachment_records(child)
    elif isinstance(value, list):
        for child in value:
            yield from attachment_records(child)


def main() -> int:
    if len(sys.argv) != 3:
        print(
            "usage: extract-ui-baselines.py ATTACHMENT_EXPORT_DIR BASELINE_DIR",
            file=sys.stderr,
        )
        return 2

    export_directory = Path(sys.argv[1])
    baseline_directory = Path(sys.argv[2])
    manifest_path = export_directory / "manifest.json"
    with manifest_path.open(encoding="utf-8") as manifest_file:
        manifest = json.load(manifest_file)

    exported: dict[str, Path] = {}
    for record in attachment_records(manifest):
        labels = [str(value) for value in record.values() if isinstance(value, str)]
        for name in EXPECTED_ATTACHMENTS:
            if any(label == name or label.startswith(f"{name}_") for label in labels):
                exported[name] = export_directory / record["exportedFileName"]

    missing = EXPECTED_ATTACHMENTS - exported.keys()
    if missing:
        print(
            "missing UI screenshot attachments: " + ", ".join(sorted(missing)),
            file=sys.stderr,
        )
        return 1

    baseline_directory.mkdir(parents=True, exist_ok=True)
    for name in sorted(EXPECTED_ATTACHMENTS):
        destination = baseline_directory / f"{name}.png"
        shutil.copyfile(exported[name], destination)
        print(f"Recorded {destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
