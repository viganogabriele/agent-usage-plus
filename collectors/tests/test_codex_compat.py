"""The packaged RPC reader must handle coalesced app-server messages."""
import ast
from datetime import datetime, timezone
import importlib.machinery
import importlib.util
import json
import os
import select
import subprocess
import sys
import time
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "bin/omarchy-agent-usage-codex-compat"
loader = importlib.machinery.SourceFileLoader("codex_compat", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
compat = importlib.util.module_from_spec(spec)
loader.exec_module(compat)


class CodexRpcTests(unittest.TestCase):
    def test_all_available_reset_expiries_are_preserved(self):
        now = datetime(2026, 11, 27, tzinfo=timezone.utc)
        first = "2026-11-28T00:00:00+00:00"
        later = "2026-12-10T00:00:00+00:00"
        def credit(expiry, status="available"):
            return {"status": status, "expiresAt": expiry, "id": "private"}

        credits = compat.reset_credits({"rateLimitResetCredits": {"credits": [
            credit(datetime.fromisoformat(later).timestamp()),
            credit(datetime.fromisoformat(first).timestamp()),
            credit(datetime.fromisoformat(first).timestamp()),
            credit(now.timestamp()),
            credit(datetime.fromisoformat(later).timestamp(), "redeemed"),
            credit(None),
            credit({}),
            credit(10**100),
        ]}}, now)
        self.assertEqual(credits, {
            "available": 6, "nextExpiresAt": first, "expiries": [first, first, later, "", "", ""],
        })
        self.assertIsNone(compat.reset_credits({"rateLimitResetCredits": {"credits": [credit(now.timestamp())]}}, now))
        self.assertIsNone(compat.reset_credits({"rateLimitResetCredits": {"credits": "invalid"}}, now))

    def test_notification_and_reply_in_one_write_do_not_timeout(self):
        source = (Path(__file__).parent / "fixtures/codex-rpc-reader.py").read_text()
        for old, new in compat.PATCHES:
            source = source.replace(old, new)
        tree = ast.parse(source)
        rpc = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "rpc_request")
        namespace = dict(json=json, os=os, select=select, time=time)
        exec(compile(ast.Module(body=[rpc], type_ignores=[]), str(SCRIPT), "exec"), namespace)
        # Two lines arrive together. TextIOWrapper.readline() prefetches both;
        # selecting the fd before reading the second line then times out.
        server = "import sys,time; sys.stdin.readline(); sys.stdout.write('{\"method\":\"notice\"}\\n{\"id\":2,\"result\":{\"account\":{\"planType\":\"pro\"}}}\\n'); sys.stdout.flush(); time.sleep(2)"
        with subprocess.Popen([sys.executable, "-c", server], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, text=True) as proc:
            try:
                reply = namespace["rpc_request"](proc, 2, "account/read", timeout=.3)
                self.assertEqual(reply["result"]["account"]["planType"], "pro")
            finally:
                proc.terminate()
                proc.wait()
