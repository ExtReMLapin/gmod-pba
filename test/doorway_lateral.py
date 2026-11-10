"""End to end, native rendering, rp_downtown_v4c_v2: the module's OUTPUT (total, direct, reverb) while the
listener steps SIDEWAYS across a doorway, from clear sight of the source to behind the jamb. The case a
player reported (2026-11-10): outside the radio room, door open, the radio in view; half a metre to the
right "the reverb (and other things) change completely". native_output_walk and native_send_continuity
walk the same doorway but along it (room -> corridor), never across the shadow boundary of its jamb.
Source: a 3D stream (sound.PlayFile of ambient/machines/spin_loop.wav: stationary energy) at the reported
radio (-2046.7, -6755.6, -59.5), the player's own streams paused. Two distance laws, as other addons'
radios use them: "flat" (Set3DFadeDistance(1e6, ...): same volume everywhere, the reported radio) and
"250" (Set3DFadeDistance(250, 10000)).
Walks (feet, noclip; 4 u steps along the corridor, x growing = to the right looking at the doorway):
  * "eye": the reported spot's line, feet z -68, y -6957 (45 u from the doorway), x -2234 .. -2154;
  * "far": the same 40 u further back (y -6997: behind the corridor's back wall, in the next room);
  * "near": 20 u from the doorway (y -6932);
  * "high": the reported line, feet 24 u higher (z -44).
Method: as native_output_walk (teleport, SETTLE s, then a WINDOW s reading of pba.Native.energyL/R and
RenderDebug: total and direct energies per second; reverb = total - direct).
Pass, per 4 u step (a slow step is ~ 8-16 u per frame: 4 u is finer than any walk):
  * |total change| <= MAX_DB (2 dB);
  * |reverb change| <= REV_DB (3 dB; the reverb is a tail, its level JND is coarser than the direct's);
  * |direct change| <= MAX_DB, EDGE_DB (4 dB) where the straight line eye -> source changes from clear to
    blocked (UTD: -6 dB at the shadow boundary itself; a 4 u step spans part of it);
  * levels below the walk's loudest total minus FLOOR_DB (40 dB) compared as that floor (inaudible next to
    the rest of the walk); a part (direct or reverb) more than MASK_DB (20 dB) under its own point's total at
    both ends of a step is not judged on its own (masked by the other part: the total covers it). Behind
    the corridor's back wall ("far" walk) the direct is 22 dB under the room's reverb and its rendered
    position flips between the stream's two arrivals of equal level (cl_streams renders voices[1]);
  * the walks: "far" is behind the corridor's back wall (y -6977..-6987), another room, kept as a
    behind-the-wall control;
  * steps where the eye is in a solid or the move crosses one: left out (reported);
  * a stable reading (the start point read twice within NOISE_DB = 1 dB), the stream rendered natively.
Usage: python -I doorway_lateral.py <mcp.py> [--settle=1] [--window=0.5] [--laws=flat,250] [--walks=eye,far]
       (loads the map if needed; restores pba_* settings, the player's position, move type and streams)
"""
import json
import math
import os
import subprocess
import sys
import time

MCP = sys.argv[1]
OPT = {a.split("=", 1)[0][2:]: a.split("=", 1)[1] for a in sys.argv[2:] if a.startswith("--") and "=" in a}
SETTLE = float(OPT.get("settle", 1.0))
WINDOW = float(OPT.get("window", 0.5))
STEP, MAX_DB, REV_DB, EDGE_DB, FLOOR_DB, NOISE_DB, MASK_DB = 4.0, 2.0, 3.0, 4.0, 40.0, 1.0, 20.0
TEST = os.path.dirname(os.path.abspath(__file__))
MAP = "rp_downtown_v4c_v2"
RADIO = (-2046.7, -6755.6, -59.5)
LAWS = {"flat": (1e6, 1e9), "250": (250, 10000)}
WALKS = {
    "eye": [(-2234.0, -6957.0, -68.0), (-2154.0, -6957.0, -68.0)],
    "far": [(-2234.0, -6997.0, -68.0), (-2154.0, -6997.0, -68.0)],
    "near": [(-2234.0, -6932.0, -68.0), (-2154.0, -6932.0, -68.0)],
    "high": [(-2234.0, -6957.0, -44.0), (-2154.0, -6957.0, -44.0)],
}
laws = OPT.get("laws", "flat,250").split(",")
walks = OPT.get("walks", ",".join(WALKS)).split(",")


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


