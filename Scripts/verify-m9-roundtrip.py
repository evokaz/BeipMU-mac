#!/usr/bin/env python3
"""Verify the Milestone 9 round-trip contract and checked-in artifact provenance."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path, PurePosixPath
import struct
import sys
import zipfile


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "Documentation" / "Evidence" / "M9" / "manifest.json"
REQUIRED_ROLES = {
    "seed-config", "seed-atlas", "seed-restore", "seed-image", "seed-sound",
    "seed-script", "seed-log", "operation-set",
    "macos-reload-config", "macos-reload-atlas", "macos-reload-restore",
    "macos-sidecar", "macos-generation-record", "macos-reload-readme",
    "macos-git-attributes",
    "macos-reload-image", "macos-reload-sound", "macos-reload-script",
    "macos-reload-log", "macos-reload-seed-log",
    "macos-remediation-config", "macos-remediation-atlas",
    "macos-remediation-restore", "macos-remediation-sidecar",
    "macos-remediation-generation-record", "macos-remediation-readme",
    "macos-remediation-git-attributes", "macos-remediation-hashes",
    "macos-remediation-image",
    "macos-remediation-sound", "macos-remediation-script",
    "macos-remediation-log", "macos-remediation-seed-log",
    "windows-reload-remediation-config", "windows-reload-remediation-atlas",
    "windows-reload-remediation-restore", "windows-reload-remediation-image",
    "windows-reload-remediation-sound", "windows-reload-remediation-script",
    "windows-reload-remediation-prior-log",
    "windows-reload-remediation-seed-log",
    "windows-reload-remediation-audit-log",
    "windows-reload-remediation-semantic-inventory",
    "windows-reload-remediation-application-events",
    "windows-reload-remediation-host-metadata",
    "windows-reload-remediation-session-metadata",
    "windows-reload-remediation-verifier-result",
    "windows-reload-remediation-readme",
    "windows-reload-remediation-hashes",
    "windows-baseline-config", "windows-baseline-atlas",
    "windows-baseline-restore", "windows-baseline-image",
    "windows-baseline-sound", "windows-baseline-script",
    "windows-baseline-log", "windows-baseline-seed-log",
    "windows-reload-config", "windows-reload-atlas", "windows-reload-restore",
    "windows-reload-semantic-inventory", "windows-reload-application-events",
    "macos-final-acceptance-readme",
    "macos-final-acceptance-semantic-comparison",
    "macos-final-acceptance-classified-differences",
    "macos-final-acceptance-raw-hashes",
    "macos-final-acceptance-verifier-result",
    "macos-final-acceptance-host-metadata",
    "macos-final-acceptance-reproduction-commands",
    "macos-final-round-trip-result",
}
REQUIRED_SCOPES = {"global", "world", "character", "puppet", "atlas", "restore"}
REQUIRED_ACTIONS = {"add", "update", "delete"}
DIFFERENCE_CLASSIFICATIONS = {
    "intended portable edit",
    "documented Windows canonicalization",
    "allowed host-specific sidecar state",
    "failure",
}
WINDOWS_CANONICALIZATION_IDS = {
    "config-findstring-canonicalization",
    "config-variable-layout-canonicalization",
    "config-character-macro-canonicalization",
    "config-collection-layout-canonicalization",
    "restore-ring-canonicalization",
    "runtime-BytesSent",
    "runtime-BytesReceived",
    "runtime-SecondsConnected",
    "runtime-ConnectionCount",
    "runtime-LastUsed",
    "runtime-restore-records",
    "runtime-audit-log",
}
CONFIG_MARKERS = {
    b"Shortcuts", b"Characters", b"Puppets", b"Aliases", b"KeyboardMacros2",
    b"Triggers", b"Extensions", b"Variables", b"Logging", b"Window",
    b"Font", b"Keys", b"C:\\\\M9Audit", b"M9Unknown",
}


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fail(failures: list[str], message: str) -> None:
    failures.append(message)


def verify_restore(
    data: bytes,
    buffer_size: int,
    failures: list[str],
    label: str = "seed-restore",
    minimum_buffers: int = 2,
) -> None:
    if buffer_size < 20 or len(data) == 0 or len(data) % buffer_size:
        fail(failures, f"{label}: invalid buffer size or file length")
        return
    if len(data) // buffer_size < minimum_buffers:
        fail(failures, f"{label}: expected at least {minimum_buffers} buffers")
    for buffer_index in range(len(data) // buffer_size):
        chunk = data[buffer_index * buffer_size:(buffer_index + 1) * buffer_size]
        start, count = struct.unpack_from("<II", chunk)
        capacity = buffer_size - 8
        if start > capacity or count > capacity:
            fail(failures, f"{label}: buffer {buffer_index} has invalid ring header")
            continue
        ring = chunk[8:]
        logical = bytes(ring[(start + index) % capacity] for index in range(count))
        cursor = 0
        while cursor < len(logical):
            if cursor + 12 > len(logical):
                fail(failures, f"{label}: buffer {buffer_index} has a partial record")
                break
            kind = logical[cursor]
            size = int.from_bytes(logical[cursor + 1:cursor + 4], "little")
            if kind not in {0, 1, 2, 4} or cursor + 12 + size > len(logical):
                fail(failures, f"{label}: buffer {buffer_index} has a corrupt record")
                break
            cursor += 12 + size


def restore_payloads(data: bytes, buffer_size: int) -> list[list[bytes]]:
    result: list[list[bytes]] = []
    for buffer_index in range(len(data) // buffer_size):
        chunk = data[buffer_index * buffer_size:(buffer_index + 1) * buffer_size]
        start, count = struct.unpack_from("<II", chunk)
        capacity = buffer_size - 8
        ring = chunk[8:]
        logical = bytes(ring[(start + index) % capacity] for index in range(count))
        payloads: list[bytes] = []
        cursor = 0
        while cursor < len(logical):
            size = int.from_bytes(logical[cursor + 1:cursor + 4], "little")
            payloads.append(logical[cursor + 12:cursor + 12 + size])
            cursor += 12 + size
        result.append(payloads)
    return result


def load_artifact_json(
    artifact_data: dict[str, bytes],
    role: str,
    failures: list[str],
) -> dict:
    data = artifact_data.get(role)
    if data is None:
        return {}
    try:
        document = json.loads(data.decode("utf-8-sig"))
        if not isinstance(document, dict):
            raise TypeError("top-level value is not an object")
        return document
    except (UnicodeDecodeError, json.JSONDecodeError, TypeError) as error:
        fail(failures, f"{role}: unreadable JSON: {error}")
        return {}


def main() -> int:
    failures: list[str] = []
    try:
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"manifest unreadable: {error}", file=sys.stderr)
        return 1

    for key in ("schemaVersion", "contractId", "referenceBinary", "operationSet",
                "normalizationRules", "requiredCorpusMembers", "artifacts"):
        if key not in manifest:
            fail(failures, f"manifest: missing {key}")
    reference = manifest.get("referenceBinary", {})
    if reference.get("version") != "v331" or len(reference.get("sha256", "")) != 64:
        fail(failures, "manifest: incomplete v331 binary identity")

    rules = manifest.get("normalizationRules", [])
    if not rules or any(rule.get("lineEndings") != "exact-bytes" for rule in rules):
        fail(failures, "manifest: every normalization rule must require exact line-ending bytes")

    records = manifest.get("artifacts", [])
    roles = {record.get("role") for record in records}
    for role in sorted(REQUIRED_ROLES - roles):
        fail(failures, f"manifest: missing required role {role}")
    seen_paths: set[str] = set()
    artifact_data: dict[str, bytes] = {}
    for record in records:
        for key in ("path", "role", "producerHost", "sha256", "binaryVersion",
                    "binarySHA256", "operationSet", "normalizationRule", "provenance"):
            if not record.get(key):
                fail(failures, f"artifact {record.get('role', '<unknown>')}: missing {key}")
        relative = record.get("path", "")
        pure = PurePosixPath(relative)
        if pure.is_absolute() or ".." in pure.parts or relative in seen_paths:
            fail(failures, f"artifact path is unsafe or duplicated: {relative}")
            continue
        seen_paths.add(relative)
        path = ROOT / relative
        if not path.is_file():
            fail(failures, f"{relative}: missing")
            continue
        data = path.read_bytes()
        artifact_data[record.get("role", "")] = data
        if digest(data) != record.get("sha256"):
            fail(failures, f"{relative}: raw SHA-256 mismatch")
        if record.get("producerHost") == "windows-v331":
            provenance = record.get("provenance", {})
            if not provenance.get("hostMetadata") or provenance.get("binarySHA256") != reference.get("sha256"):
                fail(failures, f"{relative}: incomplete Windows provenance")

    rule_ids = {rule.get("id") for rule in rules}
    operation_id = manifest.get("operationSet", {}).get("id")
    for record in records:
        if record.get("normalizationRule") not in rule_ids:
            fail(failures, f"{record.get('path')}: unknown normalization rule")
        if record.get("operationSet") != operation_id:
            fail(failures, f"{record.get('path')}: operation-set identity mismatch")

    seed_root = ROOT / "Tests" / "Fixtures" / "M9" / "seed"
    for relative in manifest.get("requiredCorpusMembers", {}).get("seedDirectory", []):
        if not (seed_root / relative).is_file():
            fail(failures, f"seed corpus: missing required member {relative}")

    config = artifact_data.get("seed-config", b"")
    for marker in sorted(CONFIG_MARKERS):
        if marker not in config:
            fail(failures, f"seed-config: missing coverage marker {marker!r}")

    operation_path = ROOT / manifest.get("operationSet", {}).get("path", "")
    try:
        operations_document = json.loads(operation_path.read_text(encoding="utf-8"))
        operations = operations_document["operations"]
        if digest(operation_path.read_bytes()) != manifest["operationSet"].get("sha256"):
            fail(failures, "operation set: manifest SHA-256 mismatch")
    except (OSError, json.JSONDecodeError, KeyError, TypeError) as error:
        fail(failures, f"operation set unreadable: {error}")
        operations = []
    ids = [item.get("id") for item in operations]
    if not ids or len(ids) != len(set(ids)):
        fail(failures, "operation set: operation IDs must be present and unique")
    scopes = {item.get("scope") for item in operations}
    actions = {item.get("action") for item in operations if item.get("artifact") == "config"}
    for scope in sorted(REQUIRED_SCOPES - scopes):
        fail(failures, f"operation set: missing scope {scope}")
    for action in sorted(REQUIRED_ACTIONS - actions):
        fail(failures, f"operation set: missing portable config action {action}")
    for scope in ("global", "world", "character", "puppet"):
        scoped = {item.get("action") for item in operations if item.get("scope") == scope}
        if not REQUIRED_ACTIONS <= scoped:
            fail(failures, f"operation set: {scope} must contain add/update/delete")

    atlas = artifact_data.get("seed-atlas")
    if atlas:
        try:
            with zipfile.ZipFile(ROOT / next(r["path"] for r in records if r.get("role") == "seed-atlas")) as archive:
                names = set(archive.namelist())
                required = set(manifest.get("requiredCorpusMembers", {}).get("atlasArchive", []))
                for name in sorted(required - names):
                    fail(failures, f"seed-atlas: missing archive member {name}")
                xml = archive.read("Atlas.xml")
                for marker in (b"m9_extension", b"m9_map_element", b"far_exits", b"map_from", b"map-marker.svg"):
                    if marker not in xml:
                        fail(failures, f"seed-atlas: missing semantic marker {marker!r}")
                embedded = manifest.get("embeddedArtifacts", [])
                for record in embedded:
                    if digest(archive.read(record["path"])) != record["sha256"]:
                        fail(failures, f"seed-atlas: embedded hash mismatch for {record['path']}")
        except (KeyError, OSError, zipfile.BadZipFile) as error:
            fail(failures, f"seed-atlas: unreadable archive: {error}")

    restore_record = next((r for r in records if r.get("role") == "seed-restore"), {})
    if "seed-restore" in artifact_data:
        verify_restore(artifact_data["seed-restore"], restore_record.get("bufferSize", 0), failures)

    mac_config = artifact_data.get("macos-reload-config", b"")
    if mac_config:
        if mac_config.count(b"\n") != mac_config.count(b"\r\n"):
            fail(failures, "macos-reload-config: Config.txt must remain entirely CRLF")
        for marker in (
            b'MDIPosition=(120,80,1280,760)', b'BytesSent=153',
            b'Description="M9 global added"', b'Description="Global updated"',
            b'Description="M9 world added"', b'Name="world_update"',
            b'Description="M9 character added"', b'Name="character_update"',
            b'Description="M9 puppet added"', b'Description="Puppet updated"',
        ):
            if marker not in mac_config:
                fail(failures, f"macos-reload-config: missing {marker!r}")
        for deleted in (b'Description="Global delete"', b'Name="world_delete"',
                        b'Name="character_delete"', b'Description="Puppet macro delete"'):
            if deleted in mac_config:
                fail(failures, f"macos-reload-config: deleted marker remains {deleted!r}")

    mac_restore_record = next((r for r in records if r.get("role") == "macos-reload-restore"), {})
    if "macos-reload-restore" in artifact_data:
        verify_restore(
            artifact_data["macos-reload-restore"],
            mac_restore_record.get("bufferSize", 0),
            failures,
            "macos-reload-restore",
        )

    generation = artifact_data.get("macos-generation-record")
    if generation:
        try:
            generation_document = json.loads(generation)
            if generation_document.get("appliedOperationIds") != ids:
                fail(failures, "macos-generation-record: operation order or IDs differ")
        except (json.JSONDecodeError, TypeError) as error:
            fail(failures, f"macos-generation-record: unreadable JSON: {error}")

    remediation_config = artifact_data.get("macos-remediation-config", b"")
    if remediation_config:
        if remediation_config.count(b"\n") != remediation_config.count(b"\r\n"):
            fail(failures, "macos-remediation-config: Config.txt must remain entirely CRLF")
        for marker in (
            b'MDIPosition=(120,80,1280,760)', b'ActiveTab=1',
            b'BytesSent=153', b'BytesReceived=288', b'SecondsConnected=78',
            b'ConnectionCount=3', b'Password="fixture-only-password"',
            b'FileName="C:\\\\M9Audit\\\\RoundTrip.atlas"',
            b'Sound="C:\\\\M9Audit\\\\Assets\\\\notify.wav"',
            b'Description="M9 global added"', b'Description="Global updated"',
            b'Description="M9 world added"', b'Name="world_update"',
            b'Value="mac-world"', b'"KeyboardMacros2"',
            b'Description="M9 character added"', b'key=Control+Alt+H',
            b'Macro="health"', b'Name="character_update"',
            b'Description="M9 puppet added"', b'Description="Puppet updated"',
        ):
            if marker not in remediation_config:
                fail(failures, f"macos-remediation-config: missing {marker!r}")
        for forbidden in (
            b'key="Control+Alt+H"', b'AIEndpoint=', b'AIModel=', b'GMCP_WebView=',
            b'TCP_KeepAlive=', b'TCP_NoDelay=', b'ConnectTimeout=30000',
            b'ConnectRetry=5', b'RetryForever=false', b'ScriptStartup=""',
            b'ScriptDebug=false', b'Encoding=CP1252', b'ConnectAtStartup=false',
            b'IdleEnabled=false', b'RegularExpression=false',
            b'MatchCase=false', b'StartsWith=false', b'EndsWith=false',
            b'WholeWord=false',
        ):
            if forbidden in remediation_config:
                fail(failures, f"macos-remediation-config: introduced forbidden/default syntax {forbidden!r}")

    remediation_restore_record = next(
        (r for r in records if r.get("role") == "macos-remediation-restore"), {}
    )
    remediation_restore = artifact_data.get("macos-remediation-restore")
    if remediation_restore is not None:
        remediation_buffer_size = remediation_restore_record.get("bufferSize", 0)
        verify_restore(
            remediation_restore,
            remediation_buffer_size,
            failures,
            "macos-remediation-restore",
            minimum_buffers=1,
        )
        payloads = restore_payloads(remediation_restore, remediation_buffer_size)
        if len(payloads) != 1 or b"M9 macOS append\r\n" not in payloads[0]:
            fail(
                failures,
                "macos-remediation-restore: append is not in v331-retained RestoreLogIndex=0 buffer",
            )

    remediation_generation = artifact_data.get("macos-remediation-generation-record")
    if remediation_generation:
        try:
            generation_document = json.loads(remediation_generation)
            if generation_document.get("appliedOperationIds") != ids:
                fail(failures, "macos-remediation-generation-record: operation order or IDs differ")
            selections = generation_document.get("restoreSelections", [])
            if selections != [{
                "operationId": "restore-append",
                "requestedBufferIndex": 1,
                "v331RetainedBufferIndex": 0,
            }]:
                fail(failures, "macos-remediation-generation-record: unexpected restore selection")
        except (json.JSONDecodeError, TypeError) as error:
            fail(failures, f"macos-remediation-generation-record: unreadable JSON: {error}")

    windows_remediation_config = artifact_data.get(
        "windows-reload-remediation-config", b""
    )
    if windows_remediation_config:
        if windows_remediation_config.count(b"\n") != windows_remediation_config.count(b"\r\n"):
            fail(failures, "windows-reload-remediation-config: Config.txt must remain entirely CRLF")
        for marker in (
            b'MDIPosition=(120,80,1280,760)', b'ActiveTab=1',
            b'BytesSent=487', b'BytesReceived=722', b'SecondsConnected=237',
            b'ConnectionCount=6', b'LastUsed=2026-7-24-23-28-17-836',
            b'Password="fixture-only-password"',
            b'Connect="connect hero %PASSWORD%"',
            b'FileName="C:\\\\M9Audit\\\\RoundTrip.atlas"',
            b'Sound="C:\\\\M9Audit\\\\Assets\\\\notify.wav"',
            b'Description="M9 global added"', b'Description="Global updated"',
            b'Description="M9 world added"', b'Name="world_update"',
            b'Value="mac-world"', b'Description="M9 character added"',
            b'key=Control+Alt+H', b'Macro="health"', b'Type=true',
            b'Name="character_update"', b'Value="mac-character"',
            b'Description="M9 puppet added"', b'Description="Puppet updated"',
        ):
            if marker not in windows_remediation_config:
                fail(failures, f"windows-reload-remediation-config: missing {marker!r}")
        for forbidden in (
            b'Description="Global delete"', b'Name="world_delete"',
            b'Name="character_delete"', b'Description="Puppet macro delete"',
            b'AIModel=', b'GMCP_WebView=', b'TCP_KeepAlive=', b'TCP_NoDelay=',
            b'ConnectTimeout=30000', b'ConnectRetry=5', b'RetryForever=false',
            b'ScriptStartup=""', b'ScriptDebug=false', b'Encoding=CP1252',
            b'ConnectAtStartup=false', b'IdleEnabled=false',
            b'RegularExpression=false', b'MatchCase=false',
            b'StartsWith=false', b'EndsWith=false', b'WholeWord=false',
        ):
            if forbidden in windows_remediation_config:
                fail(
                    failures,
                    f"windows-reload-remediation-config: forbidden/default syntax {forbidden!r}",
                )

    windows_remediation_restore_record = next(
        (r for r in records if r.get("role") == "windows-reload-remediation-restore"),
        {},
    )
    windows_remediation_restore = artifact_data.get(
        "windows-reload-remediation-restore"
    )
    if windows_remediation_restore is not None:
        buffer_size = windows_remediation_restore_record.get("bufferSize", 0)
        verify_restore(
            windows_remediation_restore,
            buffer_size,
            failures,
            "windows-reload-remediation-restore",
            minimum_buffers=1,
        )
        payloads = restore_payloads(windows_remediation_restore, buffer_size)
        if len(payloads) != 1 or b"M9 macOS append\r\n" not in payloads[0]:
            fail(
                failures,
                "windows-reload-remediation-restore: remediation append was lost",
            )

    windows_remediation_inventory = artifact_data.get(
        "windows-reload-remediation-semantic-inventory"
    )
    if windows_remediation_inventory:
        try:
            inventory = json.loads(windows_remediation_inventory.decode("utf-8-sig"))
            operations = inventory.get("portableOperations", [])
            if len(operations) != 14 or any(not item.get("passed") for item in operations):
                fail(failures, "windows remediation inventory: not all 14 operations pass")
            if inventory.get("parseErrors") != []:
                fail(failures, "windows remediation inventory: parser errors are not empty")
            session = inventory.get("session", {})
            if not session.get("loadedWithoutConfigurationErrors"):
                fail(failures, "windows remediation inventory: configuration errors recorded")
            if session.get("saveConfirmationsRequired"):
                fail(failures, "windows remediation inventory: save confirmation was required")
            if not session.get("auditSessionCrashFree"):
                fail(failures, "windows remediation inventory: audit interval is not crash-free")
            if inventory.get("unexplainedMutations") != []:
                fail(failures, "windows remediation inventory: unexplained mutations remain")
            recovered = inventory.get("explicitRecoveredOperations", {})
            if not all(recovered.get(name, {}).get("passed") for name in (
                "worldUpdate", "characterMacro", "restoreAppend",
            )):
                fail(failures, "windows remediation inventory: a prior Sprint 9.3 loss remains")
            historical = inventory.get("comparisonToFailedSprint93", {}).get(
                "historicalApplicationCrash", {}
            )
            if not historical.get("retained") or historical.get("faultOffset") != "0x00000000000a9bb0":
                fail(failures, "windows remediation inventory: historical APPCRASH changed")
            if not inventory.get("allChecksPassed"):
                fail(failures, "windows remediation inventory: overall checks failed")
        except (UnicodeDecodeError, json.JSONDecodeError, TypeError) as error:
            fail(failures, f"windows remediation inventory unreadable: {error}")

    windows_remediation_events = artifact_data.get(
        "windows-reload-remediation-application-events"
    )
    if windows_remediation_events:
        try:
            events = json.loads(windows_remediation_events.decode("utf-8-sig"))
            if events.get("matchingEvents") != []:
                fail(failures, "windows remediation event interval contains BeipMU events")
            if events.get("crashes") != [] or events.get("hangs") != []:
                fail(failures, "windows remediation event interval contains crash/hang evidence")
        except (UnicodeDecodeError, json.JSONDecodeError, TypeError) as error:
            fail(failures, f"windows remediation application events unreadable: {error}")

    for mac_role, windows_role in (
        ("macos-remediation-atlas", "windows-reload-remediation-atlas"),
        ("macos-remediation-image", "windows-reload-remediation-image"),
        ("macos-remediation-sound", "windows-reload-remediation-sound"),
        ("macos-remediation-script", "windows-reload-remediation-script"),
        ("macos-remediation-log", "windows-reload-remediation-prior-log"),
        ("macos-remediation-seed-log", "windows-reload-remediation-seed-log"),
    ):
        if mac_role in artifact_data and windows_role in artifact_data:
            if artifact_data[mac_role] != artifact_data[windows_role]:
                fail(failures, f"{windows_role}: bytes differ from remediation input")

    audit_log = artifact_data.get("windows-reload-remediation-audit-log", b"")
    if not audit_log:
        fail(failures, "windows-reload-remediation-audit-log: missing or empty")

    failed_inventory = artifact_data.get("windows-reload-semantic-inventory")
    if failed_inventory:
        try:
            inventory = json.loads(failed_inventory.decode("utf-8-sig"))
            failed_ids = [item.get("id") for item in inventory.get("failures", [])]
            if failed_ids[:3] != [
                "world-update-variable", "character-add-macro", "restore-append",
            ]:
                fail(failures, "failed Sprint 9.3 inventory: recorded losses changed")
            if inventory.get("unexplainedMutations") != []:
                fail(failures, "failed Sprint 9.3 inventory: unexplained mutations were reclassified")
            if inventory.get("session", {}).get("accepted") is not False:
                fail(failures, "failed Sprint 9.3 inventory: failure was allowlisted")
        except (UnicodeDecodeError, json.JSONDecodeError, TypeError) as error:
            fail(failures, f"failed Sprint 9.3 inventory unreadable: {error}")

    failed_reload_config = artifact_data.get("windows-reload-config", b"")
    if failed_reload_config and remediation_config:
        if b'Name="world_update"' in failed_reload_config:
            fail(failures, "failed Sprint 9.3 comparison: world variable loss is no longer represented")
        if b'Description="M9 character added"' in failed_reload_config:
            fail(failures, "failed Sprint 9.3 comparison: character macro loss is no longer represented")
        if b'Name="world_update"' not in remediation_config:
            fail(failures, "remediation comparison: world variable remains lost")
        if b'Description="M9 character added"' not in remediation_config:
            fail(failures, "remediation comparison: character macro remains lost")

    failed_reload_restore = artifact_data.get("windows-reload-restore")
    if failed_reload_restore:
        failed_record = next(
            (r for r in records if r.get("role") == "windows-reload-restore"), {}
        )
        failed_payloads = restore_payloads(
            failed_reload_restore, failed_record.get("bufferSize", 0)
        )
        if any(b"M9 macOS append\r\n" in buffer for buffer in failed_payloads):
            fail(failures, "failed Sprint 9.3 comparison: restore loss is no longer represented")

    for baseline_role, mac_role in (
        ("windows-baseline-image", "macos-reload-image"),
        ("windows-baseline-sound", "macos-reload-sound"),
        ("windows-baseline-script", "macos-reload-script"),
        ("windows-baseline-log", "macos-reload-log"),
        ("windows-baseline-seed-log", "macos-reload-seed-log"),
        ("windows-baseline-image", "macos-remediation-image"),
        ("windows-baseline-sound", "macos-remediation-sound"),
        ("windows-baseline-script", "macos-remediation-script"),
        ("windows-baseline-log", "macos-remediation-log"),
        ("windows-baseline-seed-log", "macos-remediation-seed-log"),
    ):
        if baseline_role in artifact_data and mac_role in artifact_data:
            if artifact_data[baseline_role] != artifact_data[mac_role]:
                fail(failures, f"{mac_role}: untouched bytes differ from Windows baseline")

    semantic = load_artifact_json(
        artifact_data, "macos-final-acceptance-semantic-comparison", failures
    )
    semantic_operations = semantic.get("portableOperations", [])
    semantic_ids = [item.get("id") for item in semantic_operations]
    if semantic.get("decision") != "accepted":
        fail(failures, "final semantic comparison: decision is not accepted")
    if semantic_ids != ids or any(not item.get("passed") for item in semantic_operations):
        fail(failures, "final semantic comparison: operation results do not match the contract")
    if not semantic.get("assetsAndLogs", {}).get("allPreservedExact"):
        fail(failures, "final semantic comparison: assets or prior logs are not exact")
    if not semantic.get("atlas", {}).get("exactMacosInputEquality"):
        fail(failures, "final semantic comparison: atlas output is not exact")
    restore_summary = semantic.get("restore", {})
    if (
        not restore_summary.get("ringStructureValid")
        or not restore_summary.get("appendPreserved")
        or restore_summary.get("priorRecordCountPreserved")
        != restore_summary.get("input", {}).get("recordCount")
    ):
        fail(failures, "final semantic comparison: restore semantics are incomplete")
    difference_summary = semantic.get("differenceSummary", {})
    if (
        not difference_summary.get("allDifferencesClassified")
        or difference_summary.get("currentUnexplainedDifferences") != []
        or difference_summary.get("currentFailureOrUnexplainedDifferenceCount") != 0
    ):
        fail(failures, "final semantic comparison: unexplained differences remain")
    acceptance = semantic.get("acceptanceCriteria", {})
    if not acceptance.get("accepted") or not all(
        value is True for value in acceptance.values()
    ):
        fail(failures, "final semantic comparison: an acceptance criterion failed")

    classified = load_artifact_json(
        artifact_data, "macos-final-acceptance-classified-differences", failures
    )
    if set(classified.get("classificationVocabulary", [])) != DIFFERENCE_CLASSIFICATIONS:
        fail(failures, "difference report: classification vocabulary differs from Sprint 9.4")
    current_differences = classified.get("currentRemediationDifferences", [])
    current_ids = [item.get("id") for item in current_differences]
    if len(current_ids) != len(set(current_ids)):
        fail(failures, "difference report: current difference IDs are missing or duplicated")
    operation_classifications = {
        item.get("id"): item.get("classification")
        for item in current_differences
        if item.get("id") in ids
    }
    if operation_classifications != {
        operation_id: "intended portable edit" for operation_id in ids
    }:
        fail(failures, "difference report: portable operations are not classified exactly once")
    canonicalization_ids = {
        item.get("id")
        for item in current_differences
        if item.get("classification") == "documented Windows canonicalization"
    }
    if canonicalization_ids != WINDOWS_CANONICALIZATION_IDS:
        fail(failures, "difference report: Windows canonicalization allowlist changed")
    sidecar_differences = [
        item for item in current_differences
        if item.get("classification") == "allowed host-specific sidecar state"
    ]
    if [item.get("id") for item in sidecar_differences] != ["macos-config-sidecar"]:
        fail(failures, "difference report: host-specific sidecar classification is incomplete")
    if any(item.get("classification") not in DIFFERENCE_CLASSIFICATIONS for item in current_differences):
        fail(failures, "difference report: an unknown current classification is present")
    if any(item.get("classification") == "failure" for item in current_differences):
        fail(failures, "difference report: a current failure remains")
    if classified.get("currentFailureOrUnexplainedDifferences") != []:
        fail(failures, "difference report: current failures or unexplained differences remain")
    historical = classified.get("historicalFailedSprint93Differences", [])
    if (
        len(historical) != 4
        or any(item.get("classification") != "failure" for item in historical)
        or any(item.get("historical") is not True for item in historical)
    ):
        fail(failures, "difference report: historical failures were changed or allowlisted")
    classification_checks = classified.get("checks", {})
    if (
        not classification_checks.get("everyCurrentDifferenceClassifiedExactlyOnce")
        or classification_checks.get("currentFailureOrUnexplainedDifferenceCount") != 0
        or not classification_checks.get("historicalFailuresKeptSeparate")
    ):
        fail(failures, "difference report: classification checks do not pass")

    raw_hashes = load_artifact_json(
        artifact_data, "macos-final-acceptance-raw-hashes", failures
    )
    stage_roots = {
        "windowsBaseline": ROOT / "Documentation/Evidence/M9/win11-dev/baseline",
        "macosRemediationInput": ROOT / "Documentation/Evidence/M9/macos-reload-remediation",
        "windowsRemediationOutput": (
            ROOT / "Documentation/Evidence/M9/win11-dev/reload-remediation/post-reload"
        ),
        "historicalFailedWindowsOutput": (
            ROOT / "Documentation/Evidence/M9/win11-dev/reload/post-reload"
        ),
    }
    hash_stages = raw_hashes.get("stages", {})
    for stage, stage_root in stage_roots.items():
        expected_hashes = hash_stages.get(stage)
        if not isinstance(expected_hashes, dict) or not expected_hashes:
            fail(failures, f"raw hash inventory: missing stage {stage}")
            continue
        for relative, expected_hash in expected_hashes.items():
            path = stage_root / relative
            if (
                PurePosixPath(relative).is_absolute()
                or ".." in PurePosixPath(relative).parts
                or not path.is_file()
            ):
                fail(failures, f"raw hash inventory: unsafe or missing {stage}/{relative}")
            elif digest(path.read_bytes()) != expected_hash:
                fail(failures, f"raw hash inventory: mismatch for {stage}/{relative}")
    expected_output_members = set(
        hash_stages.get("windowsRemediationOutput", {}).keys()
    )
    output_root = stage_roots["windowsRemediationOutput"]
    actual_output_members = {
        path.relative_to(output_root).as_posix()
        for path in output_root.rglob("*")
        if path.is_file()
    }
    if actual_output_members != expected_output_members:
        fail(failures, "Windows output: an unexplained file addition or removal is present")
    if not raw_hashes.get("rawExactBytes") or not raw_hashes.get("allRecordedHashesVerified"):
        fail(failures, "raw hash inventory: exact-byte verification is not accepted")

    final_verifier = load_artifact_json(
        artifact_data, "macos-final-acceptance-verifier-result", failures
    )
    final_checks = final_verifier.get("checks", {})
    if (
        final_verifier.get("status") != "pass"
        or final_verifier.get("failedAcceptanceChecks") != []
        or final_verifier.get("acceptance") is not True
        or final_checks.get("milestone9ContractTestCount") != 14
        or final_checks.get("milestone9ContractTestFailures") != 0
        or final_checks.get("fullSwiftSuite") is not True
        or final_checks.get("fullSwiftTestCount") != 272
        or final_checks.get("fullSwiftTestFailures") != 0
    ):
        fail(failures, "recorded final verifier result does not pass")

    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(f"verified M9 contract: {len(records)} artifacts, {len(operations)} operations, raw hashes exact")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
