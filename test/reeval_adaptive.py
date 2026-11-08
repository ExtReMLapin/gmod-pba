"""Adaptive re-evaluation of loops (pba_reeval_adaptive): a loop is re-evaluated only when something
changed. Three checks, Lua rendering (pba_native_render 0; --render=native for the module):
  1. cost, gm_construct, 20 hidden loops (perf_crowd.lua, loopsOnly), player frozen: loop work (ms/s,
     pba.perfTimers.loops) and evaluations per loop per second, with reeval_adaptive 0 then 1.
     Expected: 0 -> ~20 ms/s and 4 evaluations/s per loop (every 0.25 s); 1 -> ~5 ms/s and ~1/s (the
     reeval_max_s fallback). Thresholds fixed before the first run: adaptive 1 must give <= 8 ms/s and
     <= 1.5 evaluations/s per loop; the same thresholds must FAIL with adaptive 0 (red check).
  2. listener moved 32 u (server SetPos, player frozen): every loop re-evaluated within one
     update_interval (+ 2 frames of margin).
  3. pba_tworooms, a loop behind the closed door1, still listener: opening the door (the world version
     P.cacheGen changes on each door message) re-evaluates the loop within one interval of the first
     message, its last evaluation sees the final door state (gen equal, within one interval of the last
     message), and its level rises (>= 3 dB).
Usage: python -I -u reeval_adaptive.py <mcp.py> [--render=native] [--skip-cost]
"""
import json
import os
import subprocess
import sys
import time

MCP = sys.argv[1]
HERE = os.path.dirname(os.path.abspath(__file__))
RENDER = next((a.split("=", 1)[1] for a in sys.argv[2:] if a.startswith("--render=")), "lua")
SECS = 10.0
MARGIN = 0.05  # two frames at 40 fps
MAX_MS_PER_S, MAX_EVALS_PER_S = 8.0, 1.5


def call(tool, args, timeout=900):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), "4000000"],
                         capture_output=True, text=True, encoding="utf-8", timeout=timeout).stdout
    try:
        return json.loads(out)
    except ValueError:
        return {"raw": out[-400:]}


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


def job(realm, code, args=None, timeout_s=60):
    v = call("lua_job", {"realm": realm, "code": code, "args": args or {}, "timeout_s": timeout_s}).get("values")
    return v[0] if v else None


def cl(cmd):
    call("console_exec", {"realm": "client", "cmd": cmd})


def load(m):
    if call("status", {}).get("map") != m:
        call("map_load", {"map": m, "maxplayers": 4}, timeout=300)
        time.sleep(4)
    lua("server", "if pba.DemoMap and pba.DemoMap.SetMode then pba.DemoMap.SetMode(3) end return true")
    for _ in range(120):  # probe graph ready (first load of a map builds it)
        if lua("client", "return pba.Probes == nil or pba.Probes.current ~= nil"):
            break
        time.sleep(1)


sys.path.insert(0, HERE)
import _cvsnap  # restores every pba_* setting at exit
_cvsnap.guard(call)

fails = []
FREEZE = "local p = player.GetHumans()[1] p:Freeze(%s) p:SetVelocity(-p:GetVelocity()) return true"
cl(f"pba_native_render {1 if RENDER == 'native' else 0}")
cl("pba_update_interval 0.25")
cl("pba_reeval_move 8")
cl("pba_reeval_max_s 1")

# sum of evaluations of the mirrors (P.ReevalDue counts them in m.reeval.n)
EVALS = "local n, k = 0, 0 for _, m in pairs(pba.Loops.mirrors) do k = k + 1 n = n + (m.reeval and m.reeval.n or 0) end return { n = n, k = k }"


