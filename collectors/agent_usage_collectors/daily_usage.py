"""Keep Omarchy's per-day, per-model token buckets for the cost chart.

Omarchy's shared scanner (``collectors.Stats``) sees every reply with its day
and model, but its snapshot keeps only lifetime per-model buckets and one
combined token count per day. Pricing a day needs the per-model split, so
this module, installed by the Claude and Codex compatibility readers before
they run Omarchy's collector, swaps in a ``Stats`` subclass whose snapshot
also carries ``dailyModelUsage``: ``{ "YYYY-MM-DD": { model: TokenBucket } }``
for the last ``DAILY_WINDOW_DAYS`` local days.

The field is consumed (and removed) by ``transcript_cost.decorate``, which
turns it into ``cost.byDay``. Nothing here reads credentials, transcripts or
the network: it only keeps more of what Omarchy's own scan already counts.

Omarchy caches a scan's snapshot for a few minutes. A cache written by a run
without this hook has no ``dailyModelUsage``, so the hook also adds a key to
the scan's ``match`` options: such a cache is then a miss for these readers
and the (index-backed, incremental) scan runs once more. Omarchy's own runs
ignore the extra key and keep reusing either cache.

Any upstream shape this doesn't recognise leaves Omarchy's module untouched:
the record then simply has no daily breakdown, never a failed collector.
"""

from __future__ import annotations

import os
import sys
from datetime import date, timedelta
from pathlib import Path
from typing import Any

DAILY_WINDOW_DAYS = 31
# Bounds what one record can carry, whatever a transcript claims.
MAX_MODELS_PER_DAY = 64
MATCH_KEY = "agentUsagePlusDaily"
MATCH_VALUE = 1
BUCKET_KEYS = ("inputTokens", "outputTokens", "cacheReadInputTokens", "cacheCreationInputTokens")


def omarchy_agents_dir() -> Path:
    return Path(os.environ.get("OMARCHY_PATH") or "/usr/share/omarchy") / "shell" / "plugins" / "agents"


def load_collectors_module() -> Any:
    """Omarchy's shared ``collectors`` module, imported the way its collectors do."""
    module = sys.modules.get("collectors")
    if module is not None:
        return module
    path = str(omarchy_agents_dir())
    if path not in sys.path:
        sys.path.insert(0, path)
    previous = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        import collectors  # type: ignore[import-not-found]  # noqa: PLC0415
    finally:
        sys.dont_write_bytecode = previous
    return collectors


def _count(value: Any) -> int:
    try:
        return max(0, int(value or 0))
    except (TypeError, ValueError, OverflowError):
        return 0


def daily_stats_class(base: type) -> type:
    """A ``base`` (Omarchy's Stats) subclass that also keeps day x model buckets."""

    class DailyStats(base):  # type: ignore[misc, valid-type]
        def __init__(self, *args: Any, **kwargs: Any) -> None:
            super().__init__(*args, **kwargs)
            self._agent_usage_plus_daily: dict[str, dict[str, dict[str, int]]] = {}
            try:
                newest = date.fromisoformat(str(self.today))
            except (AttributeError, TypeError, ValueError):
                newest = date.today()
            oldest = newest - timedelta(days=DAILY_WINDOW_DAYS - 1)
            self._agent_usage_plus_window = (oldest.isoformat(), newest.isoformat())

        def add(self, day: Any, session: Any, model: Any, input_tokens: Any, output_tokens: Any,
                cache_read: Any, cache_write: Any, *args: Any, **kwargs: Any) -> Any:
            result = super().add(day, session, model, input_tokens, output_tokens, cache_read, cache_write, *args, **kwargs)
            try:
                self._agent_usage_plus_keep(day, model, input_tokens, output_tokens, cache_read, cache_write)
            except Exception:  # noqa: BLE001 - the breakdown is optional
                pass
            return result

        def _agent_usage_plus_keep(self, day: Any, model: Any, *tokens: Any) -> None:
            if not isinstance(day, str):
                return
            oldest, newest = self._agent_usage_plus_window
            if not (oldest <= day <= newest):
                return
            counts = [_count(value) for value in tokens]
            if sum(counts) <= 0:
                return
            models = self._agent_usage_plus_daily.setdefault(day, {})
            name = str(model)
            if name not in models and len(models) >= MAX_MODELS_PER_DAY:
                return
            bucket = models.setdefault(name, {key: 0 for key in BUCKET_KEYS})
            for key, value in zip(BUCKET_KEYS, counts):
                bucket[key] += value

        def snapshot(self, *args: Any, **kwargs: Any) -> Any:
            snapshot = super().snapshot(*args, **kwargs)
            if isinstance(snapshot, dict):
                snapshot["dailyModelUsage"] = {
                    day: {model: dict(bucket) for model, bucket in models.items()}
                    for day, models in sorted(self._agent_usage_plus_daily.items())
                }
            return snapshot

    DailyStats.__name__ = DailyStats.__qualname__ = getattr(base, "__name__", "Stats")
    DailyStats.__doc__ = getattr(base, "__doc__", None)
    DailyStats._agent_usage_plus_daily_hook = True  # type: ignore[attr-defined]
    return DailyStats


