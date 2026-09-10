"""Antigravity (AGY) usage collector.

Combines local session/token stats read from Antigravity conversation SQLite
databases with quota allowances from `agy -p /usage --output-format json`.
Reads only: never writes to conversation databases.
"""

from __future__ import annotations

import io
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import threading
import time
from datetime import datetime, timedelta
from typing import Any, Iterable, Iterator

from .common import (
    MAX_RESPONSE_BYTES,
    auth_missing,
    base_record,
    endpoint_problem,
    print_record,
)

AGENT_ID = "agy"
AGENT_NAME = "Antigravity"
AUTH_HELP = "Run `agy` to sign in. Local stats are still shown."
STATUS_QUOTA_UNAVAILABLE = f"{AGENT_NAME} quota unavailable"
STATUS_DATABASE_ERROR = f"{AGENT_NAME} database error"
STATUS_DB_ERROR = STATUS_DATABASE_ERROR
# Antigravity embeds an entire tool payload or the full chat context in some
# gen_metadata/steps rows (observed up to ~920 KiB); this bounds how much of a
# row we will ever read, without excluding the small usage fields that live
# alongside that bulk data.
MAX_METADATA_BYTES = 2 * 1024 * 1024
# A single embedded field this large is bulk context/tool-payload data we
# never read, not a token/timestamp/model field. ProtobufParser skips past
# oversized fields instead of aborting the whole message, so the small fields
# that matter still get parsed regardless of where they sit in the message.
MAX_FIELD_BYTES = 64 * 1024
TOKEN_BUCKET = {
    "inputTokens": 0,
    "outputTokens": 0,
    "cacheReadInputTokens": 0,
    "cacheCreationInputTokens": 0,
}

# ---------------------------------------------------------------------------
# Lightweight Protobuf Wire-Format Decoder
#
# Antigravity stores generation token metadata and step timestamps as binary
# protobuf blobs in SQLite (gen_metadata.data and steps.metadata). To keep this
# collector dependency-free Python (3.10+) as described in collectors/README.md
# (avoiding third-party dependencies such as google.protobuf), this module
# implements a hand-written, stream-based Tag-Length-Value (TLV) wire format
# parser. Some rows embed a large, unrelated field (full chat context, tool
# payloads) alongside the small usage/timestamp fields we actually want; the
# parser skips oversized fields rather than aborting the whole message, so
# those small fields are still found regardless of field order.
# ---------------------------------------------------------------------------

class ProtobufParser:
    """Lightweight hand-written Protobuf wire-format parser.

    Decodes Tag-Length-Value (TLV) fields from a protobuf binary payload.
    Implements Iterable, yielding (field_number, wire_type, value) tuples.
    """

    def __init__(self, source: bytes | bytearray) -> None:
        self._data: bytes | bytearray = source
        self._valid: bool = bool(source and len(source) <= MAX_METADATA_BYTES)

    @staticmethod
    def read_varint(stream: io.BytesIO) -> int | None:
        """Decodes an unsigned variable-length integer (varint) from a byte stream.

        In protobuf, each byte of a varint contributes 7 bits of value; the high
        bit (0x80) indicates continuation. Returns None on premature EOF or overflow.
        """
        VARINT_DATA_MASK = 0x7F
        VARINT_CONTINUATION_BIT = 0x80
        VARINT_SHIFT_STEP = 7
        MAX_VARINT_SHIFT = 70

        val = shift = 0
        while True:
            b = stream.read(1)
            if not b:
                return None
            byte = b[0]
            val |= (byte & VARINT_DATA_MASK) << shift
            if not (byte & VARINT_CONTINUATION_BIT):
                return val
            shift += VARINT_SHIFT_STEP
            if shift > MAX_VARINT_SHIFT:
                return None

    def __iter__(self) -> Iterator[tuple[int, int, bytes | int]]:
        """Iterates through Tag-Length-Value (TLV) fields in the protobuf payload.

        Yields (field_number, wire_type, value) where value is:
          - int for WIRE_VARINT
          - bytes for WIRE_LENGTH_DELIMITED, WIRE_FIXED64, and WIRE_FIXED32

        Fields are decoded purely by their wire tag ((field_number << 3) | wire_type),
        so unknown fields or field order variations are handled safely and skipped.
        If the payload is invalid, yields nothing.
        """
        if not self._valid:
            return

        WIRE_VARINT = 0             # int32, int64, uint32, uint64, bool, enum
        WIRE_FIXED64 = 1            # fixed64, sfixed64, double (8 bytes)
        WIRE_LENGTH_DELIMITED = 2   # string, bytes, embedded submessage, packed array
        WIRE_FIXED32 = 5            # fixed32, sfixed32, float (4 bytes)

        FIXED64_BYTE_SIZE = 8
        FIXED32_BYTE_SIZE = 4

        WIRE_TYPE_MASK = 0x07
        WIRE_TYPE_BIT_SHIFT = 3

        MIN_PROTO_FIELD_NUMBER = 1
        MAX_PROTO_FIELD_NUMBER = (1 << 29) - 1

        stream = io.BytesIO(self._data)
        while True:
            key = self.read_varint(stream)
            if key is None:
                break
            field_num = key >> WIRE_TYPE_BIT_SHIFT
            wire_type = key & WIRE_TYPE_MASK

            if field_num < MIN_PROTO_FIELD_NUMBER or field_num > MAX_PROTO_FIELD_NUMBER:
                # Illegal protobuf field number; stop parsing defensively
                break

            if wire_type == WIRE_VARINT:
                val = self.read_varint(stream)
                if val is None:
                    break
                yield field_num, wire_type, val
            elif wire_type == WIRE_LENGTH_DELIMITED:
                length = self.read_varint(stream)
                if length is None or length < 0:
                    break
                if length > MAX_FIELD_BYTES:
                    # Bulk data we never read (chat context, tool payloads):
                    # skip past it without materializing it, and keep parsing
                    # so later, smaller fields (tokens, timestamps) aren't lost.
                    stream.seek(length, io.SEEK_CUR)
                    continue
                payload = stream.read(length)
                if len(payload) < length:
                    break
                yield field_num, wire_type, payload
            elif wire_type == WIRE_FIXED64:
                payload = stream.read(FIXED64_BYTE_SIZE)
                if len(payload) < FIXED64_BYTE_SIZE:
                    break
                yield field_num, wire_type, payload
            elif wire_type == WIRE_FIXED32:
                payload = stream.read(FIXED32_BYTE_SIZE)
                if len(payload) < FIXED32_BYTE_SIZE:
                    break
                yield field_num, wire_type, payload
            else:
                # Unsupported wire type; stop parsing defensively
                break