def cost(adaptive):
    cl(f"pba_reeval_adaptive {adaptive}")
    time.sleep(2.5)  # probe searches of the new mirrors solved, fallback rounds settled
    lua("client", "pba.ResetPerf() return true")
    e0, t0 = lua("client", EVALS), time.time()
    time.sleep(SECS)
    e1, el = lua("client", EVALS), time.time() - t0
    t = lua("client", "return pba.perfTimers.loops") or {"sum": 0, "n": 0, "max": 0}
    k = max(e1["k"], 1)
    r = {"ms_per_s": t["sum"] / el, "max_ms": t["max"], "evals_per_loop_s": (e1["n"] - e0["n"]) / k / el, "mirrors": e1["k"]}
    print(f"  reeval_adaptive {adaptive}: {r['mirrors']} mirrors, loops {r['ms_per_s']:.2f} ms/s (worst frame {r['max_ms']:.2f} ms), "
          f"{r['evals_per_loop_s']:.2f} evaluations/s per loop", flush=True)
    return r


crowd = open(os.path.join(HERE, "perf_crowd.lua"), encoding="utf-8").read()
if "--skip-cost" not in sys.argv[2:]:
    print("-- 1. cost, gm_construct, 20 hidden loops, still listener", flush=True)
    load("gm_construct")
    scene = job("server", crowd, {"n": 20, "loopsOnly": True}, 120)
    print(f"  scene: {json.dumps(scene)}", flush=True)
    lua("server", FREEZE % "true")
    off, on = cost(0), cost(1)

    def over(r):
        return r["ms_per_s"] > MAX_MS_PER_S or r["evals_per_loop_s"] > MAX_EVALS_PER_S
    if over(on):
        fails.append(f"adaptive: loops {on['ms_per_s']:.1f} ms/s (max {MAX_MS_PER_S}), {on['evals_per_loop_s']:.2f} evals/s (max {MAX_EVALS_PER_S})")
    if not over(off):
        fails.append("red check: the thresholds also pass with reeval_adaptive 0 (they do not measure the feature)")
    if on["mirrors"] < 10:
        fails.append(f"only {on['mirrors']} mirrors")

    print("-- 2. listener moved 32 u", flush=True)
    # a free direction for a 32 u step (hull of the player)
    lua("server", """local p = player.GetHumans()[1] local o = p:GetPos() PBA_STEP = nil
for _, d in ipairs({ Vector(32, 0, 0), Vector(-32, 0, 0), Vector(0, 32, 0), Vector(0, -32, 0) }) do
  local tr = util.TraceHull({ start = o + Vector(0, 0, 2), endpos = o + d + Vector(0, 0, 2), mins = p:OBBMins(), maxs = p:OBBMaxs(), filter = p })
  if not tr.Hit then PBA_STEP = d break end
end
if PBA_STEP then timer.Simple(1, function() p:SetPos(o + PBA_STEP) end) end
return PBA_STEP ~= nil""")
    moved = job("client", """local A = pba
local L0 = A.ListenerPos()
job:wait(function() local L = A.ListenerPos() return L:Distance(L0) > 16 end, 5)
-- the eye may glide to the new spot over a few frames (prediction error smoothing): the move counts
-- from the first frame it is 16 u away; each loop's first evaluation after it is timed
local tMove, first = RealTime(), {}
job:wait(function()
  local all = true
  for key, m in pairs(A.Loops.mirrors) do
    local r = m.reeval
    if r and r.t then
      if not first[key] and r.t >= tMove then first[key] = r.t - tMove end
      if not first[key] then all = false end
    end
  end
  return all
end, 3)
job:sleep(1)
local worst, late, stale, L1 = 0, 0, 0, A.ListenerPos()
for key, m in pairs(A.Loops.mirrors) do
  local r = m.reeval
  if r and r.t then
    if first[key] then worst = math.max(worst, first[key]) else late = late + 1 end
    -- the settled position was taken into account (within reeval_move)
    local d = Vector(r.lx, r.ly, r.lz):Distance(L1)
    if d > A.cfg.reeval_move + 0.5 then stale = stale + 1 end
  end
end
return { moved = L1:Distance(L0), worst = worst, notDone = late, stale = stale, interval = A.cfg.update_interval }""", None, 30)
    print(f"  {json.dumps(moved)}", flush=True)
    if not moved or moved.get("notDone", 1) > 0 or moved.get("stale", 1) > 0 or moved["worst"] > moved["interval"] + MARGIN:
        fails.append(f"listener move: {json.dumps(moved)} (every loop within {0.25 + MARGIN} s)")
    lua("server", FREEZE % "false")
    job("server", crowd, {"stop": True}, 30)

