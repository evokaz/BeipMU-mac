#!/usr/bin/env python3
"""Generate the deterministic Milestone 10 scale fixtures."""

from __future__ import annotations

import argparse
import io
import json
from pathlib import Path
import sys
import zipfile


ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "Tests" / "Fixtures" / "M10"


def large_configuration() -> bytes:
    lines = [
        "Version=331",
        "M10UnknownRoot=preserve-root",
        "Connections",
        "{",
        "  Logging.RestoreBufferSize=10000",
        "  Shortcuts",
        "  {",
    ]
    for world in range(64):
        lines.extend(
            [
                f'    "M10 World {world:02d}"',
                "    {",
                f'      Host="127.0.0.1:{46000 + world}"',
                f'      Info="Deterministic scale world {world:02d}"',
                "      Encoding=UTF8",
                f"      M10WindowsOnly{world:02d}=preserve-world-{world:02d}",
                "      Characters",
                "      {",
            ]
        )
        for character in range(4):
            lines.extend(
                [
                    f'        "Character {world:02d}-{character:02d}"',
                    "        {",
                    f'          Connect="connect m10-{world:02d}-{character:02d} fixture-password"',
                    "          MainWindowSettings.InputSize=25",
                    "          Triggers",
                    "          {",
                ]
            )
            for trigger in range(8):
                lines.extend(
                    [
                        "            {",
                        f'              Description="M10 trigger {trigger:02d}"',
                        f'              FindString.MatchText="HP{trigger:02d}:"',
                        f'              Replace="score {world:02d}-{character:02d}-{trigger:02d}"',
                        "            }",
                    ]
                )
            lines.extend(["          }", "          Aliases", "          {"])
            for alias in range(8):
                lines.extend(
                    [
                        "            {",
                        f'              Description="M10 alias {alias:02d}"',
                        f'              FindString.MatchText="m10-{alias:02d}"',
                        f'              Replace="say alias {world:02d}-{character:02d}-{alias:02d}"',
                        "            }",
                    ]
                )
            lines.extend(
                [
                    "          }",
                    f'          M10UnknownCharacter="preserve-{world:02d}-{character:02d}"',
                    "        }",
                ]
            )
        lines.extend(["      }", "    }"])
    lines.extend(["  }", "}", "M10TrailingUnknown=preserve-trailing", ""])
    return "\n".join(lines).encode()


def large_atlas() -> bytes:
    size = 20
    xml = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        "<atlas version='2' m10_unknown_root='preserve-root'>",
        "<font_rooms name='Helvetica' size='10'/>",
        "<palette name='M10' background='#101820' foreground='#f2f2f2'/>",
        "<m10_extension payload='preserve-unknown-xml'/>",
        "<map name='M10 Grid' m10_map_unknown='preserve-map'>",
    ]
    for row in range(size):
        for column in range(size):
            index = row * size + column
            x, y = column * 100, row * 70
            xml.append(
                f"<room name='Room {index:03d}' rect='{x},{y},{x + 80},{y + 50}' "
                f"color='#{(index * 2654435761) & 0xFFFFFF:06x}' "
                f"m10_room_unknown='preserve-{index:03d}'/>"
            )
            if column:
                xml.append(
                    f"<exit from='{index - 1}' to='{index}' name_from='east' "
                    "name_to='west'/>"
                )
            if row:
                xml.append(
                    f"<exit from='{index - size}' to='{index}' name_from='south' "
                    "name_to='north'/>"
                )
    xml.extend(
        [
            "<label rect='0,1420,420,1460' text='M10 deterministic 20x20 atlas' color='#ffffff'/>",
            "</map>",
            "</atlas>",
            "",
        ]
    )
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        info = zipfile.ZipInfo("Atlas.xml", date_time=(1980, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o100644 << 16
        archive.writestr(info, "\n".join(xml).encode())
    return buffer.getvalue()


def concurrent_connections() -> bytes:
    sessions = []
    for session in range(8):
        actions: list[dict[str, object]] = [
            {"send_hex": "fffb19fffbc9"},
            {"expect_hex": "fffd19fffdc9"},
            {
                "send": (
                    f"\u001b[38;5;{32 + session}m[M10:{session}] ready\u001b[0m\r\n"
                    f'Core.Hello {{"client":"m10-{session}"}}\r\n'
                ),
                "chunks": [1, 2, 5, 13],
            },
        ]
        for burst in range(250):
            actions.append(
                {
                    "send": (
                        f"\u001b[1;3{session % 8}m[M10:{session}:{burst:03d}]\u001b[0m "
                        f"styled payload \u2713 {burst * 7919 % 100003}\r\n"
                    ),
                    "chunks": [1, 4, 11],
                }
            )
            if burst in (49, 149):
                actions.append(
                    {
                        "send": (
                            f'Client.Media.Play {{"name":"fixture-{session}-{burst}.wav","volume":25}}\r\n'
                            f'WebView.Open {{"id":"m10-{session}","url":"http://127.0.0.1/m10/{burst}"}}\r\n'
                        )
                    }
                )
        actions.extend(
            [
                {"expect": f"quit-{session}\r\n"},
                {"delay_ms": 25 + session},
                {"disconnect": True},
            ]
        )
        sessions.append(
            {
                "id": f"session-{session:02d}",
                "port": 47000 + session,
                "reconnects": 2,
                "logStem": f"m10-session-{session:02d}",
                "actions": actions,
            }
        )
    document = {
        "schemaVersion": 1,
        "seed": 10_010,
        "sessionCount": len(sessions),
        "styledLinesPerConnection": 250,
        "sessions": sessions,
    }
    return (json.dumps(document, indent=2, sort_keys=True) + "\n").encode()


def generated_files() -> dict[Path, bytes]:
    return {
        FIXTURES / "large-config.txt": large_configuration(),
        FIXTURES / "large-atlas.atlas": large_atlas(),
        FIXTURES / "concurrent-connections.json": concurrent_connections(),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    failures = []
    for path, expected in generated_files().items():
        if args.check:
            if not path.is_file() or path.read_bytes() != expected:
                failures.append(str(path.relative_to(ROOT)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(expected)
            print(path.relative_to(ROOT))
    if failures:
        print("stale M10 fixtures: " + ", ".join(failures), file=sys.stderr)
        return 1
    if args.check:
        print("M10 deterministic fixtures are current")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