def _text(value: bytes | bytearray) -> str:
    return value.decode("utf-8", errors="replace").strip()


def _timestamp(value: bytes | bytearray) -> int | None:
    for field, _, item in ProtobufParser(value):
        if field == 1 and isinstance(item, int) and 1_000_000_000 <= item <= 2_500_000_000:
            return item
    return None


def _usage_event(
    value: bytes | bytearray,
    *,
    model: str = "",
    timestamp: int | None = None,
) -> dict[str, Any]:
    """Decode one ModelUsageStats protobuf without retaining opaque data."""
    input_tokens = output_tokens = cache_read = cache_creation = 0
    thinking = visible = 0
    identities: list[str] = []
    response_id = ""
    for field, _, item in ProtobufParser(value):
        if field == 2 and isinstance(item, int):
            input_tokens = item
        elif field == 3 and isinstance(item, int):
            output_tokens = item
        elif field == 4 and isinstance(item, int):
            cache_creation = item
        elif field == 5 and isinstance(item, int):
            cache_read = item
        elif field == 9 and isinstance(item, int):
            thinking = item
        elif field == 10 and isinstance(item, int):
            visible = item
        elif field in (7, 11, 12) and isinstance(item, (bytes, bytearray)):
            decoded = _text(item)
            if decoded:
                kind = {7: "agent", 11: "response", 12: "provider"}[field]
                identities.append(f"{kind}:{decoded}")
                if field == 11:
                    response_id = decoded
    return {
        "model": model,
        "input": input_tokens,
        "output": max(output_tokens, thinking + visible),
        "cacheRead": cache_read,
        "cacheCreation": cache_creation,
        "timestamp": timestamp,
        "identities": identities,
        "responseId": response_id,
    }


def _generation_events(g_data: bytes | bytearray) -> list[dict[str, Any]]:
    """Return primary and retry usage entries stored in gen_metadata.data."""
    model = ""
    timestamp = None
    usage_blobs: list[bytes | bytearray] = []
    retry_blobs: list[bytes | bytearray] = []
    for field, _, value in ProtobufParser(g_data):
        if field != 1 or not isinstance(value, (bytes, bytearray)):
            continue
        for sub_field, _, sub_value in ProtobufParser(value):
            if sub_field in (19, 21) and isinstance(sub_value, (bytes, bytearray)):
                model = _text(sub_value) or model
            elif sub_field == 3 and isinstance(sub_value, int) and not model:
                model = f"antigravity-model-{sub_value}"
            elif sub_field == 4 and isinstance(sub_value, (bytes, bytearray)):
                usage_blobs.append(sub_value)
            elif sub_field == 9 and isinstance(sub_value, (bytes, bytearray)):
                for timing_field, _, timing_value in ProtobufParser(sub_value):
                    if timing_field == 4 and isinstance(timing_value, (bytes, bytearray)):
                        timestamp = _timestamp(timing_value) or timestamp
            elif sub_field == 17 and isinstance(sub_value, (bytes, bytearray)):
                retry_blobs.append(sub_value)
    events = [_usage_event(blob, model=model, timestamp=timestamp) for blob in usage_blobs]
    for retry in retry_blobs:
        for field, _, value in ProtobufParser(retry):
            if field == 2 and isinstance(value, (bytes, bytearray)):
                events.append(_usage_event(value, model=model, timestamp=timestamp))
    return events


