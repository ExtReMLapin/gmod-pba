"""Runs pba's GLuaTest pure suite outside the game (LuaJIT 2.1 via lupa + a small GMod shim).
Offline check only: the in-game suite (run_battery.py) stays the reference.
Needs `pip install lupa` (or a local copy in test/offline/pylib). Agents use it to prepare code and pure
tests without the game, in parallel; the in-game suite stays the reference before a merge.
Usage: python -I test/offline/run_pure.py [repo] [extra.lua]   (repo defaults to this checkout; extra.lua
       runs after the suites, with the repo path as `...`, e.g. test/offline/oneshot_follow_sim.lua)
Then the native helpers' suite (test/gluatest/pba_pure_native_test.lua): cl_native.lua is loaded after the
first suite and the static lock (a timer.Remove stub is all the shim lacks for it), so the first suite
runs exactly as before."""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "pylib"))
from lupa import luajit21 as lj  # noqa: E402

repo = sys.argv[1] if len(sys.argv) > 1 else os.path.abspath(os.path.join(HERE, "..", ".."))
L = lj.LuaRuntime(unpack_returned_tuples=True)
L.execute(open(os.path.join(HERE, "gmshim.lua"), encoding="utf-8").read())
L.execute("PBA_OFFLINE = true")  # dumps compared bit for bit (17 digits) outside the game
for f in ("sh_config.lua", "sh_bsp.lua", "sh_acoustics.lua", "sh_graph.lua", "sh_paths.lua", "sh_core.lua", "cl_probes_kernels.lua", "cl_probes.lua", "cl_slicer.lua"):
    src = open(os.path.join(repo, "lua", "pba", f), encoding="utf-8").read()
    L.execute(src)
runner = r"""
local src = ...
local function expect(v)
	return { to = { beTrue = function() if v ~= true then error("expected true, got " .. tostring(v), 2) end end,
		beNil = function() if v ~= nil then error("expected nil, got " .. tostring(v), 2) end end,
		equal = function(o) if v ~= o then error("expected " .. tostring(o) .. ", got " .. tostring(v), 2) end end } }
end
local fn = assert(loadstring(src, "pba_pure_test"))
setfenv(fn, setmetatable({ expect = expect }, { __index = _G }))
local suite = fn()
local ok, out = 0, {}
for _, c in ipairs(suite.cases) do
	local s, e = pcall(c.func)
	if s then ok = ok + 1 out[#out + 1] = "PASS " .. c.name else out[#out + 1] = "FAIL " .. c.name .. ": " .. tostring(e) end
end
out[#out + 1] = ok .. "/" .. #suite.cases .. " passed"
return table.concat(out, "\n")
"""
src = open(os.path.join(repo, "test", "gluatest", "pba_pure_test.lua"), encoding="utf-8").read()
print(L.execute(runner, src))

# Static lock (offline only): one model for a sound's file name. SoundDuration is called only by
# A.SoundDuration, and the sound-character pattern exists only in A.SoundFile (sh_core.lua).
import re  # noqa: E402
raw, pat = [], []
for root, _, names in os.walk(os.path.join(repo, "lua")):
    for n in names:
        if not n.endswith(".lua"):
            continue
        path = os.path.join(root, n)
        rel = os.path.relpath(path, repo).replace(os.sep, "/")
        for i, line in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
            if re.search(r"(?<![\w.])SoundDuration\(", line):
                raw.append("%s:%d" % (rel, i))
            if "&~`+%%%(" in line:
                pat.append("%s:%d" % (rel, i))
ok_static = len(raw) == 1 and raw[0].startswith("lua/pba/sh_core.lua:") and len(pat) == 1 and pat[0].startswith("lua/pba/sh_core.lua:")
print("%s static: SoundDuration only via A.SoundDuration, prefix pattern only in A.SoundFile (raw calls %s, patterns %s)"
      % ("PASS" if ok_static else "FAIL", raw, pat))

# The native helpers (cl_native.lua: distance law, sends, directivity, EQ) and their suite. Loaded last:
# the suite above runs without pba.Native, as before.
L.execute("timer.Remove = timer.Remove or function() end")
L.execute(open(os.path.join(repo, "lua", "pba", "cl_native.lua"), encoding="utf-8").read())
src_native = open(os.path.join(repo, "test", "gluatest", "pba_pure_native_test.lua"), encoding="utf-8").read()
print(L.execute(runner.replace('"pba_pure_test"', '"pba_pure_native_test"'), src_native))

# The native module update check (cl_update.lua): network, cookies and the module are stubbed by the suite.
upd = os.path.join(repo, "lua", "pba", "cl_update.lua")
if os.path.exists(upd):
    L.execute(open(upd, encoding="utf-8").read())
src_update = open(os.path.join(repo, "test", "gluatest", "pba_pure_update_test.lua"), encoding="utf-8").read()
print(L.execute(runner.replace('"pba_pure_test"', '"pba_pure_update_test"'), src_update))
if len(sys.argv) > 2:
    print(L.execute(open(sys.argv[2], encoding="utf-8").read(), repo))  # the repo path as `...`
