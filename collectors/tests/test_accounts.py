"""Account records remain isolated without touching real CLI credentials."""
import importlib.machinery
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "bin/agent-usage-plus-accounts"
loader = importlib.machinery.SourceFileLoader("accounts_runner", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
accounts = importlib.util.module_from_spec(spec)
loader.exec_module(accounts)


class AccountCollectorTests(unittest.TestCase):
    def test_profiles_only_accept_safe_matching_account_ids(self):
        parsed = accounts.profiles_from_json(json.dumps({
            "claude-work": {"provider": "claude", "name": "Claude · Work"},
            "codex-private": {"provider": "claude", "name": "Wrong provider"},
            "claude-../oops": {"provider": "claude", "name": "Bad path"},
        }))
        self.assertEqual(parsed, {"claude-work": {"provider": "claude", "name": "Claude · Work"}})

    def test_collector_uses_native_profile_and_isolated_scan_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            with patch.dict(os.environ, {"XDG_DATA_HOME": temporary, "ANTHROPIC_API_KEY": "dummy"}):
                environment = accounts.collector_environment("claude-work", "claude")
                self.assertEqual(environment["CLAUDE_CONFIG_DIR"], str(Path(temporary) / "agent-usage-plus-accounts/claude-work/claude"))
                self.assertNotEqual(environment["HOME"], os.environ.get("HOME"))
                self.assertTrue(environment["XDG_CACHE_HOME"].startswith(temporary))
                self.assertNotIn("ANTHROPIC_API_KEY", environment)
                environment = accounts.collector_environment("codex-work", "codex")
                config = Path(environment["CODEX_HOME"]) / "config.toml"
                self.assertEqual(config.read_text(), 'cli_auth_credentials_store = "file"\n')

    def test_rewrites_only_public_record_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = json.dumps({"id": "claude", "name": "Claude Code", "limits": [{"percent": .4}]})
            def emit_record(_command, **kwargs):
                kwargs["stdout"].write(output.encode())
            with patch.dict(os.environ, {"XDG_DATA_HOME": temporary}), patch.object(accounts.subprocess, "run", side_effect=emit_record):
                record = accounts.collect("claude-work", {"provider": "claude", "name": "Work"}, [])
            self.assertEqual(record["id"], "claude-work")
            self.assertEqual(record["name"], "Claude · Work")
            self.assertEqual(record["brand"], "claude")
            self.assertEqual(record["limits"], [{"percent": .4}])

    def test_removal_only_deletes_records_owned_by_account_runner(self):
        with tempfile.TemporaryDirectory() as temporary:
            with patch.dict(os.environ, {"XDG_STATE_HOME": temporary}):
                directory = accounts.usage_dir()
                directory.mkdir(parents=True)
                owned = directory / "claude-old.json"
                owned.write_text(json.dumps({"id": "claude-old", "managedBy": "agent-usage-plus-accounts"}))
                other = directory / "claude-other.json"
                other.write_text(json.dumps({"id": "claude-other"}))
                accounts.remove_unconfigured_records({})
                self.assertFalse(owned.exists())
                self.assertTrue(other.exists())


if __name__ == "__main__":
    unittest.main()