def parse_gen_metadata(g_data: bytes) -> tuple[str, int, int, int, str]:
    """Extracts model name, token counts, and response ID from gen_metadata.data.

    Antigravity stores generation records in a nested Protobuf envelope:

        message CortexGeneratorMetadata {
            // FIELD_GEN_INFO (wire type 2, tag 0x0A): Generation payload
            GenerationInfo gen_info = 1;
            // (wire type 2, tag 0x12): Generator status/completeness flags
            bytes is_full = 2;
            // (wire type 2, tag 0x22): Session trajectory UUID
            string trajectory_id = 4;
            // (wire type 2, tag 0x2A): Error string if stream failed
            string error_message = 5;
            // (wire type 2, tag 0x42): Execution hash/identifier
            bytes execution_id = 8;
        }

        message GenerationInfo {
            // (wire type 0, tag 0x18): Internal model enum identifier
            int64 model_enum = 3;
            // FIELD_USAGE_METADATA (wire type 2, tag 0x22): Token usage stats
            ModelUsageStats usage = 4;
            // (wire type 2, tag 0x4A): Prompt breakdown metadata
            bytes prompt_section_metadata = 9;
            // (wire type 2, tag 0x5A): Retry / attempt counters
            bytes retry_info = 11;
            // (wire type 2, tag 0x62): Generation latency timings
            bytes latency_breakdown = 12;
            // (wire type 2, tag 0x8A 0x01): Internal billing cost metrics
            bytes model_cost = 17;
            // FIELD_MODEL_NAME (wire type 2, tag 0x9A 0x01): e.g. "gemini-3.8-flash"
            string model_name = 19;
            // (wire type 2, tag 0xA2 0x01): Trajectory metadata map (e.g. request_id)
            map<string, string> metadata_map = 20;
        }

        message ModelUsageStats {
            // Internal model enum (1298=gemini-3.7-flash, 1318=gemini-3.8-flash)
            enum Model model = 1;
            // FIELD_INPUT_TOKENS (wire type 0, tag 0x10): Fresh un-cached prompt tokens
            int64 input_tokens = 2;
            // FIELD_OUTPUT_TOKENS (wire type 0, tag 0x18): Total output tokens
            // Note: output_tokens == thinking_output_tokens + response_output_tokens
            int64 output_tokens = 3;
            // FIELD_CACHE_READ_TOKENS (wire type 0, tag 0x28): Prompt tokens from cache
            int64 cache_read_tokens = 5;
            // (wire type 0, tag 0x30): Service tier / routing flag (constant 24)
            int64 service_tier = 6;
            // (wire type 2, tag 0x3A): Bot instance UUID (e.g. "bot-<uuid>")
            string agent_id = 7;
            // (wire type 2, tag 0x42): Session key-value pair (e.g. sessionID)
            map<string, string> session_metadata = 8;
            // (wire type 0, tag 0x48): Reasoning tokens (already in output_tokens)
            int64 thinking_output_tokens = 9;
            // (wire type 0, tag 0x50): Candidate text tokens (already in output_tokens)
            int64 response_output_tokens = 10;
            // FIELD_RESPONSE_ID (wire type 2, tag 0x5A): Upstream Gemini response ID
            string response_id = 11;
        }

    Returns:
        (model_name, input_tokens, output_tokens, cache_read_tokens, response_id).
        Defaults to ("", 0, 0, 0, "") if payload is empty, corrupted, or has no counts.
    """
    events = _generation_events(g_data)
    if not events:
        return ("", 0, 0, 0, "")
    event = events[0]
    return (event["model"], event["input"], event["output"], event["cacheRead"], event["responseId"])


