"""Moving-listener scenarios: the player walks, runs, flies or teleports while sounds play, from simple
to complex, and the client records what PBA costs frame by frame and what it answers per source.
Written for the far-sound slicing (pba_far_sliced) and kept as a general guard: whatever schedules the
path evaluations, the player must not feel a hitch and no source may go stale or jump.

Per scenario (client side, timed outside the MCP debug hook, from hooks and timers):
  - frames: count, frame time median / p99 / max, hitches (frame time > 2 x median);
  - pba cost per frame: time inside A.Paths.Compute summed per frame (max, p99, frames over 5 ms), plus
    the time of A.Paths.SliceStep / A.Probes.AdvanceFar when such a slicer exists (any of the names in
    SLICERS below, wrapped if present);
  - per source (keyed by its rounded position): evaluations, longest wait between two evaluations,
    the physical delay d / c, the largest level step between consecutive evaluations while the listener
    moved <= 32 u (voices' power relative to the free field, as door_sweep_real).
Report only for now (no thresholds: the baseline before pba_far_sliced is the reference). Intended pass
rules once the slicer is in: pba cost per frame <= probe_field_ms + 2 ms, no wait longer than the physical
delay + the re-evaluation interval + 0.1 s, steps <= 3 dB for loops while walking.

Usage: python -I -u move_scenarios.py <mcp.py> [scenario ...]   (all when none given)
"""
import json
import os
import subprocess
import sys
import time

MCP = sys.argv[1]
ONLY = [a for a in sys.argv[2:] if not a.startswith("--")]
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import _cvsnap  # noqa: E402  restores every pba_* setting at exit


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


_cvsnap.guard(call)

LOOPS = ["ambient/machines/combine_terminal_loop1.wav", "ambient/fire/fire_med_loop1.wav",
         "ambient/water/water_flow_loop1.wav", "ambient/levels/labs/machine_ring_resonance_loop1.wav"]
SHOT = "weapons/smg1/smg1_fire1.wav"

# path: list of feet positions; speed in u/s (0 = teleport between consecutive points, each held `hold` s)
# sources: {pos, kind = loop|shot, lvl, period (shots), move = {to, speed} (moving source)}
SCENARIOS = [
    {"name": "open_walk", "doc": "simple: open ground, one far loop in clear sight, walk 800 u",
     "map": "gm_flatgrass", "path": [(0, 0, -12288), (800, 0, -12288)], "speed": 200,
     "sources": [{"pos": (3000, 300, -12240), "kind": "loop", "lvl": 90}]},
    {"name": "doorway_walk", "doc": "simple: walk from room A through the open door into room B, a loop in B",
     "map": "pba_tworooms", "doors": {"door1": "open"},
     "path": [(200, 256, 0), (700, 256, 0)], "speed": 150,
     "sources": [{"pos": (900, 380, 40), "kind": "loop", "lvl": 80}]},
    {"name": "door_opens_walking", "doc": "medium: walking toward a shut door that opens on the way",
     "map": "pba_tworooms", "doors": {"door1": "close"}, "events": [(1.0, "server", "for _, d in ipairs(ents.FindByName('door1')) do d:Fire('Open') end")],
     "path": [(150, 256, 0), (450, 256, 0)], "speed": 100,
     "sources": [{"pos": (784, 256, 40), "kind": "loop", "lvl": 80}]},
    {"name": "downtown_walk", "doc": "medium: rp_downtown street walk, three far loops behind buildings",
     "map": "rp_downtown_v4c_v2", "path": [(-185, -720, -6), (-185, 200, -6)], "speed": 200,
     "sources": [{"pos": (-1797.25, -418.8, -147), "kind": "loop", "lvl": 85},
                 {"pos": (-2149.3, -6898.2, -59.6), "kind": "loop", "lvl": 85},
                 {"pos": (900, 600, 40), "kind": "loop", "lvl": 85}]},
    {"name": "downtown_sprint", "doc": "complex: sprint 400 u/s through many probe zones, far loops and far gunfire",
     "map": "rp_downtown_v4c_v2", "path": [(-185, -720, -6), (-185, 200, -6), (-185, -720, -6)], "speed": 400,
     "sources": [{"pos": (-1797.25, -418.8, -147), "kind": "loop", "lvl": 85},
                 {"pos": (900, 600, 40), "kind": "loop", "lvl": 85},
                 {"pos": (-1500, 900, 40), "kind": "shot", "lvl": 140, "period": 0.15},
                 {"pos": (1200, -1500, 40), "kind": "shot", "lvl": 140, "period": 0.3}]},
    {"name": "teleport", "doc": "complex: teleports of ~1000 u (respawn, noclip), every far route new at once",
     "map": "rp_downtown_v4c_v2", "path": [(-185, -720, -6), (-185, 200, -6), (-185, -720, -6), (-185, 200, -6)],
     "speed": 0, "hold": 1.0,
     "sources": [{"pos": (-1797.25, -418.8, -147), "kind": "loop", "lvl": 85},
                 {"pos": (900, 600, 40), "kind": "loop", "lvl": 85}]},
    {"name": "fly_up", "doc": "medium: noclip straight up 600 u above the spawn area (vertical move, roofs)",
     "map": "gm_construct", "path": [(-1800, -1200, -140), (-1800, -1200, 460)], "speed": 150,
     "sources": [{"pos": (-1100, -1900, -100), "kind": "loop", "lvl": 85},
                 {"pos": (-2600, -600, -100), "kind": "loop", "lvl": 85}]},
    {"name": "both_moving", "doc": "complex: a far loop drives across while the player walks the other way",
     "map": "gm_construct", "path": [(-1800, -1200, -140), (-1400, -1200, -140)], "speed": 150,
     "sources": [{"pos": (-2600, -2000, -100), "kind": "loop", "lvl": 90, "move": {"to": (-1000, -2000, -100), "speed": 400}}]},
    {"name": "crowd_walk", "doc": "stress: 40 hidden emitters (half loops, half repeated one-shots) while walking",
     "map": "gm_construct", "path": [(-1800, -1200, -140), (-1400, -1200, -140), (-1800, -1200, -140)], "speed": 250,
     "crowd": 40, "sources": []},
]

