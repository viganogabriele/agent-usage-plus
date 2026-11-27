"""Decorate an existing Claude/Codex transcript collector with API pricing.

Omarchy already owns the mature transcript scanners. This companion keeps
that source of truth and only adds a derived ``cost`` block to its JSON; it
does not read credentials or make a network request.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any

from .daily_usage import take_daily_usage


def helper_path() -> Path | None:
    configured = os.environ.get("AGENT_USAGE_PLUS_COST_HELPER", "")
    candidates = [Path(configured)] if configured else []
    here = Path(__file__).resolve()
    # Installed layout: <data>/agent_usage_collectors + <data>/scripts.
    candidates.append(here.parents[1] / "scripts" / "calculate-api-cost")
    # Source layout: <repo>/collectors/agent_usage_collectors + <repo>/scripts.
    candidates.append(here.parents[2] / "scripts" / "calculate-api-cost")
    return next((candidate for candidate in candidates if candidate.is_file()), None)


def normalise_today_buckets(record: dict[str, Any]) -> None:
    """Upgrade old base collectors' scalar daily totals to the contract shape.

    Older Omarchy scanners only retain a per-model total for today. It cannot
    reconstruct a historic input/output/cache split, so preserve the total in
    ``inputTokens`` and make the unknown split explicit as zeroes. Newer
    bucket-shaped values pass through with every required key present.
    """
    raw = record.get("todayTokensByModel")
    if not isinstance(raw, dict):
        return
    def token_count(value: Any) -> int:
        """Coerce one legacy counter without letting bad telemetry kill usage.

        The base collector owns this optional, backwards-compatible field.
        It has emitted both scalars and partial bucket objects over time, so a
        malformed value must become a zero *for that field*, not turn the
        entire Claude/Codex wrapper into an "unavailable" status card.
        """
        try:
            return max(0, int(value or 0))
        except (TypeError, ValueError, OverflowError):
            return 0

    buckets: dict[str, dict[str, int]] = {}
    for model, value in raw.items():
        if isinstance(value, dict):
            buckets[str(model)] = {
                "inputTokens": token_count(value.get("inputTokens")),
                "outputTokens": token_count(value.get("outputTokens")),
                "cacheReadInputTokens": token_count(value.get("cacheReadInputTokens")),
                "cacheCreationInputTokens": token_count(value.get("cacheCreationInputTokens")),
            }
        else:
            buckets[str(model)] = {
                "inputTokens": token_count(value),
                "outputTokens": 0,
                "cacheReadInputTokens": 0,
                "cacheCreationInputTokens": 0,
            }
    record["todayTokensByModel"] = buckets


def decorate(record: dict[str, Any], provider: str, period: str) -> dict[str, Any]:
    """Add an API-rate estimate without disguising unpriced models.

    A transcript with priced models gets a clearly marked partial subtotal
    when another model lacks an official rate. An all-unknown transcript still
    omits the estimate rather than inventing $0.
    """
    normalise_today_buckets(record)
    # Internal hand-off from the compatibility readers: always taken off the
    # record (it is not part of the collector contract), and only used here.
    daily = take_daily_usage(record)
    helper = helper_path()
    if helper is None:
        return record
    payload = {
        "provider": provider,
        "period": period,
        "modelUsage": record.get("modelUsage") or {},
        "activeDays": record.get("activeDays", 0),
    }
    if daily:
        payload["dailyModelUsage"] = daily
    try:
        result = subprocess.run(
            [str(helper)], input=json.dumps(payload), text=True, capture_output=True,
            check=True, timeout=10,
        )
        calculated = json.loads(result.stdout)
        cost = calculated.get("cost") if isinstance(calculated, dict) else None
        if isinstance(cost, dict):
            record["cost"] = cost
    except (OSError, subprocess.SubprocessError, ValueError, json.JSONDecodeError):
        # A cost estimate is additive: never hide the base collector's usage
        # record merely because the optional local bridge was unavailable.
        pass
    return record
