"""The packaged RPC reader must handle coalesced app-server messages."""
import ast
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


class CodexRpcTests(unittest.TestCase):
    def test_notification_and_reply_in_one_write_do_not_timeout(self):
        script = Path(__file__).resolve().parents[1] / "bin/omarchy-agent-usage-codex-compat"
        loader = importlib.machinery.SourceFileLoader("codex_compat", str(script))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        compat = importlib.util.module_from_spec(spec)
        loader.exec_module(compat)
        source = (Path(__file__).parent / "fixtures/codex-rpc-reader.py").read_text()
        for old, new in compat.PATCHES:
            source = source.replace(old, new)
        tree = ast.parse(source)
        rpc = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "rpc_request")
        namespace = dict(json=json, os=os, select=select, time=time)
        exec(compile(ast.Module(body=[rpc], type_ignores=[]), str(script), "exec"), namespace)
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
