"""Per-day, per-model buckets kept from Omarchy's scan for the cost chart."""
from __future__ import annotations

import os
import sys
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from agent_usage_collectors import daily_usage  # noqa: E402
from agent_usage_collectors.transcript_cost import decorate  # noqa: E402

OMARCHY_AGENTS = Path(os.environ.get("OMARCHY_PATH") or "/usr/share/omarchy") / "shell/plugins/agents/collectors.py"


class FakeStats:
    """The shape of Omarchy's collectors.Stats this hook relies on."""

    def __init__(self, today=None):
        self.today = today or "2026-11-27"
        self.model_usage = {}

    def add(self, day, session, model, input_tokens, output_tokens, cache_read, cache_write, prompts=1):
        bucket = self.model_usage.setdefault(model, [0, 0, 0, 0])
        for index, value in enumerate((input_tokens, output_tokens, cache_read, cache_write)):
            bucket[index] += value

    def snapshot(self):
        return {"modelUsage": self.model_usage}


def fake_module():
    module = types.ModuleType("collectors")
    module.Stats = FakeStats
    module.calls = []

    def cached_scan(agent_id, sources, max_age, scan, match=None, with_complete=False):
        module.calls.append(match)
        return scan()[0]

    module.cached_scan = cached_scan
    return module


class DailyStatsTests(unittest.TestCase):
    def test_snapshot_keeps_day_by_model_buckets_within_the_window(self):
        module = fake_module()
        self.assertTrue(daily_usage.install(module))
        stats = module.Stats("2026-11-27")
        stats.add("2026-11-27", "s", "opus", 1, 2, 3, 4)
        stats.add("2026-11-27", "s", "opus", 10, 0, 0, 0, prompts=0)
        stats.add("2026-11-26", "s", "sonnet", 0, 5, 0, 0)
        stats.add("2026-10-27", "s", "opus", 9, 9, 9, 9)  # day 32: outside
        stats.add(None, "s", "opus", 9, 9, 9, 9)
        stats.add("2026-11-25", "s", "opus", 0, 0, 0, 0)
        snapshot = stats.snapshot()

        self.assertEqual(snapshot["modelUsage"]["opus"], [29, 20, 21, 22])  # base totals untouched
        self.assertEqual(snapshot["dailyModelUsage"], {
            "2026-11-26": {"sonnet": {"inputTokens": 0, "outputTokens": 5, "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0}},
            "2026-11-27": {"opus": {"inputTokens": 11, "outputTokens": 2, "cacheReadInputTokens": 3, "cacheCreationInputTokens": 4}},
        })

    def test_scan_cache_match_gains_a_key_so_caches_without_days_miss(self):
        module = fake_module()
        daily_usage.install(module)
        module.cached_scan("claude", [], 60, lambda: ({}, True), match={"base": "x"})
        module.cached_scan("codex", [], 60, lambda: ({}, True))
        self.assertEqual(module.calls, [{"base": "x", daily_usage.MATCH_KEY: daily_usage.MATCH_VALUE},
                                        {daily_usage.MATCH_KEY: daily_usage.MATCH_VALUE}])

    def test_install_is_idempotent_and_refuses_unknown_shapes(self):
        module = fake_module()
        daily_usage.install(module)
        patched = module.Stats
        daily_usage.install(module)
        self.assertIs(module.Stats, patched)
        self.assertFalse(daily_usage.install(types.ModuleType("collectors")))
        odd = fake_module()
        odd.Stats = "not a class"
        self.assertFalse(daily_usage.install(odd))
        self.assertEqual(odd.Stats, "not a class")

    @unittest.skipUnless(OMARCHY_AGENTS.is_file(), "Omarchy's shared collectors module is not installed")
    def test_hooks_the_real_omarchy_stats(self):
        loader_path = str(OMARCHY_AGENTS.parent)
        sys.path.insert(0, loader_path)
        try:
            import importlib.util
            spec = importlib.util.spec_from_file_location("omarchy_collectors_probe", OMARCHY_AGENTS)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
        finally:
            sys.path.remove(loader_path)
        self.assertTrue(daily_usage.install(module))
        stats = module.Stats()
        stats.add(stats.today, "s", "claude-opus-5-5", 1, 2, 3, 4)
        snapshot = stats.snapshot()
        self.assertEqual(snapshot["dailyModelUsage"][stats.today]["claude-opus-5-5"]["cacheCreationInputTokens"], 4)
        self.assertIn("modelUsage", snapshot)


class TakeDailyUsageTests(unittest.TestCase):
    def test_is_removed_from_the_record_and_bounded(self):
        raw = {f"2026-10-{day:02d}": {"m": {"inputTokens": 1}} for day in range(1, 32)}
        raw.update({"2026-11-01": {"m": {"inputTokens": "bad", "outputTokens": -3}}, "not-a-day": {"m": {"inputTokens": 1}},
                    "2026-11-02": "x", "2026-11-03": {"m": {"inputTokens": 2}, "z": "x"}})
        record = {"dailyModelUsage": raw}
        days = daily_usage.take_daily_usage(record)
        self.assertNotIn("dailyModelUsage", record)
        # The 31 newest real days (11-03 back to 10-04), minus the all-zero
        # 11-01 and the malformed 11-02; "not-a-day" never takes a slot.
        self.assertEqual(len(days), 29)
        self.assertEqual(min(days), "2026-10-04")
        self.assertEqual(days["2026-11-03"], {"m": {"inputTokens": 2, "outputTokens": 0, "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0}})
        self.assertEqual(daily_usage.take_daily_usage({"dailyModelUsage": []}), {})


class DecorateTests(unittest.TestCase):
    def test_decorate_turns_daily_buckets_into_by_day_and_drops_the_hand_off(self):
        bucket = {"inputTokens": 1_000_000, "outputTokens": 0, "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0}
        record = decorate({
            "modelUsage": {"claude-opus-5-5": {**bucket, "inputTokens": 2_000_000}},
            "dailyModelUsage": {"2026-11-26": {"claude-opus-5-5": bucket}, "2026-11-27": {"claude-opus-5-5": bucket}},
            "activeDays": 2,
        }, "claude", "All time")
        self.assertNotIn("dailyModelUsage", record)
        self.assertEqual(record["cost"]["estimateUsd"], 8)
        self.assertEqual(record["cost"]["byDay"], [{"date": "2026-11-26", "usd": 4}, {"date": "2026-11-27", "usd": 4}])

    def test_decorate_without_daily_buckets_keeps_the_aggregate_estimate(self):
        record = decorate({"modelUsage": {"claude-opus-5-5": {"inputTokens": 1_000_000}}, "activeDays": 1}, "claude", "All time")
        self.assertEqual(record["cost"]["byDay"], [])
        self.assertEqual(record["cost"]["estimateUsd"], 4)


class CompatWiringTests(unittest.TestCase):
    def test_codex_compat_skips_the_hook_for_a_standalone_scanner(self):
        script = Path(__file__).resolve().parents[1] / "bin/omarchy-agent-usage-codex-compat"
        source = script.read_text(encoding="utf-8")
        self.assertIn('if "from collectors import" in replacement:', source)

    def test_claude_compat_installs_the_hook_before_running_the_base(self):
        script = Path(__file__).resolve().parents[1] / "bin/omarchy-agent-usage-claude-compat"
        source = script.read_text(encoding="utf-8")
        self.assertLess(source.index("install_daily_usage()\n        sys.argv[0]"), source.index("exec(code, namespace)"))


if __name__ == "__main__":
    unittest.main()
