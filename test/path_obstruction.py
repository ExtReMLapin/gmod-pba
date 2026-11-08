"""Props on the SEGMENTS of the chosen paths (not only on the straight line).
A vending machine (about 90 u tall), frozen, right in front of the doorway on the source side where the
path bends, must lower the level heard through that doorway by at least 3 dB:
  A. pba_tworooms, door open: portal path;
  B. pba_noportal (same opening, no areaportal): probe path.
Before the fix the props were only looked for on the straight source-listener line, so the level
through the doorway did not change.
Portal path (A): since pba_path_props_slit (default 1) the masked doorway is evaluated like a partly
open door (Fresnel through the free part, diffuse sound through the free area), and what passes the
machine (through it and round it, as on the straight line) then goes through the doorway; no longer the
amplitude law (1 - f) + f g. Measured with that law: -6.0 dB (A, f = 1), -5.3 dB (B). In game (portal
x = 512, y 72..112, z 8..112; machine x 526..569, top z 96.6) the 15 samples are all masked; a ring of
probes along the edges looks for the free strip above the machine. Offline: fully masked -> drop =
what passes the machine (~6 dB, as with the former law); top 15 % free -> 3.7 dB (machine 4.4 dB) to
5.3 dB (7 dB). The threshold stays 3 dB (pure test "vending machine ... loses >= 3 dB").
(B) is unchanged (segment traces).
Usage: python -I -u path_obstruction.py <mcp.py>
"""
import json
import subprocess
import sys
import time

MCP = sys.argv[1]


def call(tool, args, mx=2_000_000):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), str(mx)],
                         capture_output=True, text=True, encoding="utf-8").stdout
    try:
        return json.loads(out)
    except Exception:
        return {}


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


LEVEL = """local P = pba.Paths local S, L = Vector(784, 256, 40), Vector(256, 256, 64)
P.InvalidateCache() local r = P.Compute(S, L, 75) local pw = 0
for _, v in ipairs(r.voices or {}) do pw = pw + v.gain * v.gain end
local v = r.voices and r.voices[1]
return { level = 10 * math.log10(math.max(pw, 1e-12)), kind = v and v.kind, probes = r.viaProbes or false, n = r.paths and #r.paths or 0 }"""

SPAWN = """if IsValid(PBA_OBS) then PBA_OBS:Remove() end
local e = ents.Create('prop_physics') e:SetModel('models/props_interiors/VendingMachineSoda01a.mdl')
e:SetPos(Vector(550, 90, 0)) e:SetAngles(Angle(0, 180, 0)) e:Spawn()
local ph = e:GetPhysicsObject() if IsValid(ph) then ph:EnableMotion(false) end
-- pushed against the wall (no sliver of air between its back and the wall face x = 528)
local mn = e:WorldSpaceAABB() e:SetPos(Vector(550 - (mn.x - 526), 90, -e:OBBMins().z)) PBA_OBS = e
local mn, mx = e:WorldSpaceAABB() return { tostring(mn), tostring(mx) }"""

results = []
for label, m in (("A-portal", "pba_tworooms"), ("B-probes", "pba_noportal")):
    if call("status", {}).get("map") != m:
        call("map_load", {"map": m, "maxplayers": 4})
        time.sleep(4)
    if m == "pba_tworooms":
        lua("server", "for _, d in ipairs(ents.FindByName('door1')) do d:Fire('Open') end return true")
        time.sleep(2)
    for _ in range(60):  # probe graph (pba_noportal)
        if lua("client", "return pba.Probes == nil or pba.Probes.current ~= nil"):
            break
        time.sleep(1)
    free = lua("client", LEVEL)
    time.sleep(0.5)
    free = lua("client", LEVEL)  # warm (background probe solve done)
    box = lua("server", SPAWN)
    time.sleep(1.5)  # the client sees the prop
    lua("client", LEVEL)
    time.sleep(0.5)
    blocked = lua("client", LEVEL)
    lua("server", "if IsValid(PBA_OBS) then PBA_OBS:Remove() end return true")
    drop = free["level"] - blocked["level"]
    ok = drop >= 3
    results.append(ok)
    print(("PASS " if ok else "FAIL ") + f"{label} ({m}): free {free['level']:.1f} dB ({free['kind']}, probes={free['probes']}), "
          f"vending machine in the doorway {blocked['level']:.1f} dB -> drop {drop:.1f} dB (want >= 3); box {box}", flush=True)
n = sum(results)
print(f"{n}/{len(results)} passed")
sys.exit(0 if n == len(results) else 1)
