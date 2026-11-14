"""T8 native_lifecycle: the native module across map changes, a disconnect / reconnect and stopsound.
Native rendering on, three map changes (pba_twodoors, pba_lcorridor, pba_tworooms), each followed by:
  - clean slate: no native voice (module Stats().voices 0, N.started empty), no loop mirror, none of the
    previous map's scene left (the module's triangle count is that of the new map, > 0), N.ready and N.render
  - alive: 10 native voices played, the reflection thread keeps running (Stats().reflRuns grows over 2.5 s,
    ~1 run/s measured) and all 10 voices are counted by the module
  - stopsound with the voices and a server loop mirror alive: 0 voices, 0 mirrors at 0.3 s and 1.5 s
then `disconnect`, back to pba_tworooms: the same checks (module loaded again by the new client state).
Memory: the private bytes of the game process after each cycle; the third cycle (second visit of a map
size already built once) must not exceed the second by more than MEM_GROW_MB (a leak per map change
shows as steady growth: 3 cycles + the reconnect are printed).
Usage: python -I -X utf8 native_lifecycle.py <mcp.py>   (Windows only: reads the process' private bytes)
"""
import ctypes
import ctypes.wintypes as wt
import json
import os
import subprocess
import sys
import time

MCP = sys.argv[1]
HERE = os.path.dirname(os.path.abspath(__file__))
MEM_GROW_MB = 70  # 5 % of the ~1.4 GB game; measured 7 to 27 MB per cycle (a small steady drift, not a leak per sound)


def call(tool, args, mx=2_000_000, timeout=400):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), str(mx)],
                         capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout).stdout
    try:
        return json.loads(out)
    except ValueError:
        return {"raw": out}


sys.path.insert(0, HERE)
import _cvsnap  # restores every pba_* setting at exit, even on failure
_cvsnap.guard(call)


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


def job(realm, code, timeout_s=60):
    r = call("lua_job", {"realm": realm, "code": code, "timeout_s": timeout_s}, timeout=timeout_s + 60)
    v = r.get("values")
    return v[0] if v else r


def cmd(realm, c):
    call("console_exec", {"realm": realm, "cmd": c})


def wait_lua(realm, code, timeout=15.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if lua(realm, code) is True:
            return True
        time.sleep(1.0)
    return False


class PMC(ctypes.Structure):
    _fields_ = [("cb", wt.DWORD), ("PageFaultCount", wt.DWORD), ("PeakWorkingSetSize", ctypes.c_size_t),
                ("WorkingSetSize", ctypes.c_size_t), ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPagedPoolUsage", ctypes.c_size_t), ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                ("QuotaNonPagedPoolUsage", ctypes.c_size_t), ("PagefileUsage", ctypes.c_size_t),
                ("PeakPagefileUsage", ctypes.c_size_t), ("PrivateUsage", ctypes.c_size_t)]


def private_mb(pid):
    k32 = ctypes.windll.kernel32
    k32.OpenProcess.restype = wt.HANDLE
    h = k32.OpenProcess(0x1000 | 0x0400, False, pid)  # QUERY_LIMITED_INFORMATION | QUERY_INFORMATION
    if not h:
        return None
    pmc = PMC()
    pmc.cb = ctypes.sizeof(pmc)
    ok = ctypes.windll.psapi.GetProcessMemoryInfo(h, ctypes.byref(pmc), pmc.cb)
    k32.CloseHandle(h)
    return round(pmc.PrivateUsage / 1048576) if ok else None


results = []


def check(name, cond, detail):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name + " :: " + detail, flush=True)


READY = "local N = pba.Native return N ~= nil and not N.building and N.ready == true and N.render == true"
# the slate right after a load: nothing of the previous map is alive
SLATE = """local N, LP = pba.Native, pba.Loops
local nm = 0 for _ in pairs(LP.mirrors) do nm = nm + 1 end
local ns = 0 for _ in pairs(N.started) do ns = ns + 1 end
local st = pba_native.Stats()
return { map = game.GetMap(), ready = N.ready, render = N.render, tris = N.tris, voices = st.voices, started = ns,
	mirrors = nm, runs = st.reflRuns, commits = st.sceneCommits, soundMB = st.soundMB, err = N.err }"""