def line(a, b, step):
    n = max(1, int(math.ceil(math.dist(a, b) / step)))
    return [tuple(a[i] + (b[i] - a[i]) * k / n for i in range(3)) for k in range(n + 1)]


TELEPORT = """local p = player.GetHumans()[1]
if not IsValid(p) then return false end
p:SetMoveType(MOVETYPE_NOCLIP)
local feet, S = Vector(%f, %f, %f), Vector(%f, %f, %f)
local prev = p:EyePos()
p:SetPos(feet) p:SetVelocity(-p:GetVelocity())
p:SetEyeAngles(Angle(0, 85, 0))
local eye = feet + p:GetViewOffset()
return { solid = bit.band(util.PointContents(eye), CONTENTS_SOLID) ~= 0,
  cross = util.TraceLine({ start = prev, endpos = eye, mask = MASK_SOLID_BRUSHONLY }).Hit,
  clear = not util.TraceLine({ start = eye, endpos = S + (eye - S):GetNormalized() * 12, mask = MASK_SOLID, filter = p }).Hit }"""
RESET = "pba_native.RenderDebug() pba.Native.energyL, pba.Native.energyR = 0, 0 PBA_DL_T = RealTime() return true"
READ = """local N = pba.Native local l = pba_native.RenderDebug() local dt = math.max(RealTime() - (PBA_DL_T or 0), 1e-3)
local rec = IsValid(PBA_DL_CH) and pba.Streams.chans[PBA_DL_CH]
return { total = ((N.energyL or 0) + (N.energyR or 0)) / dt, direct = (l.y + l.z) / dt, native = rec and rec.nativeId or false }"""


def db(e):
    return 10 * math.log10(max(e, 1e-30))


def measure():
    lua("client", RESET)
    time.sleep(WINDOW)
    r = lua("client", READ)
    if not isinstance(r, dict):
        return None
    return {"totalDb": round(db(r["total"]), 2), "directDb": round(db(r["direct"]), 2),
            "reverbDb": round(db(max(r["total"] - r["direct"], 0)), 2), "native": bool(r["native"])}


