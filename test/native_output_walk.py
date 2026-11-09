"""End to end, native rendering: the module's OUTPUT level along a walk, 16 u at a time, a stationary loop
source (a 3D stream of ambient/machines/spin_loop.wav, as downtown_stream / melancholia_overhang: music
changes its energy between two measures). What a player hears while walking must not jump.
Walks:
  * rp_downtown_v4c_v2: the radio in the brick building's upper room (-2120.3, -6872.2, -50); from inside
    the room (feet (-1968.5, -6676.3, -68)) to the corridor outside its doorway (-2202.6, -6940.2, -68),
    then to the street (-838.9, -6258.4, -204);
  * gm_melancholia: the radio on an upper floor (-337.2, 8.0, 168.5); from under the overhang (feet
    (-323.2, -335.1, 24), a ceiling 52 u above the eyes) to the open sky one metre left (-375.2, -332.5, 24)
    and two metres further (-479.2, -327.3, 24), then back (the back half: the same points read again).
Method: the player is teleported (noclip: points in mid-air or crossing walls hold) with a server lua_exec,
then SETTLE s (1 s: re-evaluation, ramps, the reverb's simulation) and a WINDOW s reading of the module's
own mix: pba.Native.energyL/R (what SetListener returns each frame, summed) and RenderDebug (the direct
part), both divided by the window's duration (an energy per second: windows of different lengths compare).
total - direct = reverb.
Pass, per step (between two adjacent points):
  * |total level change| <= MAX_DB (2 dB: about twice the level JND; a walk must sound smooth);
  * except where the geometry really changes, decided by the server's traces, not by the levels:
      - "solid": the eye in a solid, or the 16 u move crossing one (a teleport through a wall: a real walk
        goes round): left out, reported;
      - "edge": the straight line eye -> source changes from clear to blocked or back (passing a door jamb,
        a window's edge, the overhang's lip): the shadow boundary, where diffraction must keep the level
        continuous but a 16 u step spans a real part of the transition (UTD: -6 dB at the boundary itself):
        EDGE_DB (4 dB);
  * levels below the walk's loudest minus FLOOR_DB (60 dB) are compared as that floor (inaudible next to
    the rest of the walk; the street is ~70 dB below the room on rp_downtown);
  * the reading is stable: the start point read twice within NOISE_DB (1 dB), or 2 dB per step means nothing;
  * the stream is rendered natively at every point.
Reported: the worst steps of each map (positions, class, total / direct / reverb before and after).
Usage: python -I native_output_walk.py <mcp.py> [downtown] [melancholia] [--settle=1] [--window=0.5]
       (both maps by default; loads each map; restores pba_* settings and the player's move type)
"""
import json
import math
import os
import subprocess
import sys
import time

MCP = sys.argv[1]
SETTLE = next((float(a[9:]) for a in sys.argv[2:] if a.startswith("--settle=")), 1.0)
WINDOW = next((float(a[9:]) for a in sys.argv[2:] if a.startswith("--window=")), 0.5)
STEP, MAX_DB, EDGE_DB, FLOOR_DB, NOISE_DB = 16.0, 2.0, 4.0, 60.0, 1.0
TEST = os.path.dirname(os.path.abspath(__file__))


def call(tool, args, mx=2_000_000, timeout=300):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), str(mx)],
                         capture_output=True, text=True, encoding="utf-8", timeout=timeout).stdout
    try:
        return json.loads(out)
    except ValueError:
        return {"raw": out[-500:]}


sys.path.insert(0, TEST)
import _cvsnap  # restores every pba_* setting at exit, even on failure
_cvsnap.guard(call)


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


WALKS = {
    "downtown": {"map": "rp_downtown_v4c_v2", "radio": (-2120.3, -6872.2, -50.0),
                 "points": [(-1968.5, -6676.3, -68.0), (-2202.6, -6940.2, -68.0), (-838.9, -6258.4, -204.0)]},
    "melancholia": {"map": "gm_melancholia", "radio": (-337.2, 8.0, 168.5),
                    "points": [(-323.2, -335.1, 24.0), (-375.2, -332.5, 24.0), (-479.2, -327.3, 24.0),
                               (-375.2, -332.5, 24.0), (-323.2, -335.1, 24.0)]},
}
which = [a for a in sys.argv[2:] if not a.startswith("--")] or list(WALKS)


def walk(points, step):
    out = [points[0]]
    for a, b in zip(points, points[1:]):
        n = max(1, int(math.ceil(math.dist(a, b) / step)))
        out += [tuple(a[i] + (b[i] - a[i]) * k / n for i in range(3)) for k in range(1, n + 1)]
    return out


# feet at p, noclip, velocity zeroed. Flags from the server's traces: eye in a solid, the move from the
# previous eye crossing a solid, the straight line eye -> source clear (world brushes and props: what the
# path model sees as walls)
TELEPORT = """local p = player.GetHumans()[1]
if not IsValid(p) then return false end
p:SetMoveType(MOVETYPE_NOCLIP)
local feet, S = Vector(%f, %f, %f), Vector(%f, %f, %f)
local prev = p:EyePos()
p:SetPos(feet) p:SetVelocity(-p:GetVelocity())
local eye = feet + p:GetViewOffset()
return { solid = bit.band(util.PointContents(eye), CONTENTS_SOLID) ~= 0,
  cross = util.TraceLine({ start = prev, endpos = eye, mask = MASK_SOLID_BRUSHONLY }).Hit,
  clear = not util.TraceLine({ start = eye, endpos = S, mask = MASK_SOLID, filter = p }).Hit }"""