def parse_step_timestamp(s_meta: bytes) -> int | None:
    """Extracts unix timestamp seconds from steps.metadata.

    Antigravity stores step execution headers in a nested Protobuf envelope:

        message CortexStepMetadata {
            // FIELD_STEP_HEADER (wire type 2, tag 0x0A): Step creation timestamp
            google.protobuf.Timestamp created_at = 1;
            // (wire type 0, tag 0x18): Step source / author (user, model, tool)
            int64 source = 3;
            // (wire type 2, tag 0x22): Invoked tool name, call ID, JSON arguments
            ToolCallMetadata tool_call = 4;
            // (wire type 2, tag 0x32): Tool execution start timestamp
            google.protobuf.Timestamp started_at = 6;
            // (wire type 2, tag 0x3A): Tool execution completion timestamp
            google.protobuf.Timestamp completed_at = 7;
            // (wire type 2, tag 0x42): UI display availability timestamp
            google.protobuf.Timestamp viewable_at = 8;
            // (wire type 2, tag 0x4A): Step model usage (matches gen_metadata 1.4)
            ModelUsageStats model_usage = 9;
            // (wire type 0, tag 0x58): Generator model enum (e.g. 1298, 1318)
            int64 generator_model = 11;
            // (wire type 2, tag 0x62): Step execution identifier UUID
            string execution_id = 12;
            // (wire type 2, tag 0xA2 0x01): Step session and trajectory identifiers
            StepSessionInfo step_session = 20;
            // (wire type 2, tag 0xD2 0x01): Detailed timing and latency breakdown
            bytes timing_events = 26;
            // (wire type 2, tag 0xE2 0x01): Credit/cost usage for step
            bytes model_cost = 28;
            // (wire type 2, tag 0x82 0x02): Model streaming finish timestamp
            google.protobuf.Timestamp finished_generating_at = 32;
            // (wire type 0, tag 0x88 0x02): Whether user or hook interrupted step
            bool is_interrupting_step = 33;
            // (wire type 2, tag 0x92 0x02): Tool approval status (e.g. "allow")
            PermissionDecision permissions = 34;
        }

        message Timestamp {
            // FIELD_TIMESTAMP_SECONDS (wire type 0, tag 0x08): Unix epoch seconds
            int64 seconds = 1;
            // (wire type 0, tag 0x10): Fractional second nanoseconds
            int32 nanos = 2;
        }

        message ToolCallMetadata {
            // Tool call ID (e.g. "call_12345")
            string call_id = 1;
            // Tool function name (e.g. "run_command", "grep_search")
            string tool_name = 2;
            // JSON-encoded tool invocation parameters
            string arguments_json = 3;
            // Tool execution context and signature
            bytes context = 7;
        }

        message StepSessionInfo {
            // Client session UUID
            string session_id = 1;
            // 0-indexed step number (idx)
            int64 step_index = 2;
            // Sub-step attempt / retry index
            int64 attempt_index = 3;
            // Root conversation UUID
            string conversation_id = 4;
        }

    Returns:
        Unix timestamp in seconds (e.g. 1757088000), or None if missing or non-positive.
    """
    fields = list(ProtobufParser(s_meta))
    for timestamp_field in (8, 1):
        for field, _, value in fields:
            if field == timestamp_field and isinstance(value, (bytes, bytearray)):
                timestamp = _timestamp(value)
                if timestamp:
                    return timestamp
    return None


def _step_events(s_meta: bytes | bytearray) -> list[dict[str, Any]]:
    """Decode usage and retry entries from optional steps.metadata rows."""
    timestamp = parse_step_timestamp(s_meta)
    model = ""
    usage_blobs: list[bytes | bytearray] = []
    retry_blobs: list[bytes | bytearray] = []
    for field, _, value in ProtobufParser(s_meta):
        if field == 9 and isinstance(value, (bytes, bytearray)):
            usage_blobs.append(value)
        elif field == 24 and isinstance(value, (bytes, bytearray)):
            for info_field, _, info_value in ProtobufParser(value):
                if info_field in (8, 12) and isinstance(info_value, (bytes, bytearray)):
                    model = _text(info_value) or model
        elif field == 28 and isinstance(value, (bytes, bytearray)):
            retry_blobs.append(value)
    events = [_usage_event(blob, model=model, timestamp=timestamp) for blob in usage_blobs]
    for retry in retry_blobs:
        for field, _, value in ProtobufParser(retry):
            if field == 2 and isinstance(value, (bytes, bytearray)):
                events.append(_usage_event(value, model=model, timestamp=timestamp))
    return events


def default_conversations_dirs() -> list[Path]:
    override = os.environ.get("AGY_CONVERSATIONS_DIR")
    if override:
        return [Path(p.strip()) for p in override.split(os.pathsep) if p.strip()]
    agy_home = os.environ.get("AGY_HOME")
    if agy_home:
        return [Path(agy_home) / "conversations"]
    home = Path.home()
    return [
        home / ".gemini" / "antigravity" / "conversations",
        home / ".gemini" / "antigravity-cli" / "conversations",
        home / ".gemini" / "antigravity-ide" / "conversations",
    ]