def analyse(samples, first, again):
    out = {"fails": [], "solid": 0, "edge": 0, "pairs": 0}
    noise = abs(first["totalDb"] - again["totalDb"]) if first and again else None
    out["noiseDb"] = None if noise is None else round(noise, 2)
    if noise is None or noise > NOISE_DB:
        out["fails"].append(f"unstable reading at the start point: {first} vs {again}")
    ok = [s for s in samples if "totalDb" in s]
    if len(ok) < len(samples):
        out["fails"].append(f"{len(samples) - len(ok)} points without a reading")
    nn = [s["i"] for s in ok if not s["native"]]
    if nn:
        out["fails"].append(f"stream not rendered natively at points {nn[:10]}")
    floor = max((s["totalDb"] for s in ok), default=-300) - FLOOR_DB
    steps = []
    for a, b in zip(samples, samples[1:]):
        if "totalDb" not in a or "totalDb" not in b:
            continue
        if a["solid"] or b["solid"] or b["cross"]:
            out["solid"] += 1
            continue
        edge = a["clear"] != b["clear"]
        out["edge"] += edge
        out["pairs"] += 1
        d = {k: abs(max(b[k + "Db"], floor) - max(a[k + "Db"], floor)) for k in ("total", "direct", "reverb")}
        # a part (direct or reverb) more than MASK_DB under its point's total at both ends of the step is
        # masked by the other part: its own change moves the total by under 0.05 dB (judged by the total)
        for k in ("direct", "reverb"):
            if a[k + "Db"] < a["totalDb"] - MASK_DB and b[k + "Db"] < b["totalDb"] - MASK_DB:
                d[k] = 0.0
        lim = {"total": EDGE_DB if edge else MAX_DB, "direct": EDGE_DB if edge else MAX_DB, "reverb": REV_DB}
        st = {"step": f"{a['i']}->{b['i']}", "edge": edge, "d": {k: round(v, 2) for k, v in d.items()},
              "x": [a["pos"][0], b["pos"][0]],
              "before": [a["totalDb"], a["directDb"], a["reverbDb"]], "after": [b["totalDb"], b["directDb"], b["reverbDb"]]}
        steps.append(st)
        for k in d:
            if d[k] > lim[k]:
                out["fails"].append(f"{st['step']} x {st['x'][0]}->{st['x'][1]}{' edge' if edge else ''}: {k} {d[k]:.1f} dB > {lim[k]} "
                                    f"(total/direct/reverb {st['before']} -> {st['after']})")
    if out["pairs"] < max(5, len(samples) // 2):
        out["fails"].append(f"only {out['pairs']} comparable steps of {len(samples) - 1} (inconclusive)")
    out["worst"] = sorted(steps, key=lambda s: -max(s["d"].values()))[:4]
    out["levels"] = [[s["i"], s["pos"][0], s.get("totalDb"), s.get("directDb"), s.get("reverbDb"),
                      "S" if s["solid"] else ("C" if s["clear"] else "")] for s in samples]
    out["pass"] = not out["fails"]
    return out


if call("status", {}).get("map") != MAP:
    call("map_load", {"map": MAP, "maxplayers": 4}, mx=5_000_000, timeout=300)
    time.sleep(4)
call("console_exec", {"realm": "client", "cmd": "pba_native_render 1"})
for _ in range(60):
    if lua("client", "return pba.Native.ready == true and pba.Native.render == true and not pba.Native.building"):
        break
    time.sleep(2)
home = lua("server", "local p = player.GetHumans()[1] if not IsValid(p) then return false end "
                     "local a, e = p:GetPos(), p:EyeAngles() return { a.x, a.y, a.z, e.p, e.y, p:GetMoveType() }")
results = {}
try:
    lua("client", """PBA_DL_PAUSED = {}
for ch in pairs(pba.Streams.chans) do if IsValid(ch) and ch:GetState() == GMOD_CHANNEL_PLAYING then ch:Pause() PBA_DL_PAUSED[#PBA_DL_PAUSED + 1] = ch end end
return true""")
    for law in laws:
        lo, hi = LAWS[law]
        for wname in walks:
            pts = line(WALKS[wname][0], WALKS[wname][1], STEP)
            lua("server", TELEPORT % (*pts[0], *RADIO))
            time.sleep(0.5)
            lua("client", """if IsValid(PBA_DL_CH) then PBA_DL_CH:Stop() end PBA_DL_CH = nil
sound.PlayFile("sound/ambient/machines/spin_loop.wav", "3d noplay noblock", function(ch)
	if not IsValid(ch) then return end
	ch:SetPos(Vector(%f, %f, %f)) ch:Set3DFadeDistance(%f, %f) ch:EnableLooping(true) ch:SetVolume(1) ch:Play()
	PBA_DL_CH = ch
end)
return true""" % (*RADIO, lo, hi))
            time.sleep(5)  # PBA takes the stream over, the reverb is simulated
            first = measure()
            again = measure()
            samples = []
            for i, p in enumerate(pts):
                f = lua("server", TELEPORT % (*p, *RADIO)) or {}
                time.sleep(SETTLE)
                m = measure() or {}
                m.update({"i": i, "pos": [round(c, 1) for c in p], "solid": bool(f.get("solid")),
                          "cross": bool(f.get("cross")) and i > 0, "clear": bool(f.get("clear"))})
                samples.append(m)
            results[f"{law}/{wname}"] = analyse(samples, first, again)
            print(f"{law}/{wname}: {'PASS' if results[law + '/' + wname]['pass'] else 'FAIL'} "
                  f"{len(results[law + '/' + wname]['fails'])} fails", file=sys.stderr, flush=True)
finally:
    lua("client", "if IsValid(PBA_DL_CH) then PBA_DL_CH:Stop() end PBA_DL_CH = nil "
                  "for _, ch in ipairs(PBA_DL_PAUSED or {}) do if IsValid(ch) then ch:Play() end end return true")
    if isinstance(home, list):
        lua("server", "local p = player.GetHumans()[1] if IsValid(p) then p:SetPos(Vector(%f, %f, %f)) "
                      "p:SetEyeAngles(Angle(%f, %f, 0)) p:SetMoveType(%d) p:SetVelocity(-p:GetVelocity()) end return true"
            % (home[0], home[1], home[2], home[3], home[4], int(home[5])))
    else:
        lua("server", "local p = player.GetHumans()[1] if IsValid(p) then p:SetMoveType(MOVETYPE_WALK) end return true")

ok = bool(results) and all(r["pass"] for r in results.values())
print(json.dumps({"pass": ok, **results}, ensure_ascii=False))
sys.exit(0 if ok else 1)
