"""Pure test (no game): test/mcp.py's output reaches its Python callers whatever the Windows code page.
A failed call (here: a refused connection) prints a traceback whose system message is localized (French
Windows: "l'ordinateur cible l'a expressément refusée", 0x92 / 0xe9 in cp1252): mcp.py must write stderr in
UTF-8 like stdout, its callers decode with errors="replace", and sweep.py must not read a failed errors_since
as "no error" (6 maps of the 2026-11-14 sweep lost their Lua errors this way).
Usage: python -I test_mcp_encoding.py [ignored args]  (the battery passes the mcp.py path)
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
MCP = os.path.join(HERE, "mcp.py")


def dead_config(d):
    p = os.path.join(d, "claude.json")
    with open(p, "w", encoding="utf-8") as f:
        json.dump({"projects": {"D:/SteamLibrary/steamapps/common/GarrysMod": {"mcpServers": {"gmod": {
            "url": "http://127.0.0.1:9/mcp"}}}}}, f)  # (port 9: nothing listens, connection refused)
    return p


class McpEncoding(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.env = dict(os.environ, CLAUDE_JSON=dead_config(self.tmp), MCP_PROJECT="D:/SteamLibrary/steamapps/common/GarrysMod")
        self.env.pop("PYTHONIOENCODING", None)
        self.env.pop("PYTHONUTF8", None)

    def test_stderr_is_utf8(self):
        r = subprocess.run([sys.executable, "-I", MCP, "call", "status", "{}"], capture_output=True, env=self.env, timeout=60)
        self.assertNotEqual(r.returncode, 0)
        r.stderr.decode("utf-8")  # strict: raises on a cp1252 byte
        r.stdout.decode("utf-8")

    def test_sweep_errors_since_failure_is_visible(self):
        os.environ["CLAUDE_JSON"] = self.env["CLAUDE_JSON"]
        os.environ["MCP_PROJECT"] = self.env["MCP_PROJECT"]
        argv = sys.argv
        sys.argv = ["sweep.py", MCP, "none_map"]
        try:
            sys.path.insert(0, os.path.join(HERE, "watch"))
            import sweep
        finally:
            sys.argv = argv
        errs, failed = sweep.errors_since(0, 10)
        self.assertEqual(errs, [])
        self.assertTrue(failed, "a failed errors_since call must be reported, not read as an empty list")


if __name__ == "__main__":
    r = unittest.main(argv=[sys.argv[0]], exit=False, verbosity=1).result
    print("PASS" if r.wasSuccessful() else "FAIL")
    sys.exit(0 if r.wasSuccessful() else 1)