RESET = "pba_native.RenderDebug() pba.Native.energyL, pba.Native.energyR = 0, 0 PBA_OW_T = RealTime() return true"
READ = """local N = pba.Native local l = pba_native.RenderDebug() local dt = math.max(RealTime() - (PBA_OW_T or 0), 1e-3)
local rec = IsValid(PBA_OW_CH) and pba.Streams.chans[PBA_OW_CH]
return { total = ((N.energyL or 0) + (N.energyR or 0)) / dt, direct = (l.y + l.z) / dt, native = rec and rec.nativeId or false }"""


def db(e):
    return 10 * math.log10(max(e, 1e-30))


def measure():
    lua("client", RESET)
    time.sleep(WINDOW)
    r = lua("client", READ)
    if not isinstance(r, dict):
        return None
    return {"total": r["total"], "direct": r["direct"], "native": bool(r["native"]),
            "totalDb": round(db(r["total"]), 2), "directDb": round(db(r["direct"]), 2),
            "reverbDb": round(db(max(r["total"] - r["direct"], 0)), 2)}


def run(name):
    w = WALKS[name]
    if call("status", {}).get("map") != w["map"]:
        call("map_load", {"map": w["map"], "maxplayers": 4}, mx=5_000_000, timeout=300)
        time.sleep(4)
    call("console_exec", {"realm": "client", "cmd": "pba_native_render 1"})
    for _ in range(60):
        if lua("client", "return pba.Native.ready == true and pba.Native.render == true and not pba.Native.building"):
            break
        time.sleep(2)
    pts = walk(w["points"], STEP)
    radio = w["radio"]
    samples = []
    try:
        lua("server", TELEPORT % (*pts[0], *radio))
        time.sleep(1)
        # other streams paused (they count in the energies); the test loop at the radio
        lua("client", """PBA_OW_PAUSED = {}
for ch in pairs(pba.Streams.chans) do if IsValid(ch) and ch:GetState() == GMOD_CHANNEL_PLAYING then ch:Pause() PBA_OW_PAUSED[#PBA_OW_PAUSED + 1] = ch end end
sound.PlayFile("sound/ambient/machines/spin_loop.wav", "3d noplay noblock", function(ch)
	if not IsValid(ch) then return end
	ch:SetPos(Vector(%f, %f, %f)) ch:Set3DFadeDistance(250, 10000) ch:EnableLooping(true) ch:SetVolume(1) ch:Play()
	PBA_OW_CH = ch
end)
return true""" % radio)
        time.sleep(5)  # PBA takes the stream over, the reverb is simulated
        first = measure()
        again = measure()
        for i, p in enumerate(pts):
            f = lua("server", TELEPORT % (*p, *radio)) or {}
            time.sleep(SETTLE)
            m = measure() or {}
            m.update({"i": i, "pos": [round(c, 1) for c in p], "solid": bool(f.get("solid")),
                      "cross": bool(f.get("cross")) and i > 0, "clear": bool(f.get("clear"))})
            samples.append(m)
    finally:
        lua("client", "if IsValid(PBA_OW_CH) then PBA_OW_CH:Stop() end PBA_OW_CH = nil "
                      "for _, ch in ipairs(PBA_OW_PAUSED or {}) do if IsValid(ch) then ch:Play() end end return true")
        lua("server", "local p = player.GetHumans()[1] if IsValid(p) then p:SetMoveType(MOVETYPE_WALK) end return true")

    out = {"map": w["map"], "points": len(pts), "fails": [], "solid": 0, "edge": 0, "pairs": 0}
    noise = abs(first["totalDb"] - again["totalDb"]) if first and again else None
    out["noiseDb"] = None if noise is None else round(noise, 2)
    if noise is None or noise > NOISE_DB:
        out["fails"].append(f"unstable reading at the start point: {first} vs {again}")
    ok_samples = [s for s in samples if "totalDb" in s]
    if len(ok_samples) < len(samples):
        out["fails"].append(f"{len(samples) - len(ok_samples)} points without a reading")
    not_native = [s["i"] for s in ok_samples if not s["native"]]
    if not_native:
        out["fails"].append(f"stream not rendered natively at points {not_native[:10]}")
    loudest = max((s["totalDb"] for s in ok_samples), default=-300)
    floor = loudest - FLOOR_DB
    steps = []
    for a, b in zip(samples, samples[1:]):
        if "totalDb" not in a or "totalDb" not in b:
            continue
        if a["solid"] or b["solid"] or b["cross"]:
            out["solid"] += 1
            continue
        kind = "edge" if a["clear"] != b["clear"] else "plain"
        out["edge"] += kind == "edge"
        out["pairs"] += 1
        d = abs(max(b["totalDb"], floor) - max(a["totalDb"], floor))
        lim = EDGE_DB if kind == "edge" else MAX_DB
        st = {"step": f"{a['i']}->{b['i']}", "kind": kind, "dDb": round(d, 2), "from": a["pos"], "to": b["pos"],
              "before": [a["totalDb"], a["directDb"], a["reverbDb"]], "after": [b["totalDb"], b["directDb"], b["reverbDb"]]}
        steps.append(st)
        if d > lim:
            out["fails"].append(f"{st['step']} {kind}: {d:.1f} dB > {lim} dB (total/direct/reverb {st['before']} -> {st['after']})")
    if out["pairs"] < max(5, len(samples) // 3):
        out["fails"].append(f"only {out['pairs']} comparable steps of {len(samples) - 1} (inconclusive)")
    out["worst"] = sorted(steps, key=lambda s: -s["dDb"])[:5]
    out["levels"] = [[s["i"], s.get("totalDb"), "S" if s["solid"] else ("C" if s["clear"] else "")] for s in samples]
    out["pass"] = not out["fails"]
    return out


results = {n: run(n) for n in which}
ok = all(r["pass"] for r in results.values())
print(json.dumps({"pass": ok, **results}, ensure_ascii=False))
sys.exit(0 if ok else 1)
