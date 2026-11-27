"""Claude's saved free resets, read alongside Omarchy's usage request."""
import datetime as dt
import importlib.machinery
import importlib.util
import json
import os
import tempfile
import unittest
import urllib.request
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "bin/omarchy-agent-usage-claude-compat"
loader = importlib.machinery.SourceFileLoader("claude_compat", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
compat = importlib.util.module_from_spec(spec)
loader.exec_module(compat)

NOW = dt.datetime(2026, 11, 26, 12, 0, tzinfo=dt.timezone.utc)
ENDPOINT = "https://api.anthropic.com/api/oauth/usage"


def grant(left=1, ends="2026-12-10T22:00:00Z", **extra):
    entry = {"id": "secret-handle", "label": "promo", "resets_left": left, "resets_total": max(left, 1),
             "paused": False, "ends_at": ends}
    entry.update(extra)
    return entry


class HttpError(Exception):
    def __init__(self, status, body=b""):
        super().__init__(f"HTTP {status}")
        self.status = status
        self.body = body


class ResetExpiryTests(unittest.TestCase):
    def test_counts_available_resets_and_keeps_only_expiries(self):
        block = {"eligible": True, "grants": [
            grant(2, "2026-12-10T22:00:00Z"),
            grant(1, None),
            grant(1, paused=True),
            grant(1, "2026-11-01T00:00:00Z"),
            grant(1, starts_at="2026-12-01T00:00:00Z"),
            grant(0),
            grant(1, "not a date"),
            {"resets_left": True, "paused": False},
            "not a grant",
        ]}
        expiries = compat.reset_expiries(block, NOW)
        self.assertEqual(sorted(expiries), ["", "2026-12-10T22:00:00+00:00", "2026-12-10T22:00:00+00:00"])
        self.assertNotIn("secret", json.dumps(expiries))
        self.assertEqual(compat.summary(expiries, NOW), {
            "available": 3, "nextExpiresAt": "2026-12-10T22:00:00+00:00",
            "expiries": ["2026-12-10T22:00:00+00:00", "2026-12-10T22:00:00+00:00", ""],
        })

    def test_ineligible_absent_or_oversized_blocks_say_nothing(self):
        for block in (None, "x", {"eligible": False, "grants": [grant()]},
                      {"eligible": True, "grants": [grant()] * 201},
                      {"eligible": True, "grants": [grant(51)]}):
            self.assertIsNone(compat.reset_expiries(block, NOW))
        self.assertEqual(compat.reset_expiries({"eligible": True, "grants": "x"}, NOW), [])
        self.assertIsNone(compat.summary([], NOW))

    def test_a_reset_that_expired_since_the_probe_drops_out(self):
        expiries = ["2026-11-26T13:00:00+00:00", ""]
        later = NOW + dt.timedelta(hours=2)
        self.assertEqual(compat.summary(expiries, later), {"available": 1, "nextExpiresAt": "", "expiries": [""]})


class TrackerTests(unittest.TestCase):
    def setUp(self):
        self.cache = tempfile.TemporaryDirectory()
        patcher = mock.patch.dict(os.environ, {"XDG_CACHE_HOME": self.cache.name, "CLAUDE_CONFIG_DIR": "/tmp/claude-a"})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.cache.cleanup)
        self.requests = []
        self.emitted = []

    def namespace(self, respond):
        def open_json(request, timeout=10):
            self.requests.append(request)
            return respond(request)
        return {"USAGE_ENDPOINT": ENDPOINT, "open_json": open_json, "HttpError": HttpError,
                "emit": lambda record, sort_keys=False: self.emitted.append(record)}

    def probe(self, namespace, token="token-a"):
        request = urllib.request.Request(ENDPOINT, headers={"Authorization": "Bearer " + token, "anthropic-beta": "oauth-2025-04-20"})
        return namespace["open_json"](request, timeout=10)

    def test_opts_in_and_adds_reset_credits_to_the_record(self):
        ns = self.namespace(lambda r: {"five_hour": {"utilization": 3}, "cedar_ember": {"eligible": True, "grants": [grant(1)]}})
        compat.Tracker(ns, now=NOW, version="2.1.332").install()
        payload = self.probe(ns)
        self.assertEqual(payload["five_hour"]["utilization"], 3)
        sent = self.requests[0]
        self.assertEqual(sent.full_url, ENDPOINT + "?cedar_ember=1")
        self.assertEqual(sent.get_header("Authorization"), "Bearer token-a")
        self.assertEqual(sent.get_header("User-agent"), "claude-cli/2.1.332 (external, cli)")
        ns["emit"]({"id": "claude", "limits": []})
        self.assertEqual(self.emitted[0]["resetCredits"], {
            "available": 1, "nextExpiresAt": "2026-12-10T22:00:00+00:00",
            "expiries": ["2026-12-10T22:00:00+00:00"],
        })
        stored = Path(compat.cache_path()).read_text()
        self.assertNotIn("secret", stored)
        self.assertNotIn("token", stored)

    def test_a_rejected_opt_in_retries_the_original_request(self):
        def respond(request):
            if "cedar_ember" in request.full_url:
                raise HttpError(400)
            return {"five_hour": {"utilization": 9}}
        ns = self.namespace(respond)
        compat.Tracker(ns, now=NOW, version="2.1.0").install()
        self.assertEqual(self.probe(ns)["five_hour"]["utilization"], 9)
        self.assertEqual([r.full_url for r in self.requests], [ENDPOINT + "?cedar_ember=1", ENDPOINT])
        ns["emit"]({"id": "claude"})
        self.assertNotIn("resetCredits", self.emitted[0])

    def test_auth_and_rate_limit_errors_are_not_retried(self):
        for error in (HttpError(429), HttpError(401), HttpError(403, b'{"error":"missing user:profile scope"}')):
            self.requests.clear()
            def respond(request, error=error):
                raise error
            ns = self.namespace(respond)
            compat.Tracker(ns, now=NOW, version="2.1.0").install()
            with self.assertRaises(HttpError):
                self.probe(ns)
            self.assertEqual(len(self.requests), 1)

    def test_a_run_without_a_probe_reuses_the_cached_resets(self):
        ns = self.namespace(lambda r: {"cedar_ember": {"eligible": True, "grants": [grant(2)]}})
        compat.Tracker(ns, now=NOW, version="2.1.0").install()
        self.probe(ns)
        ns["emit"]({"id": "claude"})
        reused = self.namespace(lambda r: {})
        compat.Tracker(reused, now=NOW, version="2.1.0").install()
        reused["emit"]({"id": "claude"})
        self.assertEqual(self.emitted[-1]["resetCredits"]["available"], 2)
        after_expiry = self.namespace(lambda r: {})
        compat.Tracker(after_expiry, now=NOW + dt.timedelta(days=30), version="2.1.0").install()
        after_expiry["emit"]({"id": "claude"})
        self.assertNotIn("resetCredits", self.emitted[-1])

    def test_several_logins_in_one_run_show_none(self):
        ns = self.namespace(lambda r: {"cedar_ember": {"eligible": True, "grants": [grant(1)]}})
        compat.Tracker(ns, now=NOW, version="2.1.0").install()
        self.probe(ns, "token-a")
        self.probe(ns, "token-b")
        ns["emit"]({"id": "claude"})
        self.assertNotIn("resetCredits", self.emitted[0])

    def test_native_accounts_keep_their_own_resets_even_on_cache_hits(self):
        ns = self.namespace(lambda r: {"cedar_ember": {"eligible": True, "grants": [
            grant(2 if r.get_header("Authorization") == "Bearer work" else 1),
        ]}})
        def collect_limits(token, expires_at, refresh_expires_at, force, cache_name="claude-limits.json"):
            if force:
                self.probe(ns, token)
            return {"live": bool(token)}

        def account_entry(account, limits, plan, **extra):
            return dict(account, **extra)

        original_open, original_emit = ns["open_json"], ns["emit"]
        for fresh in (True, False):
            # Omarchy lists the active account first, so the last probe is
            # not necessarily the one that the top-level record describes.
            ns.update(collect_limits=collect_limits, account_entry=account_entry)
            ns["open_json"] = original_open
            ns["emit"] = original_emit
            compat.Tracker(ns, now=NOW, version="2.1.0").install()
            accounts = []
            for token in ("work", "personal"):
                limits = ns["collect_limits"](token, 0, 0, fresh, "claude-limits-" + token + ".json")
                accounts.append(ns["account_entry"]({"active": token == "work"}, limits, "Max"))
            ns["emit"]({"id": "claude", "accounts": accounts})
            self.assertEqual(self.emitted[-1]["resetCredits"]["available"], 2)
            self.assertEqual([a["resetCredits"]["available"] for a in accounts], [2, 1])

    def test_other_requests_pass_through_untouched(self):
        ns = self.namespace(lambda r: {"ok": True})
        compat.Tracker(ns, now=NOW, version="2.1.0").install()
        other = urllib.request.Request("https://api.anthropic.com/api/oauth/profile")
        self.assertEqual(ns["open_json"](other), {"ok": True})
        self.assertEqual(self.requests[0].full_url, "https://api.anthropic.com/api/oauth/profile")


class BaseResolutionTests(unittest.TestCase):
    def test_skips_this_plugins_own_links(self):
        with tempfile.TemporaryDirectory() as root:
            looped = Path(root) / "omarchy-agent-usage-claude"
            looped.symlink_to(SCRIPT.with_name("omarchy-agent-usage-claude-cost"))
            real = Path(root) / "real-collector"
            real.write_text("print('{}')\n")
            with mock.patch.object(compat, "base_candidates", return_value=[looped, real]):
                self.assertEqual(compat.resolve_base(), real)
            with mock.patch.object(compat, "base_candidates", return_value=[looped]):
                self.assertIsNone(compat.resolve_base())


if __name__ == "__main__":
    unittest.main()