def wrap_cached_scan(original: Any) -> Any:
    def cached_scan(*args: Any, **kwargs: Any) -> Any:
        if "match" in kwargs:
            match = dict(kwargs.get("match") or {})
            match[MATCH_KEY] = MATCH_VALUE
            kwargs["match"] = match
        elif len(args) >= 5:
            match = dict(args[4] or {})
            match[MATCH_KEY] = MATCH_VALUE
            args = (*args[:4], match, *args[5:])
        else:
            kwargs["match"] = {MATCH_KEY: MATCH_VALUE}
        return original(*args, **kwargs)

    cached_scan._agent_usage_plus_daily_hook = True  # type: ignore[attr-defined]
    cached_scan.__doc__ = getattr(original, "__doc__", None)
    return cached_scan


def install(module: Any | None = None) -> bool:
    """Patch Omarchy's ``collectors`` module in place; True when installed.

    Must run before the collector script executes its ``from collectors
    import ...``, which then picks up the patched names.
    """
    try:
        target = module if module is not None else load_collectors_module()
        stats = getattr(target, "Stats", None)
        scan = getattr(target, "cached_scan", None)
        if not isinstance(stats, type) or not callable(scan):
            return False
        for name in ("add", "snapshot"):
            if not callable(getattr(stats, name, None)):
                return False
        if not getattr(stats, "_agent_usage_plus_daily_hook", False):
            target.Stats = daily_stats_class(stats)
        if not getattr(scan, "_agent_usage_plus_daily_hook", False):
            target.cached_scan = wrap_cached_scan(scan)
        return True
    except Exception:  # noqa: BLE001 - never stop the base collector
        return False


def take_daily_usage(record: dict[str, Any]) -> dict[str, dict[str, dict[str, int]]]:
    """Remove ``dailyModelUsage`` from ``record`` and return a bounded copy."""
    raw = record.pop("dailyModelUsage", None)
    if not isinstance(raw, dict):
        return {}
    def iso_day(key: Any) -> bool:
        try:
            return isinstance(key, str) and date.fromisoformat(key).isoformat() == key
        except ValueError:
            return False

    days: dict[str, dict[str, dict[str, int]]] = {}
    for day in sorted((key for key in raw if iso_day(key)), reverse=True)[:DAILY_WINDOW_DAYS]:
        models = raw.get(day)
        if not isinstance(models, dict):
            continue
        kept: dict[str, dict[str, int]] = {}
        for model, bucket in list(models.items())[:MAX_MODELS_PER_DAY]:
            if not isinstance(bucket, dict):
                continue
            counts = {key: _count(bucket.get(key)) for key in BUCKET_KEYS}
            if sum(counts.values()) > 0:
                kept[str(model)] = counts
        if kept:
            days[day] = kept
    return dict(sorted(days.items()))