CLIENT_START = r"""
local P, PR = pba.Paths, pba.Probes
PBA_MV = { frames = {}, cost = {}, src = {}, t0 = SysTime(), Lpos = {} }
local mv = PBA_MV
local acc = 0
local wrapped = {}
local function wrap(tbl, name)
  if not tbl or not tbl[name] or wrapped[name] then return end
  local f = tbl[name]
  wrapped[name] = { tbl, f }
  tbl[name] = function(...)
    local t = SysTime()
    local a, b, c, d = f(...)
    acc = acc + (SysTime() - t)
    return a, b, c, d
  end
end
-- P.Compute: the free-field reference and the final answer per source
do
  local f = P.Compute
  wrapped.Compute = { P, f }
  P.Compute = function(S, L, lvl, cfg, ent)
    local t = SysTime()
    local r = f(S, L, lvl, cfg, ent)
    acc = acc + (SysTime() - t)
    if r and not r.provisional then
      local key = string.format("%d,%d,%d", math.Round(S.x / 8), math.Round(S.y / 8), math.Round(S.z / 8))
      local s = mv.src[key]
      if not s then s = { n = 0, wait = 0, step = 0, d = S:Distance(L) } mv.src[key] = s end
      local p = 0
      for _, v in ipairs(r.voices or {}) do p = p + (v.gain or 0) ^ 2 end
      local ff = pba.AC.GainToDb(pba.AC.EngineGain(S:Distance(L), lvl or 75))
      local loss = r.clear and 0 or (p > 0 and -(10 * math.log10(p) - ff) or 120)
      local now = SysTime()
      if s.last then
        s.wait = math.max(s.wait, now - s.last)
        if s.lastL and s.lastL:Distance(L) <= 32 then s.step = math.max(s.step, math.abs(loss - s.lastLoss)) end
      end
      s.n, s.last, s.lastL, s.lastLoss, s.d = s.n + 1, now, Vector(L), loss, math.min(s.d, S:Distance(L))
    end
    return r
  end
end
for _, n in ipairs({ "SliceStep", "AdvanceFar" }) do wrap(P, n) wrap(PR, n) end
PBA_MV_UNWRAP = function() for name, w in pairs(wrapped) do w[1][name] = w[2] end end
hook.Add("Think", "pba_mv_frame", function()
  mv.frames[#mv.frames + 1] = RealFrameTime()
  mv.cost[#mv.cost + 1] = acc
  acc = 0
end)
return true
"""

