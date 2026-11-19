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
for f in ("sh_config.lua", "sh_bsp.lua", "sh_acoustics.lua", "sh_graph.lua", "sh_paths.lua", "sh_core.lua", "sh_whiz.lua", "sh_compat.lua", "sh_pipe.lua", "cl_probes_kernels.lua", "cl_probes.lua", "cl_slicer.lua"):
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
            # (any class of sound characters anchored at the start: "^[%^..." - a second, partial copy hid
            # behind a different character list, A.WaterMuffledFile)
            if "&~`+%%%(" in line or '"^[%^' in line:
                pat.append("%s:%d" % (rel, i))
ok_static = len(raw) == 1 and raw[0].startswith("lua/pba/sh_core.lua:") and len(pat) == 1 and pat[0].startswith("lua/pba/sh_core.lua:")
print("%s static: SoundDuration only via A.SoundDuration, prefix pattern only in A.SoundFile (raw calls %s, patterns %s)"
      % ("PASS" if ok_static else "FAIL", raw, pat))

# Static lock (offline only): no Lua file writes the global `_` (a placeholder in a multiple assignment with no
# `local _` in scope: d1, l1, _, e1 = f()). Found in the bytecode (GSET of the constant "_"), every function
# of every file; the GSET opcode is read from a probe function, not hard-coded.
gset_code = r"""
local ju, band, rshift = require("jit.util"), bit.band, bit.rshift
local function gsets(f, name, out)
	local pc = 1
	while true do
		local ins = ju.funcbc(f, pc)
		if not ins then break end
		out[#out + 1] = { op = band(ins, 0xff), d = rshift(ins, 16), pc = pc }
		pc = pc + 1
	end
	return out
end
local probe = loadstring("pba_probe_global_ = 1")
local GSET
for _, i in ipairs(gsets(probe, nil, {})) do
	if ju.funck(probe, -(i.d + 1)) == "pba_probe_global_" then GSET = i.op end
end
local hits = {}
local function scan(f, file)
	local info = ju.funcinfo(f)
	for _, i in ipairs(gsets(f, nil, {})) do
		if i.op == GSET and ju.funck(f, -(i.d + 1)) == "_" then
			local li = ju.funcinfo(f, i.pc)
			hits[#hits + 1] = file .. ":" .. tostring(li.currentline)
		end
	end
	local k = -1
	while true do
		local c = ju.funck(f, k)
		if c == nil then break end
		if type(c) == "proto" then scan(c, file) end
		k = k - 1
	end
end
local files = ...
for name, src in pairs(files) do scan(assert(loadstring(src, name)), name) end
table.sort(hits)
return tostring(GSET ~= nil), table.concat(hits, " ")
"""
srcs = {}
for root, _, names in os.walk(os.path.join(repo, "lua")):
    for n in names:
        if n.endswith(".lua"):
            pth = os.path.join(root, n)
            srcs[os.path.relpath(pth, repo).replace(os.sep, "/")] = open(pth, encoding="utf-8", errors="replace").read()
probe_ok, gset_hits = L.execute(gset_code, L.table_from(srcs))
ok_gset = probe_ok == "true" and gset_hits == ""
print("%s static: no write to the global `_` (GSET opcode found %s; writes at %s)" % ("PASS" if ok_gset else "FAIL", probe_ok, gset_hits or "none"))

# Static lock (offline only): one evaluation entry for every sound kind (refactor step 9). The client's sound
# paths (short copies at their birth, followed one-shots, loop and long mirrors, streams) compute their routes
# through P.Evaluate only (sh_paths): no direct P.Compute / Slicer.Held / Slicer.Compute in their files.
eval_calls = []
for f in ("cl_render.lua", "cl_loops.lua", "cl_streams.lua", "cl_native.lua"):
    for i, line in enumerate(srcs.get("lua/pba/" + f, "").splitlines(), 1):
        code = line.split("--", 1)[0]
        if re.search(r"(Paths|(?<![\w.])P)\.Compute\(|Slicer\.(Held|Compute)\(", code):
            eval_calls.append("%s:%d" % (f, i))
