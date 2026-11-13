"""T3 light_no_module: the Workshop package, without the native DLL (the product most players run).
The module is made unavailable in the client realm only (no file touched): pba_native is nil, `require`
fails for "pba", file.Exists says the DLL is not there, then N.Start() runs as at map load. Asserts, on
pba_tworooms:
  - N.ready is false, N.err is "module not installed", the native menu page greys out every control that
    needs the module and says so (A.RefreshMenu)
  - a door closed then open with a sound behind it, no Lua error (the game's error channel, every realm)
  - closed door: the sound reaches the client as an engine re-emission (the Light path) with a muffling DSP
    preset in {dsp_lp1..dsp_lp4} (30, 31 by default) and a volume well under the vanilla one (1.0)
  - open door: louder than closed, and a lighter (or no) DSP preset
The simulation is undone at the end (wrappers removed, map loaded anew).

Usage: python -I light_no_module.py <mcp.py>
Measured (2026-11-13, pba_tworooms, listener 256,256, source 784,256,40 at SNDLVL 80, button14.wav, defaults):
  closed: volume 0.045, DSP 31; open: volume 0.225, DSP 30. Bounds: closed < 0.3 (the audit's), open louder, open DSP lighter.
"""
import json, os, subprocess, sys, time

TEST = os.path.dirname(os.path.abspath(__file__))
MCP = sys.argv[1]


def call(tool, args, mx=200000, timeout=300):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), str(mx)], capture_output=True,
                         text=True, encoding="utf-8", errors="replace", timeout=timeout).stdout
    try:
        return json.loads(out)
    except ValueError:
        return {"raw": out}


sys.path.insert(0, TEST)
import _cvsnap
_cvsnap.guard(call)


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