CLIENT_STOP = r"""
hook.Remove("Think", "pba_mv_frame")
if PBA_MV_UNWRAP then PBA_MV_UNWRAP() end
local mv = PBA_MV
local function stats(t, scale)
  local s = table.Copy(t) table.sort(s)
  local n = #s
  if n == 0 then return {} end
  return { n = n, median = math.Round(s[math.max(1, math.floor(n / 2))] * scale, 2), p99 = math.Round(s[math.max(1, math.floor(n * 0.99))] * scale, 2), max = math.Round(s[n] * scale, 2) }
end
local fr = stats(mv.frames, 1000)
local hitches = 0
for _, x in ipairs(mv.frames) do if x * 1000 > 2 * (fr.median or 1e9) then hitches = hitches + 1 end end
local over5 = 0
for _, x in ipairs(mv.cost) do if x > 0.005 then over5 = over5 + 1 end end
local srcs = {}
local SPEED = 343 / 0.01905
for k, s in pairs(mv.src) do
  srcs[#srcs + 1] = { key = k, evals = s.n, waitMax = math.Round(s.wait, 3), physDelay = math.Round(s.d / SPEED, 3), stepMax = math.Round(s.step, 2) }
end
table.sort(srcs, function(a, b) return a.waitMax > b.waitMax end)
local out = { frames = fr, hitches = hitches, pbaCost = stats(mv.cost, 1000), costOver5ms = over5, sources = #srcs, worstSources = { srcs[1], srcs[2], srcs[3] } }
PBA_MV = nil
return out
"""


def ensure_map(m):
    st = call("status", {})
    if st.get("map") != m:
        call("map_load", {"map": m, "maxplayers": 4}, timeout=300)
        time.sleep(6)
    for _ in range(300):
        if lua("client", "return pba.Probes == nil or (pba.Probes.current ~= nil and pba.Probes.building == nil)"):
            return
        time.sleep(1)


def vec(p):
    return "Vector(%s, %s, %s)" % p


def server_setup(sc):
    lines = ["PBA_MV_ENTS = PBA_MV_ENTS or {}", "for _, e in ipairs(PBA_MV_ENTS) do if IsValid(e) then if e.pbaLoop then e:StopSound(e.pbaLoop) end e:Remove() end end",
             "PBA_MV_ENTS = {}", "for i = 1, 32 do timer.Remove('pba_mv_' .. i) end"]
    for i, s in enumerate(sc["sources"], 1):
        lines.append("do local e = ents.Create('prop_physics') e:SetModel('models/props_junk/PopCan01a.mdl') e:SetPos(%s) e:Spawn()"
                     " local ph = e:GetPhysicsObject() if IsValid(ph) then ph:EnableMotion(false) end e:SetNoDraw(true)"
                     " PBA_MV_ENTS[#PBA_MV_ENTS + 1] = e" % vec(s["pos"]))
        if s["kind"] == "loop":
            snd = LOOPS[(i - 1) % len(LOOPS)]
            lines.append(" e.pbaLoop = '%s' e:EmitSound(e.pbaLoop, %d)" % (snd, s["lvl"]))
        else:
            lines.append(" timer.Create('pba_mv_%d', %s, 0, function() if IsValid(e) then e:EmitSound('%s', %d) end end)"
                         % (i, s.get("period", 0.5), SHOT, s["lvl"]))
        if s.get("move"):
            mv = s["move"]
            lines.append(" local a, b, sp, t0 = %s, %s, %s, CurTime()"
                         " hook.Add('Think', 'pba_mv_src%d', function() if not IsValid(e) then return end"
                         " local d = a:Distance(b) local f = math.min((CurTime() - t0) * sp / d, 1) e:SetPos(LerpVector(f, a, b)) end)"
                         % (vec(s["pos"]), vec(mv["to"]), mv["speed"], i))
        lines.append("end")
    for name, mode in sc.get("doors", {}).items():
        lines.append("for _, d in ipairs(ents.FindByName('%s')) do d:Fire('SetRotationDistance', '90') d:Fire('%s') end"
                     % (name, "Open" if mode == "open" else "Close"))
    lines.append("return true")
    return "\n".join(lines)