def stats_from_rows(
    rows: Iterable[tuple[str, bytes | None, bytes | None, float | None]],
    now: datetime | None = None,
) -> dict[str, Any]:
    """Aggregates local token and session metrics from conversation generation rows.

    Each row is: (session_id, gen_metadata_blob, step_metadata_blob, fallback_mtime).
    """
    def events() -> Iterator[dict[str, Any]]:
        for session_id, g_data, s_meta, fallback_mtime in rows:
            for event in _generation_events(g_data) if isinstance(g_data, (bytes, bytearray)) else []:
                yield {**event, "session": session_id, "fallback": fallback_mtime}
            for event in _step_events(s_meta) if isinstance(s_meta, (bytes, bytearray)) else []:
                yield {**event, "session": session_id, "fallback": fallback_mtime}
    return stats_from_events(events(), now=now)


def stats_from_events(events: Iterable[dict[str, Any]], now: datetime | None = None) -> dict[str, Any]:
    """Aggregate token-bearing protobuf entries, merging duplicate identities safely."""
    current_now = now or datetime.now()
    today = current_now.strftime("%Y-%m-%d")
    recent_dates = [(current_now - timedelta(days=offset)).strftime("%Y-%m-%d") for offset in range(6, -1, -1)]
    recent = {day: {"date": day, "messageCount": 0} for day in recent_dates}
    deduped: list[dict[str, Any]] = []
    by_identity: dict[str, dict[str, Any]] = {}
    for event in events:
        identities = [value for value in event.get("identities", []) if isinstance(value, str) and value]
        existing = next((by_identity[value] for value in identities if value in by_identity), None)
        if existing is None:
            deduped.append(event)
            for value in identities:
                by_identity[value] = event
            continue
        for key in ("input", "output", "cacheRead", "cacheCreation"):
            existing[key] = max(int(existing.get(key, 0)), int(event.get(key, 0)))
        if not existing.get("model") and event.get("model"):
            existing["model"] = event["model"]
        if existing.get("timestamp") is None and event.get("timestamp") is not None:
            existing["timestamp"] = event["timestamp"]
        for value in identities:
            by_identity[value] = existing

    today_tokens_by_model: dict[str, dict[str, int]] = {}
    model_usage: dict[str, dict[str, int]] = {}
    today_sessions: set[str] = set()
    total_sessions: set[str] = set()
    active_days: set[str] = set()
    previous_model: dict[str, str] = {}
    today_prompts = today_total_tokens = total_prompts = 0
    for event in deduped:
        values = {key: max(0, int(event.get(key, 0))) for key in ("input", "output", "cacheRead", "cacheCreation")}
        total = sum(values.values())
        if total <= 0:
            continue
        session = str(event.get("session") or "")
        model = str(event.get("model") or previous_model.get(session) or "gemini")
        previous_model[session] = model
        day = None
        try:
            stamp = event.get("timestamp") or event.get("fallback")
            if stamp:
                day = datetime.fromtimestamp(float(stamp)).strftime("%Y-%m-%d")
        except (OSError, OverflowError, TypeError, ValueError):
            pass
        day = day or today
        total_prompts += 1
        total_sessions.add(session)
        active_days.add(day)
        bucket = model_usage.setdefault(model, dict(TOKEN_BUCKET))
        bucket["inputTokens"] += values["input"]
        bucket["outputTokens"] += values["output"]
        bucket["cacheReadInputTokens"] += values["cacheRead"]
        bucket["cacheCreationInputTokens"] += values["cacheCreation"]
        if day in recent:
            recent[day]["messageCount"] += total
        if day == today:
            today_prompts += 1
            today_sessions.add(session)
            today_total_tokens += total
            today_bucket = today_tokens_by_model.setdefault(model, dict(TOKEN_BUCKET))
            today_bucket["inputTokens"] += values["input"]
            today_bucket["outputTokens"] += values["output"]
            today_bucket["cacheReadInputTokens"] += values["cacheRead"]
            today_bucket["cacheCreationInputTokens"] += values["cacheCreation"]
    return {"todayPrompts": today_prompts, "todaySessions": len(today_sessions), "todayTotalTokens": today_total_tokens,
            "todayTokensByModel": today_tokens_by_model, "recentDays": [recent[d] for d in recent_dates],
            "modelUsage": model_usage, "totalPrompts": total_prompts, "totalSessions": len(total_sessions),
            "activeDays": len(active_days), "activeDates": sorted(active_days)}