print("%s static: one evaluation entry, P.Evaluate (direct route computations in the sound paths: %s)"
      % ("PASS" if not eval_calls else "FAIL", eval_calls or "none"))

# Static lock (offline only): every option of A.CONFIG is read somewhere: `.<name>` (cfg.<name>,
# (cfg or A.cfg).<name>) or its name quoted, "pba_" prefix or not, in the code of lua/ outside sh_config.lua and
# cl_menu.lua (a menu control is not a read: an option only the menu names is dead) and outside comments;
# the low-pass tables are read by a built name (cfg["dsp_lp" .. level], "lp" .. n .. "_db").
cfg_src = open(os.path.join(repo, "lua", "pba", "sh_config.lua"), encoding="utf-8").read()
opt_names = re.findall(r"^\t(\w+)\s*=\s*\{\s*[-\d.]", cfg_src, re.M)
other_src = "\n".join(ln.split("--", 1)[0] for k, v in srcs.items()
                      if not k.endswith(("/sh_config.lua", "/cl_menu.lua")) for ln in v.splitlines())
unread = [n for n in opt_names if not re.match(r"^(dsp_lp\d|lp\d_db)$", n)
          and not re.search(r"(\.%s\b|[\"'](pba_)?%s[\"'])" % (n, n), other_src)]
print("%s static: every option is read somewhere (%d options; read nowhere: %s)"
      % ("PASS" if opt_names and not unread else "FAIL", len(opt_names), unread or "none"))

# Static lock (offline only): one option reader. An option is read through A.On(cfg, "x") / A.Num(cfg, "x")
# (sh_config.lua), whose fallback is the default declared in A.CONFIG; a fallback written at the read site
# (`(cfg or A.cfg).x or 0`, `A.cfg.x or 1`, `cfg["x"] or 2`) is forbidden in the code of lua/ (comments aside):
# 97 of them did not equal the option's default (55 were `or 0` on an option at 1), a switch upside down for any
# partial cfg. The pattern is checked against planted reads first, so the lock cannot pass by matching nothing.
FALLBACK_RE = re.compile(r"(?:(?<![\w.])cfg|(?<![\w.])(?:A|pba)\.cfg)\s*\)?\s*(?:\.\s*\w+|\[\s*[\"'][^\"']+[\"']\s*\])\s+or\s+-?\.?\d")
fb_probe = ['local a = ((cfg or A.cfg).loops or 0) >= 0.5', 'x = A.cfg.max_paths or 3', 'f(cfg.diffuse or 1)',
            'y = pba.cfg["water_db"] or 12', 'z = (cfg or pba.cfg).diff_freq or .5']
fb_clean = ['local a = A.On(cfg, "loops")', 'x = A.Num(A.cfg, "max_paths")', 'y = (r.e and v * A.cfg.native_gain) or 0',
            'local myscfg = t.cfg2 or 0']
fb_probe_ok = all(FALLBACK_RE.search(s) for s in fb_probe) and not any(FALLBACK_RE.search(s) for s in fb_clean)
fb_seen = []
for k, v in sorted(srcs.items()):
    for i, ln in enumerate(v.splitlines(), 1):
        if FALLBACK_RE.search(ln.split("--", 1)[0]):
            fb_seen.append("%s:%d" % (k.rsplit("/", 1)[-1], i))
print("%s static: options read only through A.On / A.Num, no fallback at the read site (pattern catches its probes: %s; reads with a fallback: %s)"
      % ("PASS" if fb_probe_ok and not fb_seen else "FAIL", fb_probe_ok, fb_seen or "none"))

# Static lock (offline only): the upper bound of a long sound (1800 s) is written in one place only:
# A.LongDuration (sh_core.lua).
LONG_KNOWN = {"sh_core.lua": 1}
long_seen = {}
for k, v in srcs.items():
    n = len(re.findall(r"(?<![\w.])1800(?![\w.])", v))
    if n:
        long_seen[k.rsplit("/", 1)[-1]] = n