def server_walk(sc):
    pts = "{" + ", ".join(vec(p) for p in sc["path"]) + "}"
    if sc["speed"] > 0:
        return ("local pts, sp, ply = %s, %s, player.GetHumans()[1] ply:SetMoveType(MOVETYPE_NOCLIP) ply:SetPos(pts[1])"
                " local seg, t0 = 1, CurTime() PBA_MV_DONE = false"
                " hook.Add('Think', 'pba_mv_walk', function()"
                "  local a, b = pts[seg], pts[seg + 1] if not b then PBA_MV_DONE = true hook.Remove('Think', 'pba_mv_walk') return end"
                "  local d = a:Distance(b) local f = (CurTime() - t0) * sp / d"
                "  if f >= 1 then seg, t0 = seg + 1, CurTime() ply:SetPos(b) else ply:SetPos(LerpVector(f, a, b)) end"
                "  ply:SetVelocity(-ply:GetVelocity()) end) return true" % (pts, sc["speed"]))
    return ("local pts, hold, ply = %s, %s, player.GetHumans()[1] ply:SetMoveType(MOVETYPE_NOCLIP) ply:SetPos(pts[1]) PBA_MV_DONE = false"
            " for i = 2, #pts do timer.Simple((i - 1) * hold, function() ply:SetPos(pts[i]) if i == #pts then"
            " timer.Simple(hold, function() PBA_MV_DONE = true end) end end) end return true" % (pts, sc.get("hold", 1.0)))


SERVER_CLEAN = r"""
hook.Remove('Think', 'pba_mv_walk')
for i = 1, 32 do hook.Remove('Think', 'pba_mv_src' .. i) timer.Remove('pba_mv_' .. i) end
for _, e in ipairs(PBA_MV_ENTS or {}) do if IsValid(e) then if e.pbaLoop then e:StopSound(e.pbaLoop) end e:Remove() end end
PBA_MV_ENTS = nil
local ply = player.GetHumans()[1] if IsValid(ply) then ply:SetMoveType(MOVETYPE_WALK) end
return true
"""

results = {}
crowd_code = open(os.path.join(HERE, "perf_crowd.lua"), encoding="utf-8").read()
for sc in SCENARIOS:
    if ONLY and sc["name"] not in ONLY:
        continue
    print(f"##progress label=\"{sc['name']}\" msg=\"{sc['doc']}\"", flush=True)
    ensure_map(sc["map"])
    lua("server", "local ply = player.GetHumans()[1] ply:SetMoveType(MOVETYPE_NOCLIP) ply:SetPos(%s) return true" % vec(sc["path"][0]))
    if sc.get("crowd"):
        call("lua_job", {"realm": "server", "code": crowd_code, "args": {"n": sc["crowd"]}, "timeout_s": 120})
    lua("server", server_setup(sc))
    time.sleep(2.5)  # sounds start, first evaluations, fields of the start point
    lua("client", CLIENT_START)
    lua("server", server_walk(sc))
    t0 = time.time()
    for at, realm, code in sorted(sc.get("events", [])):
        while time.time() - t0 < at:
            time.sleep(0.05)
        lua(realm, code + " return true")
    for _ in range(600):
        if lua("server", "return PBA_MV_DONE == true"):
            break
        time.sleep(0.1)
    time.sleep(0.5)
    out = lua("client", CLIENT_STOP)
    lua("server", SERVER_CLEAN)
    if sc.get("crowd"):
        call("lua_job", {"realm": "server", "code": crowd_code, "args": {"stop": True}, "timeout_s": 30})
    results[sc["name"]] = out
    print(sc["name"] + ": " + json.dumps(out), flush=True)
print("##progress done=ok", flush=True)
print(json.dumps(results, indent=1))
