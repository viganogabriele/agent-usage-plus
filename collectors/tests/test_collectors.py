from __future__ import annotations

from datetime import datetime
import json
import os
import shutil
import sqlite3
import sys
from importlib.machinery import SourceFileLoader
import tempfile
import types
import unittest
from pathlib import Path
from urllib.error import HTTPError, URLError
from unittest.mock import patch

from agent_usage_collectors import (
    agy,
    cursor,
    deepseek,
    devin,
    gemini,
    kimi,
    opencode_go,
    openrouter,
    xai,
)
from agent_usage_collectors.common import MAX_RESPONSE_BYTES, base_record, classify_failure, endpoint_problem, request_json
from agent_usage_collectors.deepseek import record_from_payload as deepseek_record
from agent_usage_collectors.devin import collect as collect_devin
from agent_usage_collectors.devin import empty_stats as empty_devin_stats
from agent_usage_collectors.devin import parse_plan_status as devin_plan_status
from agent_usage_collectors.devin import read_credentials as read_devin_credentials
from agent_usage_collectors.devin import stats_from_rows as devin_stats_from_rows
from agent_usage_collectors.cursor import record_from_payload as cursor_record
from agent_usage_collectors.gemini import record_from_payload as gemini_record
from agent_usage_collectors.kimi import record_from_payload as kimi_record
from agent_usage_collectors.opencode_go import collect as collect_opencode_go
from agent_usage_collectors.opencode_go import limit_window as opencode_go_limit_window
from agent_usage_collectors.opencode_go import stats_from_rows as opencode_go_stats_from_rows
from agent_usage_collectors.openrouter import record_from_payload as openrouter_record
from agent_usage_collectors.transcript_cost import decorate, normalise_today_buckets
from agent_usage_collectors.xai import record_from_payload as xai_record
from agent_usage_collectors.xai import team_id_from_validation
from agent_usage_collectors.zai import collect as collect_zai
from agent_usage_collectors.zai import record_from_payload as zai_record


