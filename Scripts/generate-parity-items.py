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
    "?", "ansireset", "autolog", "capturecancel", "chars", "clear", "close", "connect",
    "connectioninfo", "debugaliases", "debugnetwork", "debugtimers", "debugtriggers", "delay",
    "disconnect", "echo", "exit", "gmcp", "help", "idle", "lizards", "log", "logall", "logtop",
    "makali", "map_addexit", "map_addroom", "map_guesslocation", "map_look", "mcmp", "naws", "new",
    "newedit", "newinput", "newtab", "opendialog", "ping", "printenv", "puppets", "receive",
    "receivegmcp", "reconnect", "removelast", "repeat", "resetscript", "restoreinfo", "roll", "set",
    "setinput", "shelp", "silence", "slist", "stats", "stoplogs", "switchtab", "tabcolor", "tilemap",
    "ttype", "unset", "wall", "webview", "world", "ai", "gag", "grab", "puppet", "recall",
    "resetconfig", "rolltest", "test",
}
RELEASE_EXCLUDED_COMMANDS = {"ai"}
IMPLEMENTATION_GAP_COMMANDS = set()
IMPLEMENTED_PROTOCOLS = {"ANSI", "BINARY", "CHARSET", "Client.Media", "EOR", "GMCP", "MCP", "MCMP", "MTTS", "NAWS", "Pueblo", "TTYPE", "Telnet", "Tilemap", "WebView"}
PARTIAL_PROTOCOLS = set()
IMPLEMENTED_WINDOWS = {
    "Aliases", "Characters", "Connect", "Diagnostics", "DockedWindow", "Find", "FloatingWindow",
    "InputWindow", "Logging", "Macros", "MainWindow", "MapWindow", "Puppets", "Servers", "Settings",
    "SpawnWindow", "SpawnTabsWindow", "StatsWindow", "TextWindow", "TileMapWindow", "Triggers", "WebViewWindow", "AIWindow",
}
RELEASE_EXCLUDED_WINDOWS = {"AIWindow"}
IMPLEMENTATION_GAP_WINDOWS = set()
PLATFORM_EXCEPTIONS = {"App.ActiveXObject", "Window_Properties.HWND"}
IMPLEMENTED_SETTING_OWNERS = {
    "Alias", "Aliases", "KeyboardMacro", "KeyboardMacros2", "Logging", "MapWindow", "Stat_Int", "Stat_Range",
    "Trigger", "Trigger_Activate", "Trigger_Avatar", "Trigger_Color", "Trigger_Filter",
    "Trigger_Gag", "Trigger_Paragraph", "Trigger_Script", "Trigger_Send", "Trigger_Sound",
    "Trigger_Spawn", "Trigger_Speech", "Trigger_Stat", "Trigger_Style", "Trigger_Toast", "Triggers",
}
IMPLEMENTED_SETTING_IDENTIFIERS = {
    "Character.Aliases", "Character.KeyboardMacros2", "Character.Triggers",
    "Connections.Aliases", "Connections.KeyboardMacros2", "Connections.Logging", "Connections.Triggers",
    "Global.ScriptDebug", "Global.ScriptStartup", "Server.Aliases", "Server.KeyboardMacros2", "Server.Triggers",
}
TYPED_PROJECTION_IDENTIFIERS = {
    "Character.Connect", "Character.ConnectAtStartup", "Character.IdleEnabled", "Character.IdleString",
    "Character.IdleTimeout", "Character.Password", "Character.Puppets",
    "Connections.ConnectRetry", "Connections.ConnectTimeout", "Connections.RetryForever",
    "Global.ScriptDebug", "Global.ScriptStartup", "Global.TCP_KeepAlive", "Global.TCP_NoDelay",
    "Puppet.AutoConnect", "Puppet.ConnectWithPlayer", "Puppet.HideReceivePrefix", "Puppet.ReceivePrefix",
    "Puppet.RegularExpression", "Puppet.RemoveAccidentalPrefix", "Puppet.SendPrefix",
    "Server.Characters", "Server.Encoding", "Server.GMCP_WebView", "Server.Host", "Server.IPV4",
    "Server.LimitTelnetCharset", "Server.MCP", "Server.MCMP", "Server.NAWSOnResize", "Server.Pueblo",
    "Server.Port", "Server.Prompts", "Server.TLS", "Server.VerifyCertificate",
}
IMPLEMENTED_SCRIPT_MEMBERS = {
    "App.Aliases", "App.BuildNumber", "App.ConfigPath", "App.NewTrigger", "App.OutputDebugHTML",
    "App.OutputDebugText", "App.PlaySound", "App.StopSounds", "App.Triggers", "App.Version",
    "App.BuildDate", "App.CreateInterval", "App.CreateTimeout", "App.ForwardDNSLookup", "App.IsAddress",
    "App.New_Socket", "App.New_SocketServer", "App.ReverseDNSLookup",
    "App.NewWindow", "App.NewWindow_FixedText", "App.NewWindow_Graphics", "App.NewWindow_Text", "App.SetOnNewWindow",
    "App.Windows", "App.Worlds", "ArrayUInt.Count", "ArrayUInt.Item", "Beip.App", "Beip.Window",
    "Connection.Display", "Connection.IsConnected", "Connection.IsLogging", "Connection.Receive",
    "Connection.Send", "Connection.Transmit", "Connection.Window_Main", "TextWindowLine.HTMLString",
    "Connection.Character", "Connection.Log", "Connection.Puppet", "Connection.Reconnect", "Connection.World",
    "Connection.SetOnConnect", "Connection.SetOnDisconnect", "Connection.SetOnDisplay", "Connection.SetOnGMCP",
    "Connection.SetOnReceive", "Connection.SetOnSend",
    "TextWindowLine.Length", "TextWindowLine.String", "Window_Input.Get", "Window_Input.GetSelEnd",
    "TextWindowLine.BgColor", "TextWindowLine.Blink", "TextWindowLine.Bold", "TextWindowLine.Color",
    "TextWindowLine.Delete", "TextWindowLine.Flash", "TextWindowLine.FlashMode", "TextWindowLine.Insert",
    "TextWindowLine.Italic", "TextWindowLine.Strikeout", "TextWindowLine.Underline",
    "Timer.Active", "Timer.UserData",
    "Socket.Close", "Socket.Connect", "Socket.IsConnected", "Socket.Send", "Socket.SetFlag",
    "Socket.SetOnConnect", "Socket.SetOnDisconnect", "Socket.SetOnReceive", "Socket.UserData",
    "SocketServer.Shutdown",
    "Docking.Dock", "Log.FileName", "Log.Write", "Log.WriteLine",
    "Window_FixedText.Clear", "Window_FixedText.CursorX", "Window_FixedText.CursorY",
    "Window_FixedText.Events", "Window_FixedText.Properties", "Window_FixedText.Write",
    "Window_Graphics.Clear", "Window_Graphics.Events", "Window_Graphics.GetPixel", "Window_Graphics.Height",
    "Window_Graphics.LineTo", "Window_Graphics.MoveTo", "Window_Graphics.Properties", "Window_Graphics.SetPen",
    "Window_Graphics.SetPixel", "Window_Graphics.Text", "Window_Graphics.Width",
    "Window_Events.SetOnClose", "Window_Events.SetOnKey", "Window_Events.SetOnMouseMove",
    "Window_Input.GetSelStart", "Window_Input.Length", "Window_Input.Prefix", "Window_Input.Set", "Window_Input.SetSel", "Window_Input.Title",
    "Window_Main.Activity", "Window_Main.AddImportantActivity", "Window_Main.Close",
    "Window_Main.Connection", "Window_Main.DeleteVariable", "Window_Main.GetVariable",
    "Window_Main.History", "Window_Main.Input", "Window_Main.Output", "Window_Main.Run",
    "Window_Main.CreateDialogConnect", "Window_Main.RunFile", "Window_Main.SetOnActivate", "Window_Main.SetOnClose",
    "Window_Main.GetInput", "Window_Main.GetSpawnTabs", "Window_Main.SetOnCommand", "Window_Main.SetVariable", "Window_Main.Title", "Window_Main.TitlePrefix", "Window_Main.UserData",
    "Window_SpawnTabs.SetOnTabActivate",
    "Window_Properties.Title", "Window_Text.Add", "Window_Text.Create", "Window_Text.Paused",
    "Window_Text.CreateHTML", "Window_Text.Properties", "Window_Text.SetOnPause", "Window_Text.Write", "Window_Text.WriteHTML", "Windows.Count", "Windows.Item",
    "WebView.AddToInputHistory", "WebView.ClearOnDisplay", "WebView.ClearOnDisplayCapture",
    "WebView.ClearOnGMCP", "WebView.CloseWindow", "WebView.Display", "WebView.GetPropertyString",
    "WebView.IsConnected", "WebView.ProcessAliases", "WebView.Receive", "WebView.Send",
    "WebView.SendGMCP", "WebView.SetOnConnect", "WebView.SetOnDisconnect", "WebView.SetOnDisplay",
    "WebView.SetOnDisplayCapture", "WebView.SetOnGMCP", "WebView.SetOnReceive", "WebView.SetOnSend",
}