print("-- 3. door opened on the path, pba_tworooms", flush=True)
load("pba_tworooms")
cl("pba_reeval_adaptive 1")
idx = lua("server", """local p = player.GetHumans()[1]
p:SetPos(Vector(256, 256, 0)) p:SetEyeAngles(Angle(0, 0, 0)) p:Freeze(true)
for _, d in ipairs(ents.FindByName("door1")) do d:Fire("Close") end
if IsValid(PBA_RE_SRC) then PBA_RE_SRC:Remove() end
local e = ents.Create("prop_physics")
e:SetModel("models/props_junk/PopCan01a.mdl") e:SetPos(Vector(784, 256, 40)) e:Spawn()
local ph = e:GetPhysicsObject() if IsValid(ph) then ph:EnableMotion(false) end
e:SetNoDraw(true)
PBA_RE_SRC = e
timer.Simple(0.3, function() if IsValid(e) then PBA_RE_SND = CreateSound(e, "ambient/machines/combine_terminal_loop1.wav") PBA_RE_SND:Play() end end)
return e:EntIndex()""")
time.sleep(3)
lua("server", "timer.Simple(1, function() for _, d in ipairs(ents.FindByName('door1')) do d:Fire('SetRotationDistance', '90') d:Fire('Open') end end) return true")
door = job("client", """local A, P = pba, pba.Paths
local function mirror() for _, m in pairs(A.Loops.mirrors) do if m.ent == Entity(job.args.idx) then return m end end end
local m = mirror()
if not m or not m.reeval then return { err = "no mirror" } end
local gClosed, gen0 = m.g or 1, P.cacheGen
job:wait(function() return P.cacheGen ~= gen0 end, 5)
if P.cacheGen == gen0 then return { err = "no door message" } end
local tFirst = RealTime()
job:wait(function() return m.reeval.t >= tFirst and m.reeval.gen ~= gen0 end, 2)
local first = m.reeval.t - tFirst
-- door moving: messages every 0.1 s; settled once the version is still for 1 s. `after`: the first
-- evaluation that saw the last version, timed from that version's arrival
local gen, tLast, after = P.cacheGen, tFirst, nil
job:wait(function()
  if P.cacheGen ~= gen then gen, tLast, after = P.cacheGen, RealTime(), nil end
  if not after and m.reeval.gen == gen and m.reeval.t >= tLast then after = m.reeval.t - tLast end
  return RealTime() - tLast > 1
end, 10)
return { first = first, finalGenOk = after ~= nil, lastAfter = after or -1,
  closedDb = 20 * math.log10(math.max(gClosed, 1e-6)), openDb = 20 * math.log10(math.max(m.g or 1, 1e-6)),
  bumps = P.cacheGen - gen0, interval = A.cfg.update_interval }""", {"idx": idx}, 40)
print(f"  {json.dumps(door)}", flush=True)
if not door or door.get("err"):
    fails.append(f"door: {json.dumps(door)}")
else:
    if door["first"] > door["interval"] + MARGIN:
        fails.append(f"door: first re-evaluation {door['first']:.3f} s after the first door message")
    if not door["finalGenOk"] or door["lastAfter"] < 0 or door["lastAfter"] > door["interval"] + MARGIN:
        fails.append(f"door: final state not evaluated in time ({json.dumps(door)})")
    if door["openDb"] - door["closedDb"] < 3:
        fails.append(f"door: level {door['closedDb']:.1f} -> {door['openDb']:.1f} dB, expected +3 dB at least")
lua("server", "if PBA_RE_SND then PBA_RE_SND:Stop() end if IsValid(PBA_RE_SRC) then PBA_RE_SRC:Remove() end "
    "player.GetHumans()[1]:Freeze(false) return true")
print("FAIL: " + "; ".join(fails) if fails else "PASS", flush=True)
sys.exit(1 if fails else 0)