def wait_lua(realm, code, timeout=30.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if lua(realm, code) is True:
            return True
        time.sleep(0.5)
    return False


def errors_count():
    return len(call("errors_since", {"cursor": 0, "limit": 2000}).get("errors", []))


MAP = "pba_tworooms"
# the map is loaded anew: the module state is the real one, before the simulation
call("map_load", {"map": MAP, "maxplayers": 4}, timeout=300)
time.sleep(4)
if not wait_lua("client", "local N = pba.Native return N ~= nil and not N.building and (N.ready == true or N.err ~= nil)", 90):
    print("FAIL client native state never settled")
    sys.exit(1)
module_there = lua("client", "return pba.Native.ready == true")

ON = r"""
local A = pba
local N = A.Native
PBA_NM = { file_exists = file.Exists, native = pba_native, require = require, log = {}, ready = N.ready, render = N.render }
if N.ready then pcall(N.StopAllVoices) pcall(N.StopRender) end
pba_native = nil
file.Exists = function(f, p) if type(f) == "string" and f:find("gmcl_pba_", 1, true) then return false end return PBA_NM.file_exists(f, p) end
require = function(m, ...) if m == "pba" then error("module 'pba' not found (simulated)") end return PBA_NM.require(m, ...) end
-- the engine re-emissions of the Light path (A.Emit: Entity:EmitSound or EmitSound): recorded (name, volume,
-- DSP), then played as usual
PBA_NM.emit = A.Emit
A.Emit = function(fn, a1, a2, a3, a4, a5, a6, a7, a8, a9)
	local r
	if type(a1) == "string" then r = { name = a1, vol = a5, lvl = a6, dsp = a9 } -- EmitSound(name, pos, idx, chan, vol, lvl, flags, pitch, dsp)
	else r = { name = a2, vol = a5, lvl = a3, dsp = a8 } end -- ent:EmitSound(name, lvl, pitch, vol, chan, flags, dsp)
	r.t = RealTime()
	PBA_NM.log[#PBA_NM.log + 1] = r
	return PBA_NM.emit(fn, a1, a2, a3, a4, a5, a6, a7, a8, a9)
end
N.Start()
return { ready = N.ready, err = N.err, native = pba_native ~= nil, render = N.render == true }
"""
OFF = r"""
local A = pba
if PBA_NM then
	file.Exists = PBA_NM.file_exists
	require = PBA_NM.require
	A.Emit = PBA_NM.emit
	pba_native = PBA_NM.native
	PBA_NM = nil
end
return true
"""
MENU = r"""
local A = pba
local cp = vgui.Create("ControlPanel")
cp:SetWide(300)
pba.MenuBuild.native(cp)
A.RefreshMenu()
local nDeps, nGrey, nLive, bad = 0, 0, {}, {}
for _, d in ipairs(cp.apDeps or {}) do
	nDeps = nDeps + 1
	if d[1].IsEnabled and not d[1]:IsEnabled() then nGrey = nGrey + 1
	else nLive[#nLive + 1] = tostring(d[2]) .. ":" .. tostring(d[1].apTip and d[1].apTip:match("%(console: (%S-)%)") or "?") end
end
local status = IsValid(cp.apStatus) and cp.apStatus:GetText() or ""
cp:Remove()
return { deps = nDeps, grey = nGrey, live = nLive, status = status }
"""

problems = []
e0 = errors_count()
try:
    sim = lua("client", ON)
    print("simulation:", json.dumps(sim))
    if not (isinstance(sim, dict) and sim.get("ready") is False and sim.get("err") == "module not installed" and sim.get("native") is False):
        problems.append(f"module not made unavailable as simulated: {sim}")
    # menu
    time.sleep(1)
    m = lua("client", MENU)
    print("menu:", json.dumps(m))
    if not isinstance(m, dict) or m.get("deps", 0) < 40:
        problems.append(f"native menu page: too few module-dependent controls found: {m}")
    else:
        if m["grey"] != m["deps"]:
            problems.append(f"native menu page: {m['deps'] - m['grey']} of {m['deps']} controls not greyed: {m['live'][:8]}")
        if "NOT INSTALLED" not in m.get("status", ""):
            problems.append(f"native menu page: status line does not say the module is missing: {m.get('status')!r}")
    # the sounds
    res = {}
    for state in ("closed", "open"):
        call("console_exec", {"realm": "server", "cmd": f"pba_demo tworooms_{state}"})
        time.sleep(3.5)
        call("console_exec", {"realm": "server", "cmd": "pba_demo stop"})
        time.sleep(0.5)
        lua("client", "PBA_NM.log = {} return true")
        lua("server", """
            if not IsValid(PBA_NM_E) then PBA_NM_E = ents.Create("info_target") PBA_NM_E:SetPos(Vector(784, 256, 40)) PBA_NM_E:Spawn() end
            PBA_NM_E:EmitSound("buttons/button14.wav", 80, 100, 1) return true""")
        time.sleep(1.5)
        res[state] = lua("client", "return PBA_NM.log")
        print(state, json.dumps(res[state]))
    DSP = lua("client", "return { pba.cfg.dsp_lp1, pba.cfg.dsp_lp2, pba.cfg.dsp_lp3, pba.cfg.dsp_lp4 }") or []

    def first(state):
        v = res.get(state)
        return v[0] if isinstance(v, list) and v else None

    c, o = first("closed"), first("open")
    if not c:
        problems.append("closed door: no engine re-emission reached the client (the Light path played nothing)")
    else:
        if c.get("dsp") not in DSP:
            problems.append(f"closed door: DSP {c.get('dsp')} not a muffling preset {DSP}")
        if not (c.get("vol") is not None and c["vol"] < 0.3):
            problems.append(f"closed door: volume {c.get('vol')} not < 0.3 of vanilla (1.0)")
    if not o:
        problems.append("open door: no engine re-emission reached the client")
    elif c:
        if not (o.get("vol", 0) > c.get("vol", 1)):
            problems.append(f"open door not louder than closed: {o.get('vol')} vs {c.get('vol')}")
        od, cd = o.get("dsp") or 0, c.get("dsp") or 0
        if od != 0 and od >= cd:
            problems.append(f"open door DSP {od} not lighter than closed {cd}")
finally:
    # undone: wrappers removed, then the map loaded anew (a second N.Start() in the live map leaves the door
    # occlusion inverted, closed = 1 / open = 0: native_doors fails right after; see the report of 2026-11-13)
    lua("client", OFF)
    call("map_load", {"map": MAP, "maxplayers": 4}, timeout=300)
    time.sleep(4)
    wait_lua("client", "local N = pba.Native return N ~= nil and not N.building and (N.ready == true or N.err ~= nil)", 90)
    if module_there and not wait_lua("client", "return pba.Native.ready == true", 60):
        problems.append("the simulation was not undone: the module did not come back")

e1 = errors_count()
if e1 > e0:
    for e in call("errors_since", {"cursor": 0, "limit": 2000}).get("errors", [])[e0:][:5]:
        problems.append("Lua error: " + json.dumps(e)[:300])
if not module_there:
    problems.append("(note) the module is not installed on this machine: the simulation was a no-op")
print(json.dumps({"pass": not problems, "problems": problems}, indent=1))
sys.exit(0 if not problems else 1)