def fetch_local_stats(
    record: dict[str, Any],
    conversations_dirs: list[Path] | None = None,
) -> bool:
    """Reads Antigravity SQLite conversation databases and updates record with local usage metrics.

    Returns True if local statistics are present, False otherwise.
    """
    def has_stats(stats: dict[str, Any]) -> bool:
        return bool(
            stats.get("totalPrompts", 0) > 0
            or stats.get("todayPrompts", 0) > 0
            or stats.get("todayTotalTokens", 0) > 0
            or stats.get("totalSessions", 0) > 0
        )

    dirs = conversations_dirs if conversations_dirs is not None else default_conversations_dirs()
    db_paths: list[Path] = []
    db_errors: list[str] = []
    for d in dirs:
        try:
            if d.is_dir():
                db_paths.extend(sorted(d.glob("*.db")))
        except OSError as exc:
            db_errors.append(f"{d.name}: {exc}")

    def table_exists(connection: sqlite3.Connection, name: str) -> bool:
        return connection.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1", (name,)).fetchone() is not None

    def trajectory_timestamp(connection: sqlite3.Connection) -> int | None:
        if not table_exists(connection, "trajectory_metadata_blob"):
            return None
        row = connection.execute(
            "SELECT data FROM trajectory_metadata_blob WHERE data IS NOT NULL AND length(data) <= ? LIMIT 1",
            (MAX_METADATA_BYTES,),
        ).fetchone()
        if not row or not isinstance(row[0], (bytes, bytearray)):
            return None
        for field, _, value in ProtobufParser(row[0]):
            if field == 2 and isinstance(value, (bytes, bytearray)):
                return _timestamp(value)
        return None

    def iter_events() -> Iterator[dict[str, Any]]:
        for db_path in db_paths:
            session_id = str(db_path)
            try:
                st = db_path.stat()
                if st.st_size == 0:
                    continue
                mtime = st.st_mtime
                # mode=ro protects the source while preserving SQLite's live WAL view.
                conn = sqlite3.connect(f"{db_path.resolve().as_uri()}?mode=ro", uri=True, timeout=2)
            except (OSError, sqlite3.Error) as exc:
                db_errors.append(f"{db_path.name}: {exc}")
                continue
            try:
                if not table_exists(conn, "gen_metadata"):
                    db_errors.append(f"{db_path.name}: missing gen_metadata table")
                    continue
                fallback_timestamp = trajectory_timestamp(conn)
                for (blob,) in conn.execute("SELECT data FROM gen_metadata WHERE data IS NOT NULL AND length(data) <= ? ORDER BY idx", (MAX_METADATA_BYTES,)):
                    if isinstance(blob, (bytes, bytearray)):
                        for event in _generation_events(blob):
                            if event["timestamp"] is None:
                                event["timestamp"] = fallback_timestamp
                            yield {**event, "session": session_id, "fallback": mtime}
                oversized = conn.execute("SELECT count(*) FROM gen_metadata WHERE data IS NOT NULL AND length(data) > ?", (MAX_METADATA_BYTES,)).fetchone()[0]
                if oversized:
                    db_errors.append(f"{db_path.name}: {oversized} metadata records exceed {MAX_METADATA_BYTES // 1024} KiB")
                if table_exists(conn, "steps"):
                    for (blob,) in conn.execute("SELECT metadata FROM steps WHERE metadata IS NOT NULL AND length(metadata) <= ? ORDER BY idx", (MAX_METADATA_BYTES,)):
                        if isinstance(blob, (bytes, bytearray)):
                            for event in _step_events(blob):
                                if event["timestamp"] is None:
                                    event["timestamp"] = fallback_timestamp
                                yield {**event, "session": session_id, "fallback": mtime}
                    oversized_steps = conn.execute("SELECT count(*) FROM steps WHERE metadata IS NOT NULL AND length(metadata) > ?", (MAX_METADATA_BYTES,)).fetchone()[0]
                    if oversized_steps:
                        db_errors.append(f"{db_path.name}: {oversized_steps} step records exceed {MAX_METADATA_BYTES // 1024} KiB")
            except sqlite3.Error as exc:
                db_errors.append(f"{db_path.name}: {exc}")
            finally:
                conn.close()

    stats = stats_from_events(iter_events())

    has_local_stats = has_stats(stats)
    record.update(stats)
    record["scope"] = "device"
    record["hasLocalStats"] = has_local_stats
    record["hasPromptStats"] = has_local_stats

    if db_errors:
        first_err = db_errors[0]
        suffix = f" (and {len(db_errors) - 1} other files)" if len(db_errors) > 1 else ""
        record["usageStatusText"] = STATUS_DATABASE_ERROR
        record["authHelpText"] = f"Failed to read conversation database: {first_err}{suffix}"[:300]

    return has_local_stats


