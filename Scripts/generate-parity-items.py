#!/usr/bin/env python3
"""Generate the item-level parity specification from the pinned upstream checkout."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys


REPOSITORY = Path(__file__).resolve().parent.parent
UPSTREAM = REPOSITORY.parent / "BeipMU-win" / "src"
BASELINE = json.loads((REPOSITORY / "UPSTREAM_BASELINE.json").read_text())
OUTPUT = REPOSITORY / "Documentation" / "PARITY_ITEMS.json"

IMPLEMENTED_COMMANDS = {
    "?", "ansireset", "clear", "echo", "gmcp", "help", "lizards", "makali",
    "naws", "printenv", "resetscript", "roll", "script", "set", "shelp",
    "ttype", "unset",
}
PARTIAL_COMMANDS = {
    "chars", "close", "connect", "connectioninfo", "delay", "disconnect", "exit", "idle",
    "log", "logall", "logtop", "new", "newtab", "opendialog", "ping", "puppet",
    "puppets", "receive", "receivegmcp", "reconnect", "removelast", "repeat",
    "setinput", "silence", "slist", "stats", "stoplogs", "wall", "world",
}
IMPLEMENTED_PROTOCOLS = {"ANSI", "BINARY", "CHARSET", "EOR", "GMCP", "MTTS", "NAWS", "Pueblo", "TTYPE", "Telnet"}
PARTIAL_PROTOCOLS = set()
PLATFORM_EXCEPTIONS = {"Window_Properties.HWND"}


def source_lines(name: str) -> list[str]:
    return (UPSTREAM / name).read_text(encoding="utf-8-sig", errors="replace").splitlines()


def command_items() -> list[dict]:
    lines = source_lines("Commands.cpp")
    pattern = re.compile(r'IEquals\(command, "([^"]+)"\)')
    matches = [(index, match) for index, line in enumerate(lines) if (match := pattern.search(line))]
    items = []
    for position, (index, match) in enumerate(matches):
        name = match.group(1)
        status = "compile-time-excluded" if name == "mucknet" else (
            "implemented" if name in IMPLEMENTED_COMMANDS else "partial" if name in PARTIAL_COMMANDS else "recognized"
        )
        end = matches[position + 1][0] if position + 1 < len(matches) else min(len(lines), index + 80)
        branch = " ".join(line.split("//", 1)[0].strip() for line in lines[index:end])
        items.append(item("command", f"/{name}", "Commands.cpp", index + 1, normalize(branch), status))
    items.extend([
        item("command", "//", "Commands.cpp", 135, "A second leading slash bypasses local command parsing and sends the remaining slash-prefixed line to the server.", "implemented"),
        item("command", "/silent/…", "Commands.cpp", 151, "The silent/ prefix executes the nested local command while suppressing informational output.", "implemented"),
        item("command", "/@", "Wnd_Main.cpp", 2565, "The /@ prefix evaluates the remaining, potentially multiline text as an immediate script.", "implemented"),
    ])
    return unique(items)


def setting_items() -> list[dict]:
    lines = source_lines("Root.prp")
    result = []
    stack: list[tuple[str, int]] = []
    pending_prop: tuple[str, int] | None = None
    depth = 0
    prop_pattern = re.compile(r"^\s*Prop\s+([A-Za-z_][A-Za-z0-9_]*)")
    field_pattern = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_:<>]*)\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s+&[A-Za-z_][A-Za-z0-9_]*)?(.*)$")
    ignored = {"Prop", "Func", "Enum", "Flags", "FlagSet", "Option"}

    for line_number, raw in enumerate(lines, 1):
        code = raw.split("//", 1)[0].rstrip()
        prop_match = prop_pattern.match(code)
        if prop_match and ";" not in code:
            pending_prop = (prop_match.group(1), depth)

        if pending_prop and "{" in code:
            stack.append(pending_prop)
            pending_prop = None

        if stack and not prop_match:
            match = field_pattern.match(code)
            if match and match.group(1) not in ignored and not code.lstrip().startswith(("#", "}")):
                owner = stack[-1][0]
                field = match.group(2)
                result.append(item("setting", f"{owner}.{field}", "Root.prp", line_number, code.strip(), "preserved"))

        depth += code.count("{") - code.count("}")
        while stack and depth <= stack[-1][1]:
            stack.pop()
    return unique(result)


def script_items() -> list[dict]:
    result = []
    interface: str | None = None
    statement = ""
    statement_line = 0
    interface_pattern = re.compile(r"^\s*interface\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*IDispatch")
    member_pattern = re.compile(r"HRESULT\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(")
    for line_number, raw in enumerate(source_lines("OM.idl"), 1):
        line = raw.split("//", 1)[0].strip()
        match = interface_pattern.match(line)
        if match:
            interface = match.group(1)
            statement = ""
            continue
        if interface and line == "}":
            interface = None
            statement = ""
            continue
        if not interface or not line:
            continue
        if not statement:
            statement_line = line_number
        statement = (statement + " " + line).strip()
        if ";" not in line:
            continue
        match = member_pattern.search(statement)
        if match:
            identifier = f"{interface}.{match.group(1)}"
            status = "platform-exception" if identifier in PLATFORM_EXCEPTIONS else "host-proxy-pending"
            result.append(item("script-member", identifier, "OM.idl", statement_line, normalize(statement), status))
        statement = ""
    return unique(result)


def declared_surface_items() -> list[dict]:
    surfaces = {
        "protocol": ["Telnet", "ANSI", "TTYPE", "MTTS", "NAWS", "CHARSET", "GMCP", "MCP", "MCMP", "Pueblo", "EOR", "BINARY", "Client.Media", "WebView", "Tilemap"],
        "trigger-action": ["Appearance", "Paragraph", "Gag", "Sound", "Activate", "Send", "Filter", "Avatar", "Script", "Toast", "Speech", "Stat", "Spawn", "Capture"],
        "window-dialog": ["MainWindow", "TextWindow", "InputWindow", "AIWindow", "SpawnWindow", "SpawnTabsWindow", "StatsWindow", "TileMapWindow", "MapWindow", "WebViewWindow", "DockedWindow", "FloatingWindow", "Find", "Connect", "Settings", "Characters", "Servers", "Puppets", "Aliases", "Triggers", "Macros", "Logging", "Diagnostics"],
    }
    result = []
    for category, names in surfaces.items():
        for name in names:
            status = "planned"
            if category == "protocol":
                status = "implemented" if name in IMPLEMENTED_PROTOCOLS else "partial" if name in PARTIAL_PROTOCOLS else "planned"
            entry = item(category, name, "UPSTREAM_INVENTORY.md", 1, f"Observable {category} surface: {name}", status)
            if category == "protocol" and name in {"Telnet", "BINARY", "EOR"}:
                entry["differentialFixture"] = "TelnetParserTests; Tests/Golden/windows-v331-session.trace.json"
            result.append(entry)
    return result


def item(category: str, identifier: str, source: str, line: int, behavior: str, status: str) -> dict:
    fixture = "pending"
    if status == "implemented":
        fixture = "unit-or-integration-test; Windows differential pending"
    elif status == "partial":
        fixture = "partial unit-or-integration coverage; Windows differential pending"
    elif status == "platform-exception":
        fixture = "ScriptRuntimeTests"
    return {
        "category": category,
        "identifier": identifier,
        "upstreamReference": f"{source}:{line}",
        "expectedBehavior": behavior,
        "windowsReference": BASELINE["referenceRelease"],
        "macStatus": status,
        "differentialFixture": fixture,
    }


def normalize(value: str) -> str:
    return re.sub(r"\s+", " ", value).strip()


def unique(items: list[dict]) -> list[dict]:
    found = {}
    for candidate in items:
        found[(candidate["category"], candidate["identifier"])] = candidate
    return list(found.values())


def document() -> dict:
    items = command_items() + setting_items() + script_items() + declared_surface_items()
    items.sort(key=lambda value: (value["category"], value["identifier"].casefold()))
    counts: dict[str, int] = {}
    for entry in items:
        counts[entry["category"]] = counts.get(entry["category"], 0) + 1
    return {
        "schemaVersion": 1,
        "generatedFromCommit": BASELINE["auditedCommit"],
        "windowsReference": BASELINE["referenceRelease"],
        "itemCount": len(items),
        "categoryCounts": counts,
        "items": items,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    rendered = json.dumps(document(), indent=2, ensure_ascii=False) + "\n"
    if args.check:
        current = OUTPUT.read_text(encoding="utf-8") if OUTPUT.exists() else ""
        if current.rstrip() + "\n" != rendered:
            print("Documentation/PARITY_ITEMS.json is stale; regenerate it.", file=sys.stderr)
            return 1
        print(f"verified {document()['itemCount']} parity items")
        return 0
    if args.write:
        OUTPUT.write_text(rendered, encoding="utf-8")
        print(f"wrote {document()['itemCount']} parity items to {OUTPUT.relative_to(REPOSITORY)}")
        return 0
    sys.stdout.write(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