def source_lines(name: str) -> list[str]:
    return (UPSTREAM / name).read_text(encoding="utf-8-sig", errors="replace").splitlines()


def command_items() -> list[dict]:
    lines = source_lines("Commands.cpp")
    pattern = re.compile(r'IEquals\(command, "([^"]+)"\)')
    matches = [(index, match) for index, line in enumerate(lines) if (match := pattern.search(line))]
    items = []
    for position, (index, match) in enumerate(matches):
        name = match.group(1)
        if name == "mucknet":
            status = "compile-time-excluded"
        elif name in RELEASE_EXCLUDED_COMMANDS:
            status = "release-excluded"
        elif name in IMPLEMENTATION_GAP_COMMANDS:
            status = "implementation-gap"
        else:
            status = "implemented"
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
                identifier = f"{owner}.{field}"
                status = "implemented" if (
                    owner in IMPLEMENTED_SETTING_OWNERS
                    or identifier in IMPLEMENTED_SETTING_IDENTIFIERS
                    or identifier in TYPED_PROJECTION_IDENTIFIERS
                ) else "preserved"
                if owner == "Trigger_Extension" or identifier == "Trigger.Extensions":
                    status = "platform-exception"
                result.append(item("setting", identifier, "Root.prp", line_number, code.strip(), status))

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
            status = "platform-exception" if identifier in PLATFORM_EXCEPTIONS else (
                "implemented" if identifier in IMPLEMENTED_SCRIPT_MEMBERS else "implementation-gap"
            )
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
            status = "implementation-gap"
            if category == "protocol":
                status = "implemented" if name in IMPLEMENTED_PROTOCOLS else "implementation-gap"
            elif category == "trigger-action":
                status = "implemented"
            elif category == "window-dialog":
                if name in RELEASE_EXCLUDED_WINDOWS:
                    status = "release-excluded"
                elif name in IMPLEMENTED_WINDOWS:
                    status = "implemented"
                elif name in IMPLEMENTATION_GAP_WINDOWS:
                    status = "implementation-gap"
            entry = item(category, name, "UPSTREAM_INVENTORY.md", 1, f"Observable {category} surface: {name}", status)
            result.append(entry)
    return result