# 10 native voices, the reflection thread watched for 2.5 s
VOICES = """local N = pba.Native
local ids = 0
for i = 1, 10 do
	if N.PlayVoice('ambient/machines/spin_loop.wav', LocalPlayer():EyePos() + Vector(100 + i * 10, 0, 0), 0.2, 0, 100) then ids = ids + 1 end
end
job:sleep(0.5)
local s0 = pba_native.Stats()
job:sleep(2.5)
local s1 = pba_native.Stats()
return { ids = ids, voices = s0.voices, runsGrow = s1.reflRuns - s0.reflRuns, errors = s1.reflErrors }"""
# stopsound with the voices alive and a mirror of a server loop (stopsound_setup.lua: its loop is mirrored)
STOP = """local LP, N = pba.Loops, pba.Native
local function mirrors() local n = 0 for _ in pairs(LP.mirrors) do n = n + 1 end return n end
job:wait(function() return mirrors() > 0 end, 6)
for i = 1, 10 do N.PlayVoice('ambient/machines/spin_loop.wav', LocalPlayer():EyePos() + Vector(100 + i * 10, 0, 0), 0.2, 0, 100) end
job:sleep(0.3)
local before = { mirrors = mirrors(), voices = pba_native.Stats().voices }
RunConsoleCommand('stopsound')
job:sleep(0.3)
local a = { mirrors = mirrors(), voices = pba_native.Stats().voices }
job:sleep(1.2)
local b = { mirrors = mirrors(), voices = pba_native.Stats().voices }
return { before = before, at03 = a, at15 = b }"""
GAME_PID = None
SETUP_SV = open(os.path.join(HERE, "stopsound_setup.lua"), encoding="utf-8").read()


def _pid():
    return call("status", {}).get("pid") or next(
        (i["pid"] for i in call("instances_list", {}).get("instances", []) if i.get("self")), None)


def visit(m, label):
    """Map m loaded (a changed map: the game rebuilds both realms), native back, then the three checks."""
    call("map_load", {"map": m, "maxplayers": 4}, timeout=300)
    time.sleep(4)
    up = wait_lua("client", READY, 150)
    time.sleep(1)
    slate = lua("client", SLATE)
    check(f"T8-{label}-slate", up and isinstance(slate, dict) and slate.get("map") == m and slate.get("tris", 0) > 0
          and slate.get("voices") == 0 and slate.get("started") == 0 and slate.get("mirrors") == 0,
          f"{m}: {slate}")
    lua("server", "local p = player.GetHumans()[1] if IsValid(p) then p:SetPos(Vector(256, 256, 0)) end return true")
    live = job("client", VOICES)
    check(f"T8-{label}-alive", isinstance(live, dict) and live.get("ids") == 10 and live.get("voices") == 10
          and live.get("runsGrow", 0) >= 1 and not live.get("errors"), f"{live} (about 1 run/s measured)")
    job("server", SETUP_SV)
    time.sleep(0.5)
    stop = job("client", STOP, 30)
    ok = isinstance(stop, dict) and stop["before"]["mirrors"] > 0 and stop["before"]["voices"] >= 10 and all(
        stop[k]["mirrors"] == 0 and stop[k]["voices"] == 0 for k in ("at03", "at15"))
    check(f"T8-{label}-stopsound", ok, f"{stop}")
    time.sleep(1)
    return private_mb(GAME_PID)


GAME_PID = _pid()  # read now: the status has no pid between two maps
cmd("client", "pba_native_render 1")
mem = []
for i, m in enumerate(("pba_twodoors", "pba_lcorridor", "pba_tworooms")):
    mem.append(visit(m, f"map{i + 1}"))
    print(f"private memory after map change {i + 1}: {mem[-1]} MB", flush=True)
cmd("menu", "disconnect")
gone = False
for _ in range(20):
    if not call("status", {}).get("map"):
        gone = True
        break
    time.sleep(1)
check("T8-disconnect", gone and call("status", {}).get("pid") is not None, "left the map, the game is still there")
time.sleep(2)
mem.append(visit("pba_tworooms", "reconnect"))
print(f"private memory after the reconnect: {mem[-1]} MB", flush=True)
grow = (mem[2] - mem[1]) if all(mem[:3]) else None
check("T8-memory", grow is not None and grow <= MEM_GROW_MB and (mem[3] - mem[2]) <= MEM_GROW_MB,
      f"private MB per cycle {mem} (3rd - 2nd = {grow}, reconnect - 3rd = {mem[3] - mem[2] if mem[3] and mem[2] else None}; bound {MEM_GROW_MB})")
print(f"{sum(results)}/{len(results)} passed")
sys.exit(0 if results and all(results) else 1)