class CollectorParsingTests(unittest.TestCase):
    def test_request_json_bounds_provider_response_reads(self) -> None:
        class Response:
            def __init__(self, body: bytes) -> None:
                self.body = body
                self.read_limit: int | None = None

            def __enter__(self) -> "Response":
                return self

            def __exit__(self, *_args: object) -> None:
                return None

            def read(self, limit: int = -1) -> bytes:
                self.read_limit = limit
                return self.body

        response = Response(b"{}")
        with patch("agent_usage_collectors.common.urlopen", return_value=response):
            self.assertEqual(request_json("https://provider.example/usage"), {})
        self.assertEqual(response.read_limit, MAX_RESPONSE_BYTES + 1)

        oversized = Response(b"{" + b"x" * MAX_RESPONSE_BYTES + b"}")
        with patch("agent_usage_collectors.common.urlopen", return_value=oversized):
            with self.assertRaisesRegex(ValueError, "too large"):
                request_json("https://provider.example/usage")

    def test_every_companion_collector_reports_missing_auth_without_network(self) -> None:
        with (
            patch.object(openrouter, "find_key", return_value=None),
            patch.object(deepseek, "find_key", return_value=None),
            patch.object(kimi, "find_key", return_value=None),
            patch.object(xai, "find_key", return_value=None),
            patch.object(gemini, "read_access_token", return_value=None),
            patch.object(cursor, "read_token", return_value=None),
            patch.object(devin, "read_credentials", return_value=None),
            patch.object(
                devin,
                "collect_local_stats",
                return_value=(empty_devin_stats(), False, ""),
            ),
            patch.object(shutil, "which", return_value=None),
            patch.object(agy, "fetch_local_stats", return_value=False),
            patch("agent_usage_collectors.zai.find_any_key", return_value=None),
            tempfile.TemporaryDirectory() as empty_state_dir,
            patch("agent_usage_collectors.common.usage_dir", return_value=Path(empty_state_dir)),
        ):
            records = [
                openrouter.collect(),
                deepseek.collect(),
                kimi.collect(),
                xai.collect(),
                gemini.collect(),
                cursor.collect(),
                collect_devin(),
                collect_zai(),
                agy.collect(),
            ]
        self.assertTrue(all(record.get("ready") is False for record in records))
        self.assertEqual(records[0]["usageStatusText"], "Waiting for API key")
        self.assertEqual(records[3]["usageStatusText"], "Waiting for API key")
        self.assertEqual(records[4]["usageStatusText"], "Waiting for Gemini sign-in")
        self.assertEqual(records[5]["usageStatusText"], "Waiting for Cursor sign-in")
        self.assertEqual(records[6]["usageStatusText"], "Waiting for Devin sign-in")
        self.assertEqual(records[7]["usageStatusText"], "Waiting for Z.AI API key")
        self.assertEqual(records[8]["usageStatusText"], "Waiting for agy")

    def test_openrouter_budget_maps_to_balance(self) -> None:
        record = openrouter_record({"data": {"limit": 25, "limit_remaining": 17.5, "usage": 7.5, "limit_reset": "monthly"}})
        self.assertTrue(record["ready"])
        self.assertEqual(record["balance"], {"remaining": 17.5, "funded": 25.0, "spent": 7.5, "currency": "USD"})
        self.assertIn("monthly", record["tierLabel"])

    def test_openrouter_without_key_limit_is_not_an_error(self) -> None:
        record = openrouter_record({"data": {"usage": 4.25, "limit": None}})
        self.assertTrue(record["ready"])
        self.assertNotIn("balance", record)
        self.assertNotIn("usageStatusText", record)

    def test_deepseek_prefers_usd_ledger(self) -> None:
        record = deepseek_record({"is_available": True, "balance_infos": [{"currency": "CNY", "total_balance": "100"}, {"currency": "USD", "total_balance": "3.20"}]})
        self.assertEqual(record["balance"], {"remaining": 3.2, "currency": "USD"})
        self.assertTrue(record["ready"])

    def test_xai_prepaid_credit_is_converted_from_signed_cents(self) -> None:
        record = xai_record({"total": {"val": "-1234"}})
        self.assertEqual(record["balance"], {"remaining": 12.34, "currency": "USD"})
        self.assertTrue(record["ready"])

    def test_xai_finds_team_from_legacy_or_team_scope_validation(self) -> None:
        self.assertEqual(team_id_from_validation({"teamId": "legacy-team"}, None), "legacy-team")
        self.assertEqual(team_id_from_validation({"scope": "SCOPE_TEAM", "scopeId": "scoped-team"}, None), "scoped-team")
        self.assertIsNone(team_id_from_validation({"scope": "SCOPE_ORGANIZATION", "scopeId": "org"}, None))

    @patch("agent_usage_collectors.zai.find_any_key", return_value=None)
    def test_zai_missing_key_is_a_clear_state(self, _key: object) -> None:
        record = collect_zai()
        self.assertEqual(record["usageStatusText"], "Waiting for Z.AI API key")
        self.assertNotIn("balance", record)

    def test_zai_maps_coding_plan_windows(self) -> None:
        record = zai_record({
            "success": True,
            "code": 200,
            "data": {
                "planName": "GLM Pro",
                "limits": [
                    {"type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 20, "remaining": 800, "usage": 1000, "nextResetTime": 1787529600000},
                    {"type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 40},
                    {"type": "TIME_LIMIT", "unit": 5, "number": 1, "percentage": 5},
                ],
            },
        })
        self.assertTrue(record["ready"])
        self.assertEqual(record["tierLabel"], "GLM Pro")
        self.assertEqual([limit["title"] for limit in record["limits"]], ["5-hour", "MCP", "Weekly"])
        self.assertEqual(record["limits"][0]["percent"], 0.2)
        self.assertEqual(record["limits"][0]["resetsAt"], "2026-08-24T00:00:00Z")

    @patch("agent_usage_collectors.zai.setting", return_value=None)
    @patch("agent_usage_collectors.zai.request_json")
    @patch("agent_usage_collectors.zai.find_any_key", return_value="zai-test-key")
    def test_zai_collects_personal_quota(self, _key: object, get_json: object, _setting: object) -> None:
        get_json.return_value = {"success": True, "code": 200, "data": {"limits": [{"type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 12}]}}
        record = collect_zai()
        self.assertTrue(record["ready"])
        self.assertEqual(get_json.call_args.args[0], "https://api.z.ai/api/monitor/usage/quota/limit")

    @patch.dict("os.environ", {"Z_AI_QUOTA_ENDPOINT": "https://evil.z.ai/api/monitor/usage/quota/limit"})
    @patch("agent_usage_collectors.zai.request_json")
    @patch("agent_usage_collectors.zai.find_any_key", return_value="zai-test-key")
    def test_zai_rejects_unlisted_quota_override_without_sending_key(self, _key: object, get_json: object) -> None:
        record = collect_zai()
        self.assertEqual(record["usageStatusText"], "Z.AI quota endpoint is invalid")
        get_json.assert_not_called()

    @patch("agent_usage_collectors.zai.setting", side_effect=lambda env, config: {"Z_AI_USAGE_SCOPE": "team", "Z_AI_ORGANIZATION": "org-1", "Z_AI_PROJECT": "project-1"}.get(env))
    @patch("agent_usage_collectors.zai.request_json")
    @patch("agent_usage_collectors.zai.find_any_key", return_value="zai-test-key")
    def test_zai_team_quota_adds_scope_headers_and_query(self, _key: object, get_json: object, _setting: object) -> None:
        get_json.return_value = {"success": True, "code": 200, "data": {"limits": [{"type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 3}]}}
        record = collect_zai()
        self.assertTrue(record["ready"])
        self.assertIn("type=2", get_json.call_args.args[0])
        self.assertEqual(get_json.call_args.kwargs["headers"]["Bigmodel-Organization"], "org-1")
        self.assertEqual(get_json.call_args.kwargs["headers"]["Bigmodel-Project"], "project-1")

    @patch("agent_usage_collectors.zai.setting", side_effect=lambda env, config: "team" if env == "Z_AI_USAGE_SCOPE" else None)
    @patch("agent_usage_collectors.zai.find_any_key", return_value="zai-test-key")
    def test_zai_team_scope_requires_selectors(self, _key: object, _setting: object) -> None:
        record = collect_zai()
        self.assertEqual(record["usageStatusText"], "Z.AI team details required")
        self.assertIn("organization", record["authHelpText"])

    @patch("agent_usage_collectors.xai.get_json")
    @patch("agent_usage_collectors.xai.find_setting", return_value=None)
    @patch("agent_usage_collectors.xai.find_key", return_value="management-secret")
    def test_xai_collects_validated_team_prepaid_credit(self, _key: object, _team: object, get_json: object) -> None:
        get_json.side_effect = [
            {"scope": "SCOPE_TEAM", "scopeId": "team-1"},
            {"total": {"val": "-500"}},
        ]
        from agent_usage_collectors.xai import collect as collect_xai
        record = collect_xai()
        self.assertEqual(record["balance"], {"remaining": 5.0, "currency": "USD"})
        self.assertEqual(get_json.call_count, 2)

    @patch("agent_usage_collectors.xai.get_json")
    @patch("agent_usage_collectors.xai.find_key", return_value="management-secret")
    def test_xai_rejected_management_key_is_explicit(self, _key: object, get_json: object) -> None:
        get_json.side_effect = HTTPError("https://x", 403, "no", {}, None)
        from agent_usage_collectors.xai import collect as collect_xai
        record = collect_xai()
        self.assertEqual(record["usageStatusText"], "Management key rejected")

    def test_kimi_maps_weekly_and_rolling_windows(self) -> None:
        record = kimi_record({
            "user": {"membership": {"level": "LEVEL_INTERMEDIATE"}},
            "usage": {"limit": "100", "remaining": "74", "resetTime": "2026-08-25T17:32:50Z"},
            "limits": [{
                "window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
                "detail": {"limit": 100, "used": 15, "resetTime": "2026-08-23T12:32:50Z"},
            }],
        })
        self.assertEqual(record["tierLabel"], "Intermediate")
        self.assertEqual(record["limits"][0]["title"], "Session")
        self.assertEqual(record["limits"][0]["percent"], 0.15)
        self.assertEqual(record["limits"][1]["percent"], 0.26)

    def test_gemini_maps_current_cli_bucket_shape(self) -> None:
        record = gemini_record(
            {"currentTier": {"name": "Google AI Pro"}},
            {"buckets": [
                {"modelId": "gemini-3-pro", "remainingFraction": 0.4, "resetTime": "2026-08-24T00:00:00Z"},
                {"modelId": "gemini-3-flash", "remainingFraction": 0.9},
            ]},
        )
        self.assertEqual(record["tierLabel"], "Google AI Pro")
        self.assertEqual(record["limits"][0]["title"], "Pro")
        self.assertEqual(record["limits"][0]["percent"], 0.6)
        self.assertEqual(record["limits"][1]["title"], "Flash")

    def test_cursor_maps_dashboard_subscription_pools(self) -> None:
        record = cursor_record({
            "membershipType": "ultra",
            "billingCycleEnd": "2026-09-01T00:00:00Z",
            "isUnlimited": False,
            "individualUsage": {"plan": {"autoPercentUsed": 98.1, "apiPercentUsed": 100, "totalPercentUsed": 98.5}},
        })
        self.assertEqual(record["tierLabel"], "Ultra")
        self.assertEqual([limit["title"] for limit in record["limits"]], ["Cursor Models", "Other Models", "Included total"])
        self.assertEqual(record["limits"][0]["percent"], 0.981)

    def test_cursor_unlimited_is_a_real_ready_state_without_fake_meter(self) -> None:
        record = cursor_record({"membershipType": "business", "billingCycleEnd": "2026-09-01T00:00:00Z", "isUnlimited": True})
        self.assertTrue(record["ready"])
        self.assertEqual(record["limits"], [])
        self.assertIn("unlimited", record["tierLabel"])

    def test_auth_and_transport_states_have_correct_retry_behavior(self) -> None:
        error = HTTPError("https://x", 401, "no", {}, None)
        rejected = classify_failure(base_record("x", "X", "X"), "X", error, "Fix auth")
        error.close()
        network = classify_failure(base_record("x", "X", "X"), "X", URLError("offline"), "Fix auth")
        self.assertEqual(rejected["usageStatusText"], "API key rejected")
        self.assertNotIn("retryAdvised", rejected)
        self.assertTrue(network["retryAdvised"])

    def test_endpoint_problem_carries_forward_last_known_good_reading(self) -> None:
        with tempfile.TemporaryDirectory() as state_home:
            usage_dir = Path(state_home) / "omarchy" / "agents" / "usage"
            usage_dir.mkdir(parents=True)
            (usage_dir / "x.json").write_text(json.dumps({
                "id": "x",
                "updatedAt": "2026-08-24T00:00:00Z",
                "limits": [{"label": "Session", "percent": 42}],
            }), encoding="utf-8")
            with patch.dict("os.environ", {"XDG_STATE_HOME": state_home}):
                error = HTTPError("https://x", 429, "rate limited", {}, None)
                record = classify_failure(base_record("x", "X", "X"), "X", error, "Fix auth")
                error.close()
        self.assertEqual(record["limits"], [{"label": "Session", "percent": 42}])
        self.assertEqual(record["updatedAt"], "2026-08-24T00:00:00Z")
        self.assertEqual(record["usageStatusText"], "X usage unavailable")

    def test_endpoint_problem_without_a_prior_reading_stays_empty(self) -> None:
        with tempfile.TemporaryDirectory() as state_home:
            with patch.dict("os.environ", {"XDG_STATE_HOME": state_home}):
                record = endpoint_problem(base_record("x", "X", "X"), "X down", "help")
        self.assertEqual(record["limits"], [])
        self.assertNotIn("balance", record)

    def test_transcript_cost_decorator_uses_complete_known_model_pricing(self) -> None:
        record = decorate({
            "id": "claude",
            "activeDays": 4,
            "modelUsage": {
                "claude-sonnet-5": {
                    "inputTokens": 1_000_000,
                    "outputTokens": 1_000_000,
                    "cacheReadInputTokens": 1_000_000,
                    "cacheCreationInputTokens": 1_000_000,
                },
            },
        }, "claude", "Local transcript history")
        self.assertEqual(record["cost"]["estimateUsd"], 14.7)
        self.assertEqual(record["cost"]["activeDays"], 4)

    def test_transcript_cost_decorator_labels_a_partial_unknown_model_total(self) -> None:
        record = decorate({
            "id": "codex",
            "modelUsage": {
                "gpt-5.6-sol": {"inputTokens": 1},
                "unpriced-model": {"outputTokens": 1},
            },
        }, "codex", "Local transcript history")
        self.assertTrue(record["cost"]["incomplete"])
        self.assertEqual(record["cost"]["unknownModels"], ["unpriced-model"])

    def test_transcript_cost_decorator_upgrades_old_daily_scalar_totals(self) -> None:
        record = {"todayTokensByModel": {"model": 42}}
        normalise_today_buckets(record)
        self.assertEqual(record["todayTokensByModel"]["model"], {
            "inputTokens": 42,
            "outputTokens": 0,
            "cacheReadInputTokens": 0,
            "cacheCreationInputTokens": 0,
        })

    def test_transcript_cost_decorator_keeps_the_base_record_on_bad_legacy_buckets(self) -> None:
        record = {"todayTokensByModel": {
            "scalar": float("inf"),
            "partial": {"inputTokens": "not-a-number", "outputTokens": 42},
        }}
        normalise_today_buckets(record)
        self.assertEqual(record["todayTokensByModel"], {
            "scalar": {
                "inputTokens": 0,
                "outputTokens": 0,
                "cacheReadInputTokens": 0,
                "cacheCreationInputTokens": 0,
            },
            "partial": {
                "inputTokens": 0,
                "outputTokens": 42,
                "cacheReadInputTokens": 0,
                "cacheCreationInputTokens": 0,
            },
        })


class DevinCollectorTests(unittest.TestCase):
    def test_bundled_runner_uses_updater_style_filters(self) -> None:
        path = Path(__file__).parents[1] / "bin" / "agent-usage-plus-collectors"
        runner = types.ModuleType("agent_usage_plus_runner")
        runner.__file__ = str(path)
        SourceFileLoader(runner.__name__, str(path)).exec_module(runner)
        self.assertEqual(runner.selected_providers(["update", "claude", "devin"]), ["devin"])
        self.assertEqual(runner.selected_providers(["update", "claude", "agy"]), ["agy"])
        self.assertEqual(
            runner.selected_providers(["update", "--force", "--except", "kimi", "devin"]),
            ["devin"],
        )
        self.assertNotIn(
            "devin",
            runner.selected_providers(["update", "--except", "devin"]),
        )
        self.assertNotIn(
            "agy",
            runner.selected_providers(["update", "--except", "agy"]),
        )

    def test_stats_from_rows_uses_canonical_token_buckets(self) -> None:
        today_ms = int(_local_midday_ms(days_ago=0))
        yesterday_ms = int(_local_midday_ms(days_ago=1))
        rows = [
            (
                "session-1", "claude-sonnet-5", None, today_ms,
                100, None, 50, None, 10, None, 5,
            ),
            (
                "session-1", "claude-sonnet-5", None, today_ms,
                20, None, 5, None, 0, None, 0,
            ),
            (
                "session-2", "gpt-5", "gpt-5.6", yesterday_ms,
                None, 200, None, 100, None, 40, 0,
            ),
        ]
        stats = devin_stats_from_rows(rows)
        self.assertEqual(stats["todayPrompts"], 2)
        self.assertEqual(stats["todaySessions"], 1)
        self.assertEqual(stats["todayTotalTokens"], 190)
        self.assertEqual(stats["totalPrompts"], 3)
        self.assertEqual(stats["totalSessions"], 2)
        self.assertEqual(
            stats["todayTokensByModel"]["claude-sonnet-5"],
            {
                "inputTokens": 120,
                "outputTokens": 55,
                "cacheReadInputTokens": 10,
                "cacheCreationInputTokens": 5,
            },
        )
        self.assertIn("gpt-5.6", stats["modelUsage"])

    def test_stats_from_rows_bounds_untrusted_model_ids(self) -> None:
        today_ms = int(_local_midday_ms(days_ago=0))
        rows = [
            (f"session-{index}", f"model-{index}", None, today_ms, 1, None, 0, None, 0, None, 0)
            for index in range(110)
        ]
        stats = devin_stats_from_rows(rows)
        self.assertEqual(len(stats["modelUsage"]), devin.MAX_MODEL_IDS)
        self.assertIn("other", stats["modelUsage"])

    def test_plan_status_maps_daily_weekly_and_overage_balance(self) -> None:
        parsed = devin_plan_status(
            {
                "userStatus": {
                    "planStatus": {
                        "planInfo": {"planName": "Pro"},
                        "dailyQuotaRemainingPercent": 46,
                        "weeklyQuotaRemainingPercent": 17,
                        "dailyQuotaResetAtUnix": 1788403200,
                        "weeklyQuotaResetAtUnix": 1788662400,
                        "overageBalanceMicros": 2_500_000,
                    }
                }
            }
        )
        self.assertEqual(parsed["tier"], "Pro")
        self.assertEqual([limit["title"] for limit in parsed["limits"]], ["Daily", "Weekly"])
        self.assertEqual(parsed["limits"][0]["percent"], 0.54)
        self.assertEqual(parsed["limits"][1]["percent"], 0.83)
        self.assertTrue(parsed["limits"][0]["resetsAt"].endswith("Z"))
        self.assertEqual(
            parsed["balance"],
            {"remaining": 2.5, "currency": "USD", "estimated": False},
        )

    def test_hidden_daily_quota_falls_back_to_weekly_window(self) -> None:
        parsed = devin_plan_status(
            {
                "userStatus": {
                    "planStatus": {
                        "planInfo": {"hideDailyQuota": True},
                        "dailyQuotaRemainingPercent": 25,
                    }
                }
            }
        )
        self.assertEqual(
            parsed["limits"],
            [{
                "label": "Weekly (7-day)",
                "title": "Weekly",
                "percent": 0.75,
                "resetsAt": "",
            }],
        )

    def test_credentials_are_bounded_and_api_server_is_validated(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            credentials = Path(directory) / "credentials.toml"
            credentials.write_text(
                'windsurf_api_key = "test-token"\napi_server_url = "https://server.codeium.com"\n',
                encoding="utf-8",
            )
            with patch.dict("os.environ", {"DEVIN_CREDENTIALS_FILE": str(credentials)}):
                self.assertEqual(
                    read_devin_credentials(),
                    ("test-token", "https://server.codeium.com"),
                )

            credentials.write_text(
                'windsurf_api_key = "test-token"\napi_server_url = "https://user@evil.example"\n',
                encoding="utf-8",
            )
            with patch.dict("os.environ", {"DEVIN_CREDENTIALS_FILE": str(credentials)}):
                with self.assertRaisesRegex(ValueError, "invalid API server"):
                    read_devin_credentials()

            credentials.write_bytes(b"x" * (devin.MAX_CREDENTIAL_BYTES + 1))
            with patch.dict("os.environ", {"DEVIN_CREDENTIALS_FILE": str(credentials)}):
                with self.assertRaisesRegex(ValueError, "unexpectedly large"):
                    read_devin_credentials()

    def test_python_310_credentials_fallback_reads_only_supported_key(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            credentials = Path(directory) / "credentials.toml"
            credentials.write_text(
                'windsurf_api_key = "test-token"\napi_server_url = "https://devin.example"\n',
                encoding="utf-8",
            )
            with (
                patch.dict("os.environ", {"DEVIN_CREDENTIALS_FILE": str(credentials)}),
                patch.object(devin, "tomllib", None),
            ):
                self.assertEqual(read_devin_credentials(), ("test-token", "https://devin.example"))

    def test_collect_sends_credential_only_to_configured_quota_endpoint(self) -> None:
        payload = {
            "userStatus": {
                "planStatus": {
                    "planInfo": {"planName": "Pro"},
                    "dailyQuotaRemainingPercent": 46,
                }
            }
        }
        with (
            patch.object(
                devin,
                "collect_local_stats",
                return_value=(empty_devin_stats(), False, ""),
            ),
            patch.object(
                devin,
                "read_credentials",
                return_value=("test-token", "https://server.codeium.com"),
            ),
            patch.object(devin, "request_json", return_value=payload) as request,
        ):
            record = collect_devin()
        self.assertTrue(record["ready"])
        self.assertEqual(record["scope"], "account")
        self.assertEqual(record["tierLabel"], "Pro")
        self.assertEqual(
            request.call_args.args[0],
            "https://server.codeium.com/exa.seat_management_pb.SeatManagementService/GetUserStatus",
        )
        self.assertEqual(request.call_args.kwargs["headers"]["Connect-Protocol-Version"], "1")
        self.assertEqual(request.call_args.kwargs["body"]["metadata"]["apiKey"], "test-token")
        self.assertNotIn("test-token", json.dumps(record))

    def test_collect_distinguishes_expired_auth_from_transport_failure(self) -> None:
        local = (empty_devin_stats(), False, "")
        rejected_error = HTTPError("https://server.codeium.com", 401, "unauthorized", {}, None)
        with (
            tempfile.TemporaryDirectory() as state_home,
            patch.dict("os.environ", {"XDG_STATE_HOME": state_home}),
            patch.object(devin, "collect_local_stats", return_value=local),
            patch.object(
                devin,
                "read_credentials",
                return_value=("test-token", "https://server.codeium.com"),
            ),
            patch.object(devin, "request_json", side_effect=rejected_error),
        ):
            rejected = collect_devin()
        rejected_error.close()
        self.assertEqual(rejected["usageStatusText"], "Devin sign-in expired")
        self.assertNotIn("retryAdvised", rejected)

        with (
            tempfile.TemporaryDirectory() as state_home,
            patch.dict("os.environ", {"XDG_STATE_HOME": state_home}),
            patch.object(devin, "collect_local_stats", return_value=local),
            patch.object(
                devin,
                "read_credentials",
                return_value=("test-token", "https://server.codeium.com"),
            ),
            patch.object(devin, "request_json", side_effect=URLError("offline")),
        ):
            unavailable = collect_devin()
        self.assertEqual(unavailable["usageStatusText"], "Devin usage unavailable")
        self.assertTrue(unavailable["retryAdvised"])


class OpenCodeGoCollectorTests(unittest.TestCase):
    def test_stats_from_rows_aggregates_today_and_all_time(self) -> None:
        today_ms = int(_utc_midnight_ms(days_ago=0))
        yesterday_ms = int(_utc_midnight_ms(days_ago=1))
        rows = [
            ("session-1", today_ms, "claude-sonnet-5", 100, 50, 10, 0),
            ("session-1", today_ms, "claude-sonnet-5", 20, 5, 0, 0),
            ("session-2", yesterday_ms, "gpt-5", 200, 100, 0, 0),
        ]
        stats = opencode_go_stats_from_rows(rows)
        self.assertEqual(stats["todayPrompts"], 2)
        self.assertEqual(stats["todaySessions"], 1)
        self.assertEqual(stats["todayTotalTokens"], 185)
        self.assertEqual(stats["totalPrompts"], 3)
        self.assertEqual(stats["totalSessions"], 2)
        self.assertEqual(stats["activeDays"], 2)
        self.assertEqual(
            stats["modelUsage"]["claude-sonnet-5"],
            {"inputTokens": 120, "outputTokens": 55, "cacheReadInputTokens": 10, "cacheCreationInputTokens": 0},
        )
        self.assertEqual(len(stats["recentDays"]), 7)
        self.assertEqual(stats["recentDays"][-1]["messageCount"], 185)

    def test_stats_from_rows_empty_is_a_valid_zero_state(self) -> None:
        stats = opencode_go_stats_from_rows([])
        self.assertEqual(stats["totalPrompts"], 0)
        self.assertEqual(stats["recentDays"], [])

    def test_limit_window_scales_percent_from_0_100_to_0_1(self) -> None:
        window = opencode_go_limit_window({"rolling": {"percent": 42, "resetsAt": "2026-08-23T18:00:00+00:00"}}, "rolling", "Session")
        self.assertEqual(window["percent"], 0.42)
        self.assertEqual(window["title"], "Session")

    def test_limit_window_rejects_missing_percent(self) -> None:
        with self.assertRaisesRegex(ValueError, "percent is missing"):
            opencode_go_limit_window({"rolling": {}}, "rolling", "Session")

    def test_collect_reports_missing_auth_but_keeps_local_stats(self) -> None:
        stats = {
            "todayPrompts": 3, "todaySessions": 1, "todayTotalTokens": 900, "todayTokensByModel": {},
            "recentDays": [], "modelUsage": {}, "totalPrompts": 3, "totalSessions": 1,
            "activeDays": 1, "activeDates": [],
        }
        with tempfile.TemporaryDirectory() as empty_state_dir:
            with patch.object(opencode_go, "read_key", return_value=None), patch.object(opencode_go, "collect_local_stats", return_value=stats), patch("agent_usage_collectors.common.usage_dir", return_value=Path(empty_state_dir)):
                record = collect_opencode_go()
        self.assertFalse(record["ready"])
        self.assertEqual(record["usageStatusText"], "Waiting for auth")
        self.assertEqual(record["todayTotalTokens"], 900)
        self.assertEqual(record["limits"], [])

    def test_collect_reports_sign_in_expired_without_dropping_local_stats(self) -> None:
        stats = {
            "todayPrompts": 3, "todaySessions": 1, "todayTotalTokens": 900, "todayTokensByModel": {},
            "recentDays": [], "modelUsage": {}, "totalPrompts": 3, "totalSessions": 1,
            "activeDays": 1, "activeDates": [],
        }
        error = HTTPError("https://opencode.ai/zen/go/v1/usage", 401, "unauthorized", None, None)
        with tempfile.TemporaryDirectory() as empty_state_dir:
            with patch.object(opencode_go, "read_key", return_value="stale-key"), patch.object(opencode_go, "collect_local_stats", return_value=stats), patch.object(opencode_go, "request_json", side_effect=error), patch("agent_usage_collectors.common.usage_dir", return_value=Path(empty_state_dir)):
                record = collect_opencode_go()
        self.assertEqual(record["usageStatusText"], "OpenCode Go sign-in expired")
        self.assertEqual(record["todayTotalTokens"], 900)

    def test_collect_with_working_key_reports_all_three_windows(self) -> None:
        stats = opencode_go_stats_from_rows([])
        payload = {
            "usage": {
                "rolling": {"percent": 10, "resetsAt": "2026-08-23T18:00:00+00:00"},
                "weekly": {"percent": 20, "resetsAt": "2026-08-27T00:00:00+00:00"},
                "monthly": {"percent": 30, "resetsAt": "2026-09-01T00:00:00+00:00"},
            }
        }
        with patch.object(opencode_go, "read_key", return_value="live-key"), patch.object(opencode_go, "collect_local_stats", return_value=stats), patch.object(opencode_go, "request_json", return_value=payload):
            record = collect_opencode_go()
        self.assertTrue(record["ready"])
        self.assertEqual([limit["title"] for limit in record["limits"]], ["Session", "Weekly", "Monthly"])
        self.assertEqual(record["limits"][1]["percent"], 0.2)


class AgyCollectorTests(unittest.TestCase):
    """Tests for Antigravity (AGY) collector.

    Verifies quota parsing, local SQLite aggregation, and the hand-written
    protobuf wire-format parser used to avoid third-party dependencies
    (like google.protobuf) as described in collectors/README.md.
    """

    # Fixed protobuf wire format payloads representing records from Antigravity SQLite
    # databases (~/.gemini/antigravity-cli/conversations/*.db).
    #
    # SAMPLE_GEN_METADATA_BLOB:
    # Encodes an envelope message matching gen_metadata.data:
    #   Field 1 (FIELD_GEN_INFO, length-delimited, length 27 = 0x1b):
    #     Field 19 (FIELD_MODEL_NAME, length-delimited, length 16 = 0x10): "gemini-3.8-flash"
    #     Field 4 (FIELD_USAGE_METADATA, length-delimited, length 6):
    #       Field 2 (FIELD_INPUT_TOKENS, varint): 100
    #       Field 3 (FIELD_OUTPUT_TOKENS, varint): 50
    #       Field 5 (FIELD_CACHE_READ_TOKENS, varint): 20
    #   Total tokens: 100 + 50 + 20 = 170.
    SAMPLE_GEN_METADATA_BLOB = b'\n\x1b\x9a\x01\x10gemini-3.8-flash"\x06\x10d\x182(\x14'

    # SAMPLE_STEP_METADATA_BLOB:
    # Encodes a step header message matching steps.metadata:
    #   Field 1 (FIELD_STEP_HEADER, length-delimited, length 6):
    #     Field 1 (FIELD_TIMESTAMP_SECONDS, varint): 1757088000
    #   Timestamp corresponds to 2025-09-05 16:00:00 UTC.
    SAMPLE_STEP_METADATA_BLOB = b'\n\x06\x08\x80\x92\xec\xc5\x06'

    # REAL_WORLD_GEN_METADATA_FIXTURE:
    # Full, production Protobuf wire-format generation payload extracted from an actual
    # Antigravity conversation database, with all non-usage identifiers sanitized (UUIDs,
    # response IDs, and execution hashes replaced with dummy values of identical length).
    # Verifies that our hand-written parser safely handles complete multi-field message
    # envelopes with interleaved tags (tags 2, 4, 5, 8, and 1, plus internal model enums,
    # latency breakdowns, and metadata maps) without misaligning byte offsets.
    REAL_WORLD_GEN_METADATA_FIXTURE = bytes.fromhex(
        "12020102222430303030303030302d303030302d303030302d303030302d30303030303030303030"
        "30302a2e73747265616d2072656164696e67206572726f723a20636f6e746578742063616e63656c"
        "65642062792075736572429803000000000000000000000000000000000000000000000000000000"
        "00000000000000000000000000000000000000000000000000000000000000000000000000000000"
        "00000000000000000000000000000000000000000000000000000000000000000000000000000000"
        "00000000000000000000000000000000000000000000000000000000000000000000000000000000"
        "00000000000000000000000000000000000000000000000000000000000000000000000000000000"
        "00000000000000000000000000000000000000000000000000000000000000000000000000000000"
        "00000000000000000000000000000000000000000000000000000000000000000000000000000000"
        "00000000000000000000000000000000000000000000000000000000000000000000000000000000"
        "00000000000000000000000000000000000000000000000000000000000000000000000000000000"
        "00000000000000000000000000000000000000000000000000000000000000000000000000000000"
        "0000000000000000000000000000000000000000000a830518a60a227808a60a10f43518970128c7"
        "3f30183a28626f742d30303030303030302d303030302d303030302d303030302d30303030303030"
        "303030303042210a0973657373696f6e494412142d30303030303030303030303030303030303030"
        "486350345a1773616d706c652d726573702d69642d616e7469677261764a1510ffffffffffffffff"
        "ff015208089da7012080d00f5a08080110d093adae016205109795bd078a01be01127808a60a10f4"
        "3518970128c73f30183a28626f742d30303030303030302d303030302d303030302d303030302d30"
        "303030303030303030303042210a0973657373696f6e494412142d30303030303030303030303030"
        "303030303030486350345a1773616d706c652d726573702d69642d616e7469677261761a2e737472"
        "65616d2072656164696e67206572726f723a20636f6e746578742063616e63656c65642062792075"
        "73657222103030303030303030303030303030303028039a011067656d696e692d332e382d666c61"
        "7368a201140a0f6c6173745f737465705f696e646578120130a201240a0a6d6f64656c5f656e756d"
        "12164d4f44454c5f504c414345484f4c4445525f4d333138a201350a0d7472616a6563746f72795f"
        "6964122430303030303030302d303030302d303030302d303030302d303030303030303030303030"
        "a201340a0a726571756573745f6964122630303030303030302d303030302d303030302d30303030"
        "2d3030303030303030303030302d30a201140a0b757365645f636c61756465120566616c7365a201"
        "210a18757365645f636c617564655f636f6e736572766174697665120566616c7365a2011e0a1575"
        "7365645f6e6f6e5f67656d696e695f6d6f64656c120566616c7365"
    )

    # REAL_WORLD_STEP_METADATA_FIXTURE:
    # Full, production Protobuf wire-format step header extracted from an actual
    # Antigravity database, with UUIDs sanitized.
    REAL_WORLD_STEP_METADATA_FIXTURE = bytes.fromhex(
        "0a0b089996eed40610a888985f1804622430303030303030302d303030302d303030302d30303030"
        "2d303030303030303030303030a2014c0a2430303030303030302d303030302d303030302d303030"
        "302d303030303030303030303030222430303030303030302d303030302d303030302d303030302d"
        "303030303030303030303030d201110a0f0803120b089996eed40610c3d4a064"
    )

    def test_parse_quota_groups(self) -> None:
        groups = [
            {
                "name": "Gemini Models",
                "buckets": [
                    {"window": "weekly", "remaining_fraction": 0.88, "reset_time": "2026-09-12T03:32:00Z"},
                    {"window": "5h", "remaining_fraction": 0.45, "reset_time": "2026-09-05T22:51:00Z"},
                    {"window": "5h", "remaining_fraction": "invalid"},
                ],
            },
            {
                "name": "Claude and OpenAI Models",
                "buckets": [
                    {"window": "weekly", "remaining_fraction": 0.5, "reset_time": "2026-09-12T00:00:00Z"},
                    {"window": "5h", "remaining_fraction": 0.1, "reset_time": "2026-09-05T22:00:00Z"},
                ],
            },
        ]
        limits = agy.parse_quota_groups(groups)
        self.assertEqual(len(limits), 4)
        # Session (5h) ordered before Weekly (7-day), matching Codex
        self.assertEqual(limits[0]["title"], "Session")
        self.assertEqual(limits[0]["label"], "Session (5-hour)")
        self.assertEqual(limits[0]["percent"], 0.55)
        self.assertEqual(limits[1]["title"], "Weekly")
        self.assertEqual(limits[1]["label"], "Weekly (7-day)")
        self.assertEqual(limits[1]["percent"], 0.12)
        self.assertEqual(limits[2]["title"], "Claude and OpenAI Session")
        self.assertEqual(limits[2]["label"], "Claude and OpenAI Session (5-hour)")
        self.assertEqual(limits[2]["percent"], 0.9)
        self.assertEqual(limits[3]["title"], "Claude and OpenAI Weekly")
        self.assertEqual(limits[3]["label"], "Claude and OpenAI Weekly (7-day)")
        self.assertEqual(limits[3]["percent"], 0.5)

        # Fallback handling for empty prefix and unknown/custom window types
        fallback_groups = [
            {
                "name": "",
                "buckets": [
                    {"window": "weekly", "remaining_fraction": 0.8, "reset_time": "2026-09-12T03:32:00Z"},
                    {"window": "5h", "remaining_fraction": 0.4, "reset_time": "2026-09-05T22:51:00Z"},
                    {"window": "monthly", "name": "Monthly Limit", "remaining_fraction": 0.2, "reset_time": "2026-10-01T00:00:00Z"},
                    "not-a-dict",
                ],
            }
        ]
        fallback_limits = agy.parse_quota_groups(fallback_groups)
        self.assertEqual(len(fallback_limits), 3)
        self.assertEqual(fallback_limits[0]["title"], "Session")
        self.assertEqual(fallback_limits[0]["label"], "Session (5-hour)")
        self.assertEqual(fallback_limits[1]["title"], "Weekly")
        self.assertEqual(fallback_limits[1]["label"], "Weekly (7-day)")
        self.assertEqual(fallback_limits[2]["title"], "Monthly Limit")
        self.assertEqual(fallback_limits[2]["label"], "Monthly Limit")

    def test_parse_gen_metadata_and_timestamp(self) -> None:
        model, inp, out, cache, resp_id = agy.parse_gen_metadata(self.SAMPLE_GEN_METADATA_BLOB)
        self.assertEqual(model, "gemini-3.8-flash")
        self.assertEqual(inp, 100)
        self.assertEqual(out, 50)
        self.assertEqual(cache, 20)
        self.assertEqual(resp_id, "")

        # Payload with explicit response_id (tag 11 in UsageMetadata)
        blob_with_resp_id = b'\n\x25\x9a\x01\x10gemini-3.8-flash"\x10\x10d\x182(\x14\x5a\x08resp-123'
        m_r, i_r, o_r, c_r, r_r = agy.parse_gen_metadata(blob_with_resp_id)
        self.assertEqual(m_r, "gemini-3.8-flash")
        self.assertEqual((i_r, o_r, c_r), (100, 50, 20))
        self.assertEqual(r_r, "resp-123")

        # Payload with thinking (tag 9 = 40) and candidate response (tag 10 = 60), tag 3 absent
        blob_thinking_no_tag3 = b'\n\x1b\x9a\x01\x10gemini-3.8-flash"\x06\x10dH(P<'
        _, _, o_think, _, _ = agy.parse_gen_metadata(blob_thinking_no_tag3)
        self.assertEqual(o_think, 100)

        # Payload where tag 3 only has candidate text (60), but thinking (40) is present
        blob_thinking_with_tag3 = b'\n\x1d\x9a\x01\x10gemini-3.8-flash"\x08\x10d\x18<H(P<'
        _, _, o_combined, _, _ = agy.parse_gen_metadata(blob_thinking_with_tag3)
        self.assertEqual(o_combined, 100)

        # Empty and non-matching/corrupted blobs return zero defaults
        self.assertEqual(agy.parse_gen_metadata(b""), ("", 0, 0, 0, ""))
        self.assertEqual(agy.parse_gen_metadata(b"\xff\xff"), ("", 0, 0, 0, ""))
        self.assertEqual(agy.parse_gen_metadata(b"\x08\x01"), ("", 0, 0, 0, ""))

        # Payloads exceeding maximum metadata size limit are rejected
        oversized = b"\x00" * (agy.MAX_METADATA_BYTES + 1)
        self.assertEqual(agy.parse_gen_metadata(oversized), ("", 0, 0, 0, ""))

        # Valid step timestamp parsing
        self.assertEqual(agy.parse_step_timestamp(self.SAMPLE_STEP_METADATA_BLOB), 1757088000)
        self.assertIsNone(agy.parse_step_timestamp(b""))
        self.assertIsNone(agy.parse_step_timestamp(b"\xff\xff"))
        self.assertIsNone(agy.parse_step_timestamp(b"not-proto"))
        self.assertIsNone(agy.parse_step_timestamp(oversized))

        # bytearray input is accepted directly
        m_ba, i_ba, o_ba, c_ba, r_ba = agy.parse_gen_metadata(bytearray(self.SAMPLE_GEN_METADATA_BLOB))
        self.assertEqual(m_ba, "gemini-3.8-flash")
        self.assertEqual((i_ba, o_ba, c_ba), (100, 50, 20))
        self.assertEqual(r_ba, "")
        self.assertEqual(agy.parse_step_timestamp(bytearray(self.SAMPLE_STEP_METADATA_BLOB)), 1757088000)

        # Timestamps outside the valid epoch range are rejected
        out_of_range_low = b"\n\x02\x08\x00"  # ts = 0
        self.assertIsNone(agy.parse_step_timestamp(out_of_range_low))

    def test_usage_cache_creation_and_viewable_step_timestamp(self) -> None:
        usage = b"\x10d\x182 \x1e(\x14"  # input=100, output=50, cache write=30, cache read=20
        generation = b"\x9a\x01\x10gemini-3.8-flash" + b'"' + bytes([len(usage)]) + usage
        blob = b"\n" + bytes([len(generation)]) + generation
        stats = agy.stats_from_rows([("session", blob, None, None)], now=datetime.fromtimestamp(1757088000))
        self.assertEqual(stats["todayTotalTokens"], 200)
        self.assertEqual(stats["modelUsage"]["gemini-3.8-flash"]["cacheCreationInputTokens"], 30)

        # Some step records only expose their usable timestamp in field 8.
        viewable_at = b"B\x06\x08\x80\x92\xec\xc5\x06"
        self.assertEqual(agy.parse_step_timestamp(viewable_at), 1757088000)

    def test_generation_retries_and_continuations_keep_usage_and_model(self) -> None:
        primary = b"\x10\x05\x18\x03"
        retry_usage = b"\x10\x07\x18\x02"
        retry = b"\x12" + bytes([len(retry_usage)]) + retry_usage
        generation = (
            b"\x9a\x01\x10gemini-3.8-flash"
            + b'"' + bytes([len(primary)]) + primary
            + b"\x8a\x01" + bytes([len(retry)]) + retry
        )
        retries_blob = b"\n" + bytes([len(generation)]) + generation
        continuation_blob = b"\n\x06\"\x04\x10\x0b\x18\x0d"
        stats = agy.stats_from_rows(
            [("session", retries_blob, None, None), ("session", continuation_blob, None, None)],
            now=datetime.fromtimestamp(1757088000),
        )
        self.assertEqual(stats["totalPrompts"], 3)
        self.assertEqual(stats["modelUsage"]["gemini-3.8-flash"]["inputTokens"], 23)
        self.assertNotIn("gemini", stats["modelUsage"])

    def test_real_world_full_protobuf_fixture_end_to_end(self) -> None:
        model, inp, out, cache, resp_id = agy.parse_gen_metadata(self.REAL_WORLD_GEN_METADATA_FIXTURE)
        self.assertEqual(model, "gemini-3.8-flash")
        self.assertEqual(inp, 6900)
        self.assertEqual(out, 151)
        self.assertEqual(cache, 8135)
        self.assertEqual(resp_id, "sample-resp-id-antigrav")

        sec = agy.parse_step_timestamp(self.REAL_WORLD_STEP_METADATA_FIXTURE)
        self.assertEqual(sec, 1788578585)

        fixed_now = datetime.fromtimestamp(1788578585)
        rows = [("real_sess_1", self.REAL_WORLD_GEN_METADATA_FIXTURE, self.REAL_WORLD_STEP_METADATA_FIXTURE, None)]
        stats = agy.stats_from_rows(rows, now=fixed_now)
        self.assertEqual(stats["totalPrompts"], 1)
        self.assertEqual(stats["todayPrompts"], 1)
        self.assertEqual(stats["todayTotalTokens"], 6900 + 151 + 8135)
        self.assertIn("gemini-3.8-flash", stats["modelUsage"])

        with tempfile.TemporaryDirectory() as tmpdir:
            db_path = Path(tmpdir) / "real_session.db"
            conn = sqlite3.connect(db_path)
            conn.execute("CREATE TABLE gen_metadata (idx INTEGER, data BLOB)")
            conn.execute("CREATE TABLE steps (idx INTEGER, metadata BLOB)")
            conn.execute("INSERT INTO gen_metadata (idx, data) VALUES (0, ?)", (self.REAL_WORLD_GEN_METADATA_FIXTURE,))
            conn.execute("INSERT INTO steps (idx, metadata) VALUES (0, ?)", (self.REAL_WORLD_STEP_METADATA_FIXTURE,))
            conn.commit()
            conn.close()

            rec = agy.base_record("agy", "Antigravity", "Antigravity")
            ok = agy.fetch_local_stats(rec, conversations_dirs=[Path(tmpdir)])
            self.assertTrue(ok)
            self.assertEqual(rec["totalPrompts"], 1)
            self.assertTrue(rec["hasLocalStats"])
            self.assertTrue(rec["hasPromptStats"])
            self.assertIn("gemini-3.8-flash", rec["modelUsage"])
            bucket = rec["modelUsage"]["gemini-3.8-flash"]
            self.assertEqual(bucket["inputTokens"], 6900)
            self.assertEqual(bucket["outputTokens"], 151)
            self.assertEqual(bucket["cacheReadInputTokens"], 8135)

    def test_row_with_bulky_embedded_context_field_still_yields_tokens(self) -> None:
        # Antigravity's final gen_metadata row of a session embeds the full chat
        # context alongside the small usage fields, pushing some rows past the old
        # 64 KiB cap (observed up to ~920 KiB) — that cap used to drop the whole row,
        # tokens included. Field 2 here (tag 0x12) stands in for that bulk context.
        bulky_context_field = b"\x12" + _encode_varint(100_000) + b"\x00" * 100_000
        blob = self.SAMPLE_GEN_METADATA_BLOB + bulky_context_field
        self.assertGreater(len(blob), 64 * 1024)
        self.assertLess(len(blob), agy.MAX_METADATA_BYTES)

        model, inp, out, cache, _ = agy.parse_gen_metadata(blob)
        self.assertEqual(model, "gemini-3.8-flash")
        self.assertEqual((inp, out, cache), (100, 50, 20))

        with tempfile.TemporaryDirectory() as tmpdir:
            db_path = Path(tmpdir) / "bulky_session.db"
            conn = sqlite3.connect(db_path)
            conn.execute("CREATE TABLE gen_metadata (idx INTEGER, data BLOB)")
            conn.execute("INSERT INTO gen_metadata (idx, data) VALUES (0, ?)", (blob,))
            conn.commit()
            conn.close()

            rec = agy.base_record("agy", "Antigravity", "Antigravity")
            ok = agy.fetch_local_stats(rec, conversations_dirs=[Path(tmpdir)])
            self.assertTrue(ok)
            self.assertEqual(rec["totalPrompts"], 1)
            self.assertEqual(rec["modelUsage"]["gemini-3.8-flash"]["inputTokens"], 100)
            self.assertNotIn("usageStatusText", rec)

    def test_protobuf_parser_iterable_and_guardrails(self) -> None:
        # ProtobufParser can be instantiated with bytes and iterated directly
        parser = agy.ProtobufParser(b"\x08\x01")
        self.assertEqual(list(parser), [(1, 0, 1)])
        # Multi-pass iteration supported on bytes-backed parser
        self.assertEqual(list(parser), [(1, 0, 1)])

        # Empty payload produces empty iteration
        self.assertEqual(list(agy.ProtobufParser(b"")), [])

        # Field 0 is illegal in Protobuf wire format and must immediately halt parsing
        self.assertEqual(list(agy.ProtobufParser(b"\x00\x00")), [])

        # Field numbers exceeding MAX_PROTO_FIELD_NUMBER are rejected
        # Varint key with field_number = 2^29: (1 << 32)
        excessive_key = b"\x80\x80\x80\x80\x10"
        self.assertEqual(list(agy.ProtobufParser(excessive_key)), [])

        # A length-delimited field declaring a payload larger than MAX_FIELD_BYTES is
        # skipped (not materialized), not aborted — parsing continues afterwards.
        # Tag 0x0A (field 1, wire type 2), length varint = 131072 (exceeds 64 KiB)
        oversized_len_field = b"\n\x80\x80\x08"
        self.assertEqual(list(agy.ProtobufParser(oversized_len_field)), [])

        # A small field following an oversized one (e.g. a huge embedded chat-context
        # or tool-payload blob) is still yielded: the oversized field is skipped over,
        # it does not abort parsing of the rest of the message.
        padding_len = agy.MAX_FIELD_BYTES + 1  # 65537
        oversized_then_small = b"\n" + _encode_varint(padding_len) + b"\x00" * padding_len + b"\x08\x01"
        self.assertEqual(list(agy.ProtobufParser(oversized_then_small)), [(1, 0, 1)])

    def test_stats_from_rows(self) -> None:
        fixed_now = datetime.fromtimestamp(1757088000)
        rows = [("sess1", self.SAMPLE_GEN_METADATA_BLOB, self.SAMPLE_STEP_METADATA_BLOB, None)]
        stats = agy.stats_from_rows(rows, now=fixed_now)
        self.assertEqual(stats["todayPrompts"], 1)
        self.assertEqual(stats["todaySessions"], 1)
        self.assertEqual(stats["todayTotalTokens"], 170)
        self.assertIn("gemini-3.8-flash", stats["modelUsage"])
        self.assertEqual(
            stats["modelUsage"]["gemini-3.8-flash"],
            {"inputTokens": 100, "outputTokens": 50, "cacheReadInputTokens": 20, "cacheCreationInputTokens": 0},
        )

        # Missing model name falls back to "gemini" bucket
        blob_no_model = b'\n\x08"\x06\x10d\x182(\x14'
        anon_stats = agy.stats_from_rows([("sess2", blob_no_model, None, None)], now=fixed_now)
        self.assertIn("gemini", anon_stats["modelUsage"])
        self.assertEqual(anon_stats["modelUsage"]["gemini"]["inputTokens"], 100)

        # Duplicate generations sharing the same response_id are deduplicated
        blob_resp_a = b'\n\x25\x9a\x01\x10gemini-3.8-flash"\x10\x10d\x182(\x14\x5a\x08resp-123'
        dup_rows = [
            ("sess1", blob_resp_a, self.SAMPLE_STEP_METADATA_BLOB, None),
            ("sess1", blob_resp_a, self.SAMPLE_STEP_METADATA_BLOB, None),
        ]
        dedup_stats = agy.stats_from_rows(dup_rows, now=fixed_now)
        self.assertEqual(dedup_stats["todayPrompts"], 1)
        self.assertEqual(dedup_stats["todayTotalTokens"], 170)

        # Distinct response_ids are both counted
        blob_resp_b = b'\n\x25\x9a\x01\x10gemini-3.8-flash"\x10\x10d\x182(\x14\x5a\x08resp-456'
        multi_rows = [
            ("sess1", blob_resp_a, self.SAMPLE_STEP_METADATA_BLOB, None),
            ("sess1", blob_resp_b, self.SAMPLE_STEP_METADATA_BLOB, None),
        ]
        multi_stats = agy.stats_from_rows(multi_rows, now=fixed_now)
        self.assertEqual(multi_stats["todayPrompts"], 2)
        self.assertEqual(multi_stats["todayTotalTokens"], 340)

        empty = agy.stats_from_rows([])
        self.assertEqual(empty["todayPrompts"], 0)
        self.assertEqual(empty["todayTotalTokens"], 0)
        self.assertEqual(empty["totalPrompts"], 0)

    def test_fetch_quota_never_runs_print_mode_while_signed_out(self) -> None:
        rec = lambda: agy.base_record("agy", "Antigravity", "Antigravity")
        with (
            tempfile.TemporaryDirectory() as empty_state_dir,
            patch("agent_usage_collectors.common.usage_dir", return_value=Path(empty_state_dir)),
            patch.object(shutil, "which", return_value="/usr/bin/agy"),
        ):
            # `agy models` fails fast (no browser, no prompt) when signed out. That must
            # be enough to report auth-missing without ever running `agy -p /usage`,
            # which opens a browser and blocks waiting for OAuth when signed out.
            with patch.object(agy, "run_bounded_command", return_value=(1, b"Please sign in")) as mock_run:
                r = rec()
                ok = agy.fetch_quota(r)
                self.assertFalse(ok)
                self.assertEqual(r["usageStatusText"], "Waiting for agy")
                self.assertEqual(r["authHelpText"], agy.AUTH_HELP)
                self.assertFalse(r["ready"])
                mock_run.assert_called_once_with(
                    ["/usr/bin/agy", "models"], agy.AGY_AUTH_PROBE_TIMEOUT_SECONDS, merge_stderr=True
                )

            # A timeout, launch failure, or unrecognized non-zero exit on the probe
            # itself is a transport problem, not a confirmed sign-out — it must never
            # be reported as "sign in" (which would be misleading), and it must still
            # never let a `-p /usage` attempt through while auth state is unknown.
            with patch.object(agy, "run_bounded_command", side_effect=agy.subprocess.TimeoutExpired(["agy", "models"], 5)) as mock_run:
                r = rec()
                self.assertFalse(agy.fetch_quota(r))
                self.assertEqual(r["usageStatusText"], agy.STATUS_QUOTA_UNAVAILABLE)
                self.assertNotEqual(r["usageStatusText"], "Waiting for agy")
                mock_run.assert_called_once()

            with patch.object(agy, "run_bounded_command", return_value=(127, b"command not found")) as mock_run:
                r = rec()
                self.assertFalse(agy.fetch_quota(r))
                self.assertEqual(r["usageStatusText"], agy.STATUS_QUOTA_UNAVAILABLE)
                mock_run.assert_called_once()

            # Signed in: the probe succeeds, so the real usage probe still runs.
            with patch.object(
                agy,
                "run_bounded_command",
                side_effect=[(0, b""), (0, b'{"status": "SUCCESS", "command": {"data": {"groups": []}}}')],
            ) as mock_run:
                r = rec()
                ok = agy.fetch_quota(r)
                self.assertTrue(ok)
                self.assertEqual(r["limits"], [])
                self.assertEqual(mock_run.call_count, 2)
                self.assertEqual(mock_run.call_args_list[0].args[0], ["/usr/bin/agy", "models"])
                self.assertEqual(mock_run.call_args_list[1].args[0], ["/usr/bin/agy", "-p", "/usage", "--output-format", "json"])

    def test_fetch_quota_handles_cli_failures(self) -> None:
        rec = lambda: agy.base_record("agy", "Antigravity", "Antigravity")
        with (
            tempfile.TemporaryDirectory() as empty_state_dir,
            patch("agent_usage_collectors.common.usage_dir", return_value=Path(empty_state_dir)),
        ):
            # Missing binary in PATH
            with patch.object(shutil, "which", return_value=None), patch.dict("os.environ", {"AGY_CLI_PATH": ""}):
                r = rec()
                ok = agy.fetch_quota(r)
                self.assertFalse(ok)
                self.assertEqual(r["limits"], [])
                self.assertEqual(r["usageStatusText"], "Waiting for agy")
                self.assertIn("agy not found", r["authHelpText"])
                self.assertFalse(r["ready"])

            # Non-zero exit code
            with patch.object(agy, "run_bounded_command", return_value=(1, b"secret stderr is never captured")):
                r = rec()
                ok = agy.fetch_quota(r, command_override=["agy"])
                self.assertFalse(ok)
                self.assertEqual(r["usageStatusText"], agy.STATUS_QUOTA_UNAVAILABLE)
                self.assertNotIn("secret", r["authHelpText"])
                self.assertFalse(r["ready"])

            # OSError when executing binary
            with patch.object(agy, "run_bounded_command", side_effect=OSError("permission denied")):
                r = rec()
                ok = agy.fetch_quota(r, command_override=["agy"])
                self.assertFalse(ok)
                self.assertEqual(r["limits"], [])
                self.assertEqual(r["usageStatusText"], agy.STATUS_QUOTA_UNAVAILABLE)
                self.assertNotIn("permission denied", r["authHelpText"])
                self.assertFalse(r["ready"])

            # Invalid JSON output
            with patch.object(agy, "run_bounded_command", return_value=(0, b"not-json")):
                r = rec()
                ok = agy.fetch_quota(r, command_override=["agy"])
                self.assertFalse(ok)
                self.assertEqual(r["authHelpText"], "agy returned invalid JSON")
                self.assertFalse(r["ready"])

            # Null or non-dict command/data payloads
            for bad_payload, expected_err in [
                ('{"status": "SUCCESS", "command": null}', "Unexpected command payload"),
                ('{"status": "SUCCESS", "command": "not-a-dict"}', "Unexpected command payload"),
                ('{"status": "SUCCESS", "command": {"data": null}}', "Unexpected data payload"),
                ('{"status": "SUCCESS", "command": {"data": "not-a-dict"}}', "Unexpected data payload"),
                ('{"status": "SUCCESS", "command": {"data": {"groups": null}}}', "No quota groups returned"),
            ]:
                with patch.object(agy, "run_bounded_command", return_value=(0, bad_payload.encode())):
                    r = rec()
                    ok = agy.fetch_quota(r, command_override=["agy"])
                    self.assertFalse(ok)
                    self.assertEqual(r["limits"], [])
                    self.assertEqual(r["usageStatusText"], agy.STATUS_QUOTA_UNAVAILABLE)
                    self.assertEqual(r["authHelpText"], expected_err)
                    self.assertFalse(r["ready"])

            # Successful quota probe
            with patch.object(agy, "run_bounded_command", return_value=(0, b'{"status": "SUCCESS", "command": {"data": {"groups": []}}}')):
                r = rec()
                ok = agy.fetch_quota(r, command_override=["agy"])
                self.assertTrue(ok)
                self.assertEqual(r["limits"], [])

            with patch.object(agy, "run_bounded_command", return_value=(0, b'{"status": "FAILED", "response": "token=do-not-expose"}')):
                r = rec()
                self.assertFalse(agy.fetch_quota(r, command_override=["agy"]))
                self.assertNotIn("do-not-expose", r["authHelpText"])

    def test_run_bounded_command_rejects_large_output(self) -> None:
        with self.assertRaises(ValueError):
            agy.run_bounded_command(
                [sys.executable, "-c", f"import sys; sys.stdout.buffer.write(b'x' * {MAX_RESPONSE_BYTES + 1})"],
                timeout_seconds=5,
            )

    def test_default_conversations_dirs(self) -> None:
        with patch.dict("os.environ", {}, clear=True), patch("pathlib.Path.home", return_value=Path("/fake/home")):
            dirs = agy.default_conversations_dirs()
            self.assertEqual(
                dirs,
                [
                    Path("/fake/home/.gemini/antigravity/conversations"),
                    Path("/fake/home/.gemini/antigravity-cli/conversations"),
                    Path("/fake/home/.gemini/antigravity-ide/conversations"),
                ],
            )

        with patch.dict("os.environ", {"AGY_CONVERSATIONS_DIR": f"/custom/p1{os.pathsep}/custom/p2"}):
            dirs = agy.default_conversations_dirs()
            self.assertEqual(dirs, [Path("/custom/p1"), Path("/custom/p2")])

        with patch.dict("os.environ", {"AGY_HOME": "/custom/agy"}):
            dirs = agy.default_conversations_dirs()
            self.assertEqual(dirs, [Path("/custom/agy/conversations")])

    def test_fetch_local_stats(self) -> None:
        rec = agy.base_record("agy", "Antigravity", "Antigravity")
        ok = agy.fetch_local_stats(rec, conversations_dirs=[])
        self.assertFalse(ok)
        self.assertEqual(rec["todayTotalTokens"], 0)
        self.assertEqual(rec["scope"], "device")
        self.assertFalse(rec["hasLocalStats"])
        self.assertFalse(rec["hasPromptStats"])

        with tempfile.TemporaryDirectory() as tmpdir:
            valid_db = Path(tmpdir) / "session.db"
            conn = sqlite3.connect(valid_db)
            conn.execute("CREATE TABLE gen_metadata (idx INTEGER, data BLOB)")
            conn.execute("CREATE TABLE steps (idx INTEGER, metadata BLOB)")
            conn.execute("INSERT INTO gen_metadata (idx, data) VALUES (1, ?)", (self.SAMPLE_GEN_METADATA_BLOB,))
            conn.commit()
            conn.close()

            # Empty 0-byte file alongside valid DB should be skipped without error
            empty_db = Path(tmpdir) / "empty.db"
            empty_db.touch()

            rec2 = agy.base_record("agy", "Antigravity", "Antigravity")
            ok2 = agy.fetch_local_stats(rec2, conversations_dirs=[Path(tmpdir)])
            self.assertTrue(ok2)
            self.assertGreater(rec2["totalPrompts"], 0)
            self.assertEqual(rec2["scope"], "device")
            self.assertTrue(rec2["hasLocalStats"])
            self.assertTrue(rec2["hasPromptStats"])
            self.assertNotIn("usageStatusText", rec2)

            # Directory containing only 0-byte file yields False without error
            valid_db.unlink()
            rec3 = agy.base_record("agy", "Antigravity", "Antigravity")
            ok3 = agy.fetch_local_stats(rec3, conversations_dirs=[Path(tmpdir)])
            self.assertFalse(ok3)
            self.assertFalse(rec3["hasLocalStats"])
            self.assertFalse(rec3["hasPromptStats"])
            self.assertNotIn("usageStatusText", rec3)

    def test_fetch_local_stats_reads_active_wal(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            db_path = Path(tmpdir) / "active.db"
            writer = sqlite3.connect(db_path)
            writer.execute("PRAGMA journal_mode=WAL")
            writer.execute("CREATE TABLE gen_metadata (idx INTEGER, data BLOB)")
            writer.execute("INSERT INTO gen_metadata (idx, data) VALUES (1, ?)", (self.SAMPLE_GEN_METADATA_BLOB,))
            writer.commit()
            try:
                rec = agy.base_record("agy", "Antigravity", "Antigravity")
                self.assertTrue(agy.fetch_local_stats(rec, conversations_dirs=[Path(tmpdir)]))
                self.assertEqual(rec["totalPrompts"], 1)
            finally:
                writer.close()

    def test_fetch_local_stats_exposes_database_error(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            # 1. Schema error: valid SQLite DB missing the gen_metadata table
            bad_schema_db = Path(tmpdir) / "broken_schema.db"
            conn = sqlite3.connect(bad_schema_db)
            conn.execute("CREATE TABLE dummy (id INTEGER)")
            conn.close()

            rec = agy.base_record("agy", "Antigravity", "Antigravity")
            ok = agy.fetch_local_stats(rec, conversations_dirs=[Path(tmpdir)])
            self.assertFalse(ok)
            self.assertEqual(rec["usageStatusText"], agy.STATUS_DATABASE_ERROR)
            self.assertIn("missing gen_metadata table", rec["authHelpText"])
            self.assertFalse(rec["hasLocalStats"])
            self.assertFalse(rec["hasPromptStats"])

            # 2. Corrupt / non-sqlite file
            corrupt_db = Path(tmpdir) / "corrupt.db"
            corrupt_db.write_text("not a sqlite database")
            bad_schema_db.unlink()

            rec = agy.base_record("agy", "Antigravity", "Antigravity")
            ok = agy.fetch_local_stats(rec, conversations_dirs=[Path(tmpdir)])
            self.assertFalse(ok)
            self.assertEqual(rec["usageStatusText"], agy.STATUS_DATABASE_ERROR)
            self.assertIn("file is not a database", rec["authHelpText"])
            self.assertFalse(rec["hasLocalStats"])

            # 3. collect() preserves the database error status when CLI is missing
            with (
                tempfile.TemporaryDirectory() as empty_state_dir,
                patch("agent_usage_collectors.common.usage_dir", return_value=Path(empty_state_dir)),
                patch.object(agy, "default_conversations_dirs", return_value=[Path(tmpdir)]),
                patch.object(shutil, "which", return_value=None),
                patch.dict("os.environ", {"AGY_CLI_PATH": ""}),
            ):
                record = agy.collect()
                self.assertEqual(record["usageStatusText"], agy.STATUS_DATABASE_ERROR)
                self.assertIn("file is not a database", record["authHelpText"])
                self.assertFalse(record["ready"])

            # 4. collect() exposes DB error even if quota probe succeeds, but sets ready=True
            with (
                patch.object(agy, "default_conversations_dirs", return_value=[Path(tmpdir)]),
                patch("shutil.which", return_value="/fake/agy"),
                patch.object(agy, "run_bounded_command", return_value=(0, b'{"status": "SUCCESS", "command": {"data": {"groups": []}}}')),
            ):
                record = agy.collect()
                self.assertEqual(record["usageStatusText"], agy.STATUS_DATABASE_ERROR)
                self.assertIn("file is not a database", record["authHelpText"])
                self.assertTrue(record["ready"])
                self.assertEqual(record["limits"], [])

            # 5. Multiple errors format first error + remaining count
            corrupt_db2 = Path(tmpdir) / "corrupt2.db"
            corrupt_db2.write_text("also not a database")
            rec_multi = agy.base_record("agy", "Antigravity", "Antigravity")
            ok_multi = agy.fetch_local_stats(rec_multi, conversations_dirs=[Path(tmpdir)])
            self.assertFalse(ok_multi)
            self.assertIn("(and 1 other files)", rec_multi["authHelpText"])

            # 6. Database error alongside valid DB: shows error, but retains stats and returns True
            valid_db = Path(tmpdir) / "valid.db"
            conn = sqlite3.connect(valid_db)
            conn.execute("CREATE TABLE gen_metadata (idx INTEGER, data BLOB)")
            conn.execute("CREATE TABLE steps (idx INTEGER, metadata BLOB)")
            conn.execute("INSERT INTO gen_metadata (idx, data) VALUES (1, ?)", (self.SAMPLE_GEN_METADATA_BLOB,))
            conn.commit()
            conn.close()

            rec_partial = agy.base_record("agy", "Antigravity", "Antigravity")
            ok_partial = agy.fetch_local_stats(rec_partial, conversations_dirs=[Path(tmpdir)])
            self.assertTrue(ok_partial)
            self.assertEqual(rec_partial["usageStatusText"], agy.STATUS_DATABASE_ERROR)
            self.assertIn("file is not a database", rec_partial["authHelpText"])
            self.assertTrue(rec_partial["hasLocalStats"])
            self.assertTrue(rec_partial["hasPromptStats"])
            self.assertGreater(rec_partial["todayTotalTokens"], 0)

            # In collect() with missing CLI, ready is True because valid local stats were collected
            with (
                tempfile.TemporaryDirectory() as empty_state_dir,
                patch("agent_usage_collectors.common.usage_dir", return_value=Path(empty_state_dir)),
                patch.object(agy, "default_conversations_dirs", return_value=[Path(tmpdir)]),
                patch.object(shutil, "which", return_value=None),
                patch.dict("os.environ", {"AGY_CLI_PATH": ""}),
            ):
                record = agy.collect()
                self.assertEqual(record["usageStatusText"], agy.STATUS_DATABASE_ERROR)
                self.assertIn("file is not a database", record["authHelpText"])
                self.assertTrue(record["ready"])
                self.assertGreater(record["todayTotalTokens"], 0)

    def test_collect_reports_missing_auth_or_binary_keeps_local_stats(self) -> None:
        stats = {
            "todayPrompts": 2,
            "todaySessions": 1,
            "todayTotalTokens": 500,
            "todayTokensByModel": {},
            "recentDays": [],
            "modelUsage": {},
            "totalPrompts": 2,
            "totalSessions": 1,
            "activeDays": 1,
            "activeDates": [],
        }
        mock_limits = [{"title": "Session", "percent": 0.5, "resetsAt": "2026-09-05T22:00:00Z"}]

        def fake_stats(r: dict) -> bool:
            r.update(stats)
            r["scope"] = "device"
            r["hasLocalStats"] = True
            r["hasPromptStats"] = True
            return True

        # Happy path
        def fake_happy(r: dict) -> bool:
            r["limits"] = mock_limits
            return True

        with (
            patch.object(agy, "fetch_local_stats", side_effect=fake_stats),
            patch.object(agy, "fetch_quota", side_effect=fake_happy),
        ):
            record = agy.collect()
            self.assertTrue(record["ready"])
            self.assertEqual(record["scope"], "device")
            self.assertEqual(record["limits"], mock_limits)
            self.assertEqual(record["todayTotalTokens"], 500)

        # CLI / auth missing: ready is True because local stats are available
        def fake_missing(r: dict) -> bool:
            agy.auth_missing(r, status="Waiting for agy", help_text="agy not found in PATH")
            return False

        with (
            tempfile.TemporaryDirectory() as empty_state_dir,
            patch("agent_usage_collectors.common.usage_dir", return_value=Path(empty_state_dir)),
            patch.object(agy, "fetch_local_stats", side_effect=fake_stats),
            patch.object(agy, "fetch_quota", side_effect=fake_missing),
        ):
            record = agy.collect()
            self.assertTrue(record["ready"])
            self.assertEqual(record["usageStatusText"], "Waiting for agy")
            self.assertEqual(record["todayTotalTokens"], 500)
            self.assertEqual(record["todayPrompts"], 2)
            self.assertEqual(record["limits"], [])

        # CLI missing without local stats: ready remains False
        def fake_no_stats(r: dict) -> bool:
            r["scope"] = "device"
            r["hasLocalStats"] = False
            r["hasPromptStats"] = False
            return False

        with (
            tempfile.TemporaryDirectory() as empty_state_dir,
            patch("agent_usage_collectors.common.usage_dir", return_value=Path(empty_state_dir)),
            patch.object(agy, "fetch_local_stats", side_effect=fake_no_stats),
            patch.object(agy, "fetch_quota", side_effect=fake_missing),
        ):
            record = agy.collect()
            self.assertFalse(record["ready"])
            self.assertEqual(record["usageStatusText"], "Waiting for agy")


def _encode_varint(value: int) -> bytes:
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def _utc_midnight_ms(days_ago: int) -> float:
    from datetime import datetime, timedelta, timezone

    midnight = datetime.now(timezone.utc).replace(hour=12, minute=0, second=0, microsecond=0) - timedelta(days=days_ago)
    return midnight.timestamp() * 1000


def _local_midday_ms(days_ago: int) -> float:
    from datetime import datetime, timedelta

    midday = datetime.now().astimezone().replace(hour=12, minute=0, second=0, microsecond=0)
    return (midday - timedelta(days=days_ago)).timestamp() * 1000


if __name__ == "__main__":
    unittest.main()