def evidence_for(category: str, identifier: str, status: str) -> dict:
    if status == "implementation-gap":
        return {
            "class": "milestone-audit",
            "paths": ["Documentation/MILESTONE6_AUDIT.md"],
            "status": "accepted",
            "targetMilestone": 7,
        }
    if status == "preserved":
        return {
            "class": "round-trip",
            "paths": ["Tests/BeipPersistenceTests/LegacyConfigTests.swift"],
            "status": "accepted",
        }
    if status == "compile-time-excluded":
        return {
            "class": "milestone-audit",
            "paths": ["Documentation/PLAN.md"],
            "status": "accepted",
        }
    if status == "release-excluded":
        return {
            "class": "milestone-audit",
            "paths": ["Documentation/MILESTONE8_AUDIT.md", "Documentation/PARITY_RELEASE_PLAN.md"],
            "status": "accepted",
        }
    if status == "platform-exception":
        return {
            "class": "round-trip" if category == "setting" else "unit",
            "paths": (
                ["Tests/BeipPersistenceTests/LegacyConfigTests.swift", "Documentation/MILESTONE7_AUDIT.md"]
                if category == "setting"
                else ["Tests/BeipScriptRuntimeTests/ScriptRuntimeTests.swift", "Documentation/PLAN.md"]
            ),
            "status": "accepted",
        }

    if category == "setting":
        paths, evidence_class = ["Tests/BeipPersistenceTests/LegacyConfigTests.swift"], "round-trip"
    elif category == "script-member":
        paths, evidence_class = ["Tests/BeipScriptRuntimeTests/ScriptRuntimeTests.swift"], "unit"
    elif category == "trigger-action":
        paths, evidence_class = ["Tests/BeipAutomationTests/AutomationTests.swift", "Tests/BeipPersistenceTests/LegacyConfigTests.swift"], "integration"
    elif category == "window-dialog":
        if identifier in {"Aliases", "Macros", "Triggers"}:
            paths, evidence_class = ["Tests/BeipAutomationTests/AutomationTests.swift", "Tests/BeipPersistenceTests/LegacyConfigTests.swift"], "ui"
        elif identifier in {"Characters", "Connect", "Puppets", "Servers"}:
            paths, evidence_class = ["Tests/BeipPersistenceTests/LegacyConfigTests.swift", "Tests/BeipUITests/WorkspacePreferencesTests.swift"], "ui"
        elif identifier in {"Find", "InputWindow", "MainWindow", "TextWindow"}:
            paths, evidence_class = ["Tests/BeipUITests/VirtualizedOutputViewTests.swift", "Tests/BeipUITests/WorkspacePreferencesTests.swift"], "ui"
        elif identifier in {"Diagnostics", "Logging"}:
            paths, evidence_class = ["Tests/BeipUITests/NetworkDebugWindowControllerTests.swift", "Tests/BeipUITests/WorkspacePreferencesTests.swift"], "ui"
        else:
            paths, evidence_class = ["Tests/BeipUITests/WorkspacePreferencesTests.swift"], "ui"
    elif category == "protocol":
        if identifier == "ANSI":
            paths = ["Tests/BeipProtocolsTests/TextDecoderTests.swift"]
        elif identifier == "MCP":
            paths = ["Tests/BeipProtocolsTests/MCPParserTests.swift"]
        elif identifier in {"Client.Media", "MCMP"}:
            paths = ["Tests/BeipCoreTests/ClientMediaTests.swift", "Tests/BeipProtocolsTests/MCPParserTests.swift"]
        elif identifier == "WebView":
            paths = ["Tests/BeipCoreTests/WebViewProtocolTests.swift"]
        else:
            paths = ["Tests/BeipProtocolsTests/TelnetParserTests.swift", "Tests/BeipProtocolsTests/NetworkTransportTests.swift"]
        evidence_class = "integration"
    else:
        paths, evidence_class = ["Tests/BeipAutomationTests/AutomationTests.swift"], "unit"
    return {"class": evidence_class, "paths": paths, "status": "accepted"}


