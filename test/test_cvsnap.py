"""Pure test of _cvsnap: settings changed by a test that was KILLED (no atexit) are put back by the
next guard(). No game needed: a fake mcp call() keeps the convars in a JSON file.
Usage: python -I test_cvsnap.py [ignored args]  (the battery passes the mcp.py path)
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import _cvsnap  # noqa: E402

CHILD = r"""
import json, os, sys
sys.path.insert(0, sys.argv[1])
import _cvsnap
_cvsnap.JOURNAL_DIR = sys.argv[3]
from test_cvsnap import FakeGame
call = FakeGame(sys.argv[2])
_cvsnap.guard(call)
call("console_exec", {"realm": "client", "cmd": "pba_cl_enable 0"})
call("console_exec", {"realm": "client", "cmd": "pba_native_render 0"})
os._exit(1)  # killed: atexit handlers do not run
"""


class FakeGame:
    """call(tool, args) of a game whose pba_* convars live in a JSON file."""
    def __init__(self, path):
        self.path = path

    def _load(self):
        with open(self.path, encoding="utf-8") as f:
            return json.load(f)

    def __call__(self, tool, args):
        state = self._load()
        realm = args.get("realm")
        if tool == "lua_exec":
            return {"values": [dict(state[realm])]}
        if tool == "console_exec":
            name, v = args["cmd"].split(" ", 1)
            state[realm][name[len("pba_"):]] = v
            with open(self.path, "w", encoding="utf-8") as f:
                json.dump(state, f)
            return {}
        raise ValueError(tool)


class KilledTest(unittest.TestCase):
    def test_killed_guard_restored_by_next(self):
        with tempfile.TemporaryDirectory() as d:
            game = os.path.join(d, "game.json")
            jdir = os.path.join(d, "journal")
            with open(game, "w", encoding="utf-8") as f:
                json.dump({"client": {"cl_enable": "1", "native_render": "1"}, "server": {"enable": "1"}}, f)
            subprocess.run([sys.executable, "-I", "-c", CHILD, HERE, game, jdir], check=False)
            call = FakeGame(game)
            self.assertEqual(call._load()["client"]["cl_enable"], "0", "the killed child did change the setting")
            old = getattr(_cvsnap, "JOURNAL_DIR", None)
            _cvsnap.JOURNAL_DIR = jdir
            try:
                snap = _cvsnap.guard(call)
                getattr(_cvsnap, "release", _cvsnap.restore)(call, snap)
            finally:
                _cvsnap.JOURNAL_DIR = old
            self.assertEqual(call._load()["client"], {"cl_enable": "1", "native_render": "1"})
            self.assertEqual(os.listdir(jdir) if os.path.isdir(jdir) else [], [])


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]], verbosity=1)