def parse_quota_groups(groups: list[dict[str, Any]]) -> list[dict[str, Any]]:
    WINDOW_SPECS: dict[str, tuple[str, str, int]] = {
        # window: (base_title, label_suffix, order)
        "5h": ("Session", "(5-hour)", 0),
        "weekly": ("Weekly", "(7-day)", 1),
    }

    limits: list[dict[str, Any]] = []
    for group in groups:
        if not isinstance(group, dict): continue

        # The first group represents the primary quota (Session & Weekly).
        # Subsequent groups represent auxiliary model quotas (e.g. Claude & GPT).
        group_name = str(group.get("name") or "").strip()
        model_family = "" if not limits else re.sub(r"\s+models?$", "", group_name, flags=re.IGNORECASE).strip()

        buckets = group.get("buckets")
        if not isinstance(buckets, list): continue

        group_limits: list[tuple[int, dict[str, Any]]] = []
        for bucket in buckets:
            if not isinstance(bucket, dict): continue
            try:
                remaining = float(bucket.get("remaining_fraction"))
            except (ValueError, TypeError):
                continue

            window = bucket.get("window")
            if window in WINDOW_SPECS:
                base_title, suffix, order = WINDOW_SPECS[window]
            else:
                base_title = str(bucket.get("name") or window or "")
                suffix = ""
                order = 2

            title = f"{model_family} {base_title}".strip()
            label = f"{title} {suffix}".strip()

            group_limits.append((order, {
                "label": label,
                "title": title,
                "percent": max(0.0, min(1.0, round(1.0 - remaining, 4))),
                "resetsAt": str(bucket.get("reset_time") or ""),
            }))

        # Order session/short windows (5h) before weekly windows, matching Codex
        group_limits.sort(key=lambda item: item[0])
        limits.extend(item[1] for item in group_limits)

    return limits


def run_bounded_command(command: list[str], timeout_seconds: float, *, merge_stderr: bool = False) -> tuple[int, bytes]:
    """Run a collector command without buffering more than MAX_RESPONSE_BYTES.

    stderr is discarded by default: command output may include credentials or
    upstream response bodies, neither of which belongs in a collector record.
    Pass merge_stderr=True only for a fixed, low-risk status probe (never the
    quota command itself) whose stderr is a short built-in message the caller
    classifies and discards, never stores or surfaces verbatim.
    """
    process = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT if merge_stderr else subprocess.DEVNULL,
    )
    if process.stdout is None:  # pragma: no cover - subprocess guarantees this
        process.kill()
        process.wait()
        raise OSError("agy stdout pipe is unavailable")

    result: dict[str, bytes | BaseException] = {}

    def read_stdout() -> None:
        try:
            result["stdout"] = process.stdout.read(MAX_RESPONSE_BYTES + 1)
        except BaseException as exc:  # pragma: no cover - defensive pipe failure
            result["error"] = exc

    reader = threading.Thread(target=read_stdout, daemon=True)
    started = time.monotonic()
    reader.start()
    try:
        reader.join(timeout_seconds)
        if reader.is_alive():
            raise subprocess.TimeoutExpired(command, timeout_seconds)
        if "error" in result:
            raise OSError("Could not read agy output") from result["error"]
        stdout = result.get("stdout", b"")
        if not isinstance(stdout, bytes):  # pragma: no cover - typed guard
            raise OSError("Could not read agy output")
        if len(stdout) > MAX_RESPONSE_BYTES:
            raise ValueError("response payload too large")
        remaining = max(0.01, timeout_seconds - (time.monotonic() - started))
        returncode = process.wait(timeout=remaining)
        return returncode, stdout
    except subprocess.TimeoutExpired:
        process.kill()
        reader.join()
        process.wait()
        raise
    finally:
        if process.poll() is None:
            process.kill()
            reader.join()
            process.wait()
        process.stdout.close()


AGY_AUTH_PROBE_TIMEOUT_SECONDS = 5.0


AGY_AUTH_STATE_SIGNED_IN = "signed_in"
AGY_AUTH_STATE_SIGNED_OUT = "signed_out"
AGY_AUTH_STATE_UNKNOWN = "unknown"


def _agy_auth_state(agy_bin: str, timeout_seconds: float) -> str:
    """Cheap, non-interactive check for whether agy is signed in.

    `agy -p ...` runs a real agent turn: when signed out, it prints an OAuth
    URL, opens the user's browser, and blocks for up to a minute waiting for
    the callback. Calling it on every unattended refresh while signed out
    means a fresh browser tab grabbing focus on every cycle. `agy models`
    fails fast (no browser, no prompt) when signed out, so it gates every
    quota probe instead of ever letting a signed-out state reach `-p`.

    Returns AGY_AUTH_STATE_SIGNED_IN, AGY_AUTH_STATE_SIGNED_OUT (the probe
    itself reported the sign-in message), or AGY_AUTH_STATE_UNKNOWN — a probe
    failure unrelated to auth (timeout, launch failure, an unrecognized
    non-zero exit) — which the caller must treat as a transport problem, not
    silently as "not signed in". agy prints its sign-in message to stderr, so
    this merges stderr into the captured output (unlike the quota command,
    whose stderr is always discarded); the merged text is only classified
    here, never placed in the record.
    """
    try:
        returncode, output = run_bounded_command([agy_bin, "models"], timeout_seconds, merge_stderr=True)
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return AGY_AUTH_STATE_UNKNOWN
    if returncode == 0:
        return AGY_AUTH_STATE_SIGNED_IN
    if b"sign in" in output.lower():
        return AGY_AUTH_STATE_SIGNED_OUT
    return AGY_AUTH_STATE_UNKNOWN


