"""OpenCode Go (Zen) usage collector.

Combines local session/token stats read from opencode's own SQLite state
database with the authoritative rolling/weekly/monthly allowances from Zen's
usage endpoint. Reads only: never writes to the database and never modifies
the signed-in account.
"""

from __future__ import annotations

import json
import os
import sqlite3
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from urllib.error import HTTPError

from .common import auth_missing, classify_failure, endpoint_problem, now_iso, print_record, request_json

AGENT_ID = "opencode"
AGENT_NAME = "OpenCode"
USAGE_ENDPOINT = "https://opencode.ai/zen/go/v1/usage"
PROVIDER_ID_IN_DB = "opencode-go"
# OpenCode has used both ids in the local database; the Go subscription
# endpoint is still keyed as opencode-go in auth.json.
PROVIDER_IDS = ("opencode-go", "opencode")
AUTH_HELP = "Sign in to OpenCode Go (`opencode auth login`) to show usage limits. Local stats are still shown."

_EMPTY_TOKEN_BUCKET = {"inputTokens": 0, "outputTokens": 0, "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0}


def opencode_paths() -> tuple[Path, Path]:
    data_home = Path(os.environ.get("XDG_DATA_HOME") or (Path.home() / ".local" / "share"))
    return (
        Path(os.environ.get("OPENCODE_AUTH_JSON") or (data_home / "opencode" / "auth.json")),
        Path(os.environ.get("OPENCODE_DB") or (data_home / "opencode" / "opencode.db")),
    )


def read_key() -> str | None:
    auth_path, _ = opencode_paths()
    try:
        data = json.loads(auth_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    entry = data.get(PROVIDER_ID_IN_DB)
    if not isinstance(entry, dict):
        return None
    key = entry.get("key")
    return key.strip() if isinstance(key, str) and key.strip() else None


def empty_stats() -> dict[str, Any]:
    return {
        "todayPrompts": 0,
        "todaySessions": 0,
        "todayTotalTokens": 0,
        "todayTokensByModel": {},
        "recentDays": [],
        "modelUsage": {},
        "totalPrompts": 0,
        "totalSessions": 0,
        "activeDays": 0,
        "activeDates": [],
    }


def recent_window(today: date) -> list[str]:
    return [(today - timedelta(days=offset)).isoformat() for offset in range(6, -1, -1)]


def collect_local_stats() -> dict[str, Any]:
    _, db_path = opencode_paths()
    if not db_path.is_file():
        return empty_stats()

    try:
        connection = sqlite3.connect(f"file:{db_path}?mode=ro&immutable=0", uri=True, timeout=2)
        try:
            placeholders = ",".join("?" * len(PROVIDER_IDS))
            rows = connection.execute(
                f"""
                SELECT
                    session_id,
                    time_created,
                    json_extract(data, '$.modelID') AS model,
                    COALESCE(json_extract(data, '$.tokens.input'), 0) AS input_tokens,
                    COALESCE(json_extract(data, '$.tokens.output'), 0) AS output_tokens,
                    COALESCE(json_extract(data, '$.tokens.cache.read'), 0) AS cache_read,
                    COALESCE(json_extract(data, '$.tokens.cache.write'), 0) AS cache_write
                FROM message
                WHERE json_extract(data, '$.providerID') IN ({placeholders})
                  AND json_extract(data, '$.tokens.total') IS NOT NULL
                """,
                PROVIDER_IDS,
            ).fetchall()
        finally:
            connection.close()
    except sqlite3.Error:
        # opencode holds the database open; a locked read means "try again
        # later", not a real absence of data, so it must not render as a
        # silent zero.
        return {**empty_stats(), "dbUnavailable": True}

    return stats_from_rows(rows)


def stats_from_rows(rows: list[tuple[Any, ...]]) -> dict[str, Any]:
    if not rows:
        return empty_stats()

    today = datetime.now(timezone.utc).date()
    today_str = today.isoformat()
    window = recent_window(today)
    window_totals = {day: 0 for day in window}
    model_usage: dict[str, dict[str, int]] = {}
    today_by_model: dict[str, dict[str, int]] = {}
    sessions: set[str] = set()
    today_sessions: set[str] = set()
    active_dates: set[str] = set()
    today_prompts = 0
    today_tokens = 0

    for session_id, time_created, model, input_tokens, output_tokens, cache_read, cache_write in rows:
        if time_created is None:
            continue
        model = model or "unknown"
        day = datetime.fromtimestamp(int(time_created) / 1000, tz=timezone.utc).date().isoformat()
        total = int(input_tokens) + int(output_tokens) + int(cache_read) + int(cache_write)

        sessions.add(session_id)
        active_dates.add(day)
        bucket = model_usage.setdefault(model, dict(_EMPTY_TOKEN_BUCKET))
        bucket["inputTokens"] += int(input_tokens)
        bucket["outputTokens"] += int(output_tokens)
        bucket["cacheReadInputTokens"] += int(cache_read)
        bucket["cacheCreationInputTokens"] += int(cache_write)

        if day in window_totals:
            window_totals[day] += total

        if day == today_str:
            today_prompts += 1
            today_sessions.add(session_id)
            today_tokens += total
            today_bucket = today_by_model.setdefault(model, dict(_EMPTY_TOKEN_BUCKET))
            today_bucket["inputTokens"] += int(input_tokens)
            today_bucket["outputTokens"] += int(output_tokens)
            today_bucket["cacheReadInputTokens"] += int(cache_read)
            today_bucket["cacheCreationInputTokens"] += int(cache_write)

    return {
        "todayPrompts": today_prompts,
        "todaySessions": len(today_sessions),
        "todayTotalTokens": today_tokens,
        "todayTokensByModel": today_by_model,
        "recentDays": [{"date": day, "messageCount": window_totals[day]} for day in window],
        "modelUsage": model_usage,
        "totalPrompts": len(rows),
        "totalSessions": len(sessions),
        "activeDays": len(active_dates),
        "activeDates": sorted(active_dates),
    }


def percent_value(window: dict[str, Any], field: str) -> float:
    try:
        value = float(window.get("percent"))
    except (TypeError, ValueError) as exc:
        raise ValueError(f"usage.{field}.percent is missing") from exc
    if value < 0 or value != value or value == float("inf"):
        raise ValueError(f"usage.{field}.percent is invalid")
    return min(1.0, value / 100.0)


def limit_window(usage: dict[str, Any], field: str, label: str) -> dict[str, Any]:
    window = usage.get(field)
    if not isinstance(window, dict):
        raise ValueError(f"usage.{field} is missing")
    return {
        "label": label,
        "title": label,
        "percent": percent_value(window, field),
        "resetsAt": window.get("resetsAt") or "",
    }


def collect_limits(key: str) -> dict[str, Any]:
    payload = request_json(USAGE_ENDPOINT, headers={"Authorization": f"Bearer {key}"})
    usage = payload.get("usage")
    if not isinstance(usage, dict):
        raise ValueError("OpenCode Go usage endpoint returned an unexpected response")

    limits = []
    for field, label in (
        ("rolling", "Session"),
        ("weekly", "Weekly"),
        ("monthly", "Monthly"),
    ):
        window = usage.get(field)
        if isinstance(window, dict):
            limits.append(limit_window(usage, field, label))
    return {"limits": limits}


def base_record() -> dict[str, Any]:
    return {
        "id": AGENT_ID,
        "name": AGENT_NAME,
        "schemaVersion": 1,
        "updatedAt": now_iso(),
        "hasLocalStats": True,
        "hasPromptStats": True,
        "limits": [],
    }


def collect() -> dict[str, Any]:
    record = base_record()
    stats = collect_local_stats()
    record.update(stats)
    record["ready"] = stats.get("totalPrompts", 0) > 0

    if stats.get("dbUnavailable"):
        record["usageStatusText"] = "Local database locked — retrying"
        record["authHelpText"] = (
            "OpenCode holds the database open; stats will refresh when the lock is released."
        )

    key = read_key()
    if key:
        record["tierLabel"] = "Go"
    if not key:
        return auth_missing(record, AUTH_HELP, status="Waiting for auth")

    try:
        limits = collect_limits(key)
    except HTTPError as exc:
        if exc.code in (401, 403):
            return endpoint_problem(
                record,
                "OpenCode Go sign-in expired",
                "Run `opencode auth login` to restore authoritative usage. Local stats are still shown.",
            )
        return classify_failure(record, "OpenCode Go", exc, AUTH_HELP)
    except Exception as exc:  # noqa: BLE001 - network/parse failures all map to the same visible state
        return classify_failure(record, "OpenCode Go", exc, AUTH_HELP)

    record.update(limits)
    record["ready"] = True
    return record


if __name__ == "__main__":
    print_record(collect())