def item(category: str, identifier: str, source: str, line: int, behavior: str, status: str) -> dict:
    evidence = evidence_for(category, identifier, status)
    disposition = {
        "implemented": "implemented",
        "preserved": "preservation-only",
        "implementation-gap": "implementation-gap",
        "compile-time-excluded": "compile-time-excluded",
        "release-excluded": "release-excluded",
        "platform-exception": "platform-exception",
    }[status]
    fixture = "; ".join(evidence["paths"])
    if status == "implementation-gap":
        fixture += "; deferred to Milestone 7"
    return {
        "category": category,
        "identifier": identifier,
        "upstreamReference": f"{source}:{line}",
        "expectedBehavior": behavior,
        "windowsReference": BASELINE["referenceRelease"],
        "macStatus": status,
        "releaseDisposition": disposition,
        "evidence": evidence,
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
    status_counts: dict[str, int] = {}
    disposition_counts: dict[str, int] = {}
    evidence_counts: dict[str, int] = {}
    for entry in items:
        status_counts[entry["macStatus"]] = status_counts.get(entry["macStatus"], 0) + 1
        disposition_counts[entry["releaseDisposition"]] = disposition_counts.get(entry["releaseDisposition"], 0) + 1
        evidence_class = entry["evidence"]["class"]
        evidence_counts[evidence_class] = evidence_counts.get(evidence_class, 0) + 1
    return {
        "schemaVersion": 2,
        "generatedFromCommit": BASELINE["auditedCommit"],
        "windowsReference": BASELINE["referenceRelease"],
        "itemCount": len(items),
        "categoryCounts": counts,
        "statusCounts": status_counts,
        "releaseDispositionCounts": disposition_counts,
        "evidenceClassCounts": evidence_counts,
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
