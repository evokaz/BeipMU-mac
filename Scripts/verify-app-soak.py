#!/usr/bin/env python3
"""Verify the full-app Instruments soak completion report and trace export."""

from __future__ import annotations

import re
import sys
from pathlib import Path


REPORT_PATTERN = re.compile(r"^BEIPMU_SOAK_COMPLETE (?P<values>.+)$", re.MULTILINE)


def main() -> int:
    if len(sys.argv) not in (7, 8):
        print(
            "usage: verify-app-soak.py STDOUT TRACE_TOC LEAKS_OUTPUT REQUESTED_LINES HISTORY_LIMIT MAX_RSS_BYTES [--report-only]",
            file=sys.stderr,
        )
        return 2

    stdout_path, toc_path, leaks_path = map(Path, sys.argv[1:4])
    requested_lines, history_limit, max_rss = map(int, sys.argv[4:7])
    report_only = len(sys.argv) == 8 and sys.argv[7] == "--report-only"
    if len(sys.argv) == 8 and not report_only:
        print(f"unknown option: {sys.argv[7]}", file=sys.stderr)
        return 2
    output = stdout_path.read_text(encoding="utf-8")
    match = REPORT_PATTERN.search(output)
    if not match:
        print("full-app soak did not emit its completion report", file=sys.stderr)
        return 1

    values: dict[str, str] = {}
    for component in match.group("values").split():
        key, separator, value = component.partition("=")
        if separator:
            values[key] = value

    required = {"lines", "retained", "rendered", "paintCandidates", "rssBytes", "elapsedSeconds"}
    missing = required - values.keys()
    if missing:
        print("soak report missing: " + ", ".join(sorted(missing)), file=sys.stderr)
        return 1

    lines = int(values["lines"])
    retained = int(values["retained"])
    rendered = int(values["rendered"])
    paint_candidates = int(values["paintCandidates"])
    rss_bytes = int(values["rssBytes"])
    if lines < requested_lines:
        print(f"soak appended only {lines} of {requested_lines} requested lines", file=sys.stderr)
        return 1
    if retained != history_limit or rendered != history_limit:
        print(
            f"bounded history mismatch: retained={retained}, rendered={rendered}, expected={history_limit}",
            file=sys.stderr,
        )
        return 1
    if not report_only and paint_candidates > 200:
        print(f"viewport candidate count {paint_candidates} exceeds 200", file=sys.stderr)
        return 1
    if not report_only and (rss_bytes == 0 or rss_bytes > max_rss):
        print(f"resident size {rss_bytes} exceeds budget {max_rss}", file=sys.stderr)
        return 1

    toc = toc_path.read_text(encoding="utf-8")
    if "Time Profiler" not in toc or "run number=\"1\"" not in toc:
        print("Instruments trace table of contents is incomplete", file=sys.stderr)
        return 1

    leaks_output = leaks_path.read_text(encoding="utf-8")
    zero_leaks = re.search(r"0 leaks for 0 total leaked bytes", leaks_output)
    excluded_system_leaks = None
    if not zero_leaks:
        summary = re.search(
            r"(?P<count>\d+) leaks for (?P<bytes>\d+) total leaked bytes",
            leaks_output,
        )
        stacks = re.findall(r"STACK OF .*?(?=\nSTACK OF |\Z)", leaks_output, re.DOTALL)
        known_system_cycle = (
            summary is not None
            and bool(stacks)
            and all("LNProcessInstanceRegistryClient" in stack for stack in stacks)
            and all("BeipMU" not in stack for stack in stacks)
        )
        if not known_system_cycle:
            print("full-app leak scan contains an unknown or app-owned leak", file=sys.stderr)
            return 1
        excluded_system_leaks = (summary.group("count"), summary.group("bytes"))

    print(match.group(0))
    if report_only:
        print(f"Report only: paint candidates {paint_candidates}/200; RSS {rss_bytes}/{max_rss} bytes")
    if report_only:
        print(f"Instruments Time Profiler trace verified; RSS measurement {rss_bytes} bytes")
    else:
        print(f"Instruments Time Profiler trace verified; RSS budget {rss_bytes}/{max_rss} bytes")
    if excluded_system_leaks:
        count, byte_count = excluded_system_leaks
        print(
            f"Full-app leak scan: 0 app-owned leaks; excluded macOS AppIntents root cycles "
            f"({count} nodes / {byte_count} bytes)"
        )
    else:
        print("Full-app leaks --atExit scan: 0 leaks / 0 bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