def fetch_quota(
    record: dict[str, Any],
    command_override: list[str] | None = None,
    timeout_seconds: float = 8.0,
) -> bool:
    """Runs `agy -p /usage --output-format json` and updates record with limits or problem status.

    Returns True if quota information was successfully retrieved, False otherwise.
    """
    had_db_error = record.get("usageStatusText") == STATUS_DATABASE_ERROR
    previous_status = record.get("usageStatusText")
    previous_help = record.get("authHelpText")

    try:
        if command_override:
            cmd = command_override
        else:
            agy_bin = os.environ.get("AGY_CLI_PATH") or shutil.which("agy")
            if not agy_bin:
                auth_missing(record, status="Waiting for agy", help_text="agy not found in PATH")
                return False
            auth_state = _agy_auth_state(agy_bin, min(timeout_seconds, AGY_AUTH_PROBE_TIMEOUT_SECONDS))
            if auth_state == AGY_AUTH_STATE_SIGNED_OUT:
                auth_missing(record, status="Waiting for agy", help_text=AUTH_HELP)
                return False
            if auth_state == AGY_AUTH_STATE_UNKNOWN:
                endpoint_problem(record, status=STATUS_QUOTA_UNAVAILABLE, help_text="Could not confirm agy sign-in state", retry=True)
                return False
            cmd = [agy_bin, "-p", "/usage", "--output-format", "json"]

        try:
            returncode, stdout = run_bounded_command(cmd, timeout_seconds)
        except subprocess.TimeoutExpired:
            endpoint_problem(record, status=STATUS_QUOTA_UNAVAILABLE, help_text="Usage probe timed out", retry=True)
            return False
        except OSError:
            endpoint_problem(record, status=STATUS_QUOTA_UNAVAILABLE, help_text="Could not start agy. Check AGY_CLI_PATH or reinstall agy.")
            return False
        except ValueError:
            endpoint_problem(record, status=STATUS_QUOTA_UNAVAILABLE, help_text="Response payload too large")
            return False

        if returncode != 0:
            endpoint_problem(
                record,
                status=STATUS_QUOTA_UNAVAILABLE,
                help_text="The agy usage command failed. Run `agy` to confirm you are signed in.",
            )
            return False

        try:
            payload = json.loads(stdout)
        except (UnicodeDecodeError, ValueError, TypeError):
            endpoint_problem(record, status=STATUS_QUOTA_UNAVAILABLE, help_text="agy returned invalid JSON")
            return False

        if not isinstance(payload, dict):
            endpoint_problem(record, status=STATUS_QUOTA_UNAVAILABLE, help_text="Unexpected JSON shape")
            return False

        if payload.get("status") != "SUCCESS":
            endpoint_problem(
                record,
                status=STATUS_QUOTA_UNAVAILABLE,
                help_text="agy could not retrieve usage. Run `agy` to confirm you are signed in.",
            )
            return False

        command = payload.get("command")
        if not isinstance(command, dict):
            endpoint_problem(record, status=STATUS_QUOTA_UNAVAILABLE, help_text="Unexpected command payload")
            return False

        data = command.get("data")
        if not isinstance(data, dict):
            endpoint_problem(record, status=STATUS_QUOTA_UNAVAILABLE, help_text="Unexpected data payload")
            return False

        groups = data.get("groups", [])
        if not isinstance(groups, list):
            endpoint_problem(record, status=STATUS_QUOTA_UNAVAILABLE, help_text="No quota groups returned")
            return False

        record["limits"] = parse_quota_groups(groups)
        return True
    finally:
        if had_db_error:
            record["usageStatusText"] = previous_status
            record["authHelpText"] = previous_help


def collect() -> dict[str, Any]:
    record = base_record(AGENT_ID, AGENT_NAME, "Antigravity")
    local_ok = fetch_local_stats(record)
    quota_ok = fetch_quota(record)
    if local_ok or quota_ok:
        record["ready"] = True
    return record


def main() -> None:
    print_record(collect())


if __name__ == "__main__":
    main()