print("%s static: the long-sound bound 1800 in one place (expected %s, found %s)"
      % ("PASS" if long_seen == LONG_KNOWN else "FAIL", LONG_KNOWN, long_seen))

# Static lock (offline only): one end-of-file rule. A file's play time at a pitch (x 100 / pitch) is
# written in A.AtPitch only (sh_core.lua); copies, mirrors and voices take their end from A.PlayEnd /
# A.PlaySeconds.
END_KNOWN = {"sh_core.lua": 1}
end_seen = {}
for k, v in srcs.items():
    n = len(re.findall(r"\*\s*100\s*/\s*math\.max\(", v))
    if n:
        end_seen[k.rsplit("/", 1)[-1]] = n
print("%s static: the end-of-file rule in one place (expected %s, found %s)"
      % ("PASS" if end_seen == END_KNOWN else "FAIL", END_KNOWN, end_seen))

# Offline lock: pba_lua_interp. A file listed in A.JIT_INTERP (sh_config.lua) runs interpreted, all its functions,
# while pba_lua_interp is 1 (its hot loops are patched to their interpreter-only form once hot, as jit.off makes them),
# and compiled again at 0 (the loop then gets a trace, as a plain function's does). Probe: a chunk that calls
# A.JitFile like a pba file, against two reference loops (one jit.off, one jit.on), all run hot.
interp_code = r"""
local ju, band = require("jit.util"), bit.band
local A = pba
-- the loop's backward jump: found while the function is fresh (FORL, its D a backward offset), read again once hot
local function loopPc(fn)
	for pc = 1, 64 do
		local ins = ju.funcbc(fn, pc)
		if not ins then return nil end
		local d = math.floor(ins / 65536)
		if d >= 32768 - 64 and d < 32768 then return pc end
	end
end
local function opAt(fn, pc) return pc and band(ju.funcbc(fn, pc), 0xff) end
local function plain() local s = 0 for i = 1, 200 do s = s + i end return s end
local function off() local s = 0 for i = 1, 200 do s = s + i end return s end
jit.off(off)
A.JIT_INTERP = A.JIT_INTERP or {}
A.JIT_INTERP.__probe = true
local f = assert(loadstring('local A = pba if A.JitFile then A.JitFile("__probe") end return function() local s = 0 for i = 1, 200 do s = s + i end return s end'))()
local function hot(fn) for _ = 1, 400 do fn() end end
local pcPlain, pcOff, pcF = loopPc(plain), loopPc(off), loopPc(f)
local saved = A.cfg.lua_interp
A.cfg.lua_interp = 1
if A.JitApplyAll then A.JitApplyAll() end
hot(plain) hot(off) hot(f)
local onOp, offOp, fOn = opAt(plain, pcPlain), opAt(off, pcOff), opAt(f, pcF)
A.cfg.lua_interp = 0
if A.JitApplyAll then A.JitApplyAll() end
hot(plain) hot(f)
local fOff = opAt(f, pcF)
A.cfg.lua_interp = saved
A.JIT_INTERP.__probe = nil
if A.jitChunks then A.jitChunks.__probe = nil end
if A.JitApplyAll then A.JitApplyAll() end
local listed = {}
for k in pairs(A.JIT_INTERP or {}) do listed[#listed + 1] = k end
table.sort(listed)
return tostring(onOp) .. " " .. tostring(offOp) .. " " .. tostring(fOn) .. " " .. tostring(fOff), (onOp ~= offOp and fOn == offOp and fOff == onOp) and "true" or "false", table.concat(listed, ",")
"""
ops, ok_interp, listed = L.execute(interp_code)
INTERP_KNOWN = "cl_mix,cl_native,cl_render,cl_renders,cl_sched,sh_acoustics,sh_bsp,sh_core,sh_doors,sh_graph,sh_paths"
print("%s offline: pba_lua_interp runs a listed file interpreted at 1, compiled at 0 (loop ops compiled/off/probe at 1/probe at 0: %s); list %s"
      % ("PASS" if ok_interp == "true" and listed == INTERP_KNOWN else "FAIL", ops, listed))

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
