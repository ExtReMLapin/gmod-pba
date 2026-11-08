"""One model for a partly blocked opening (pba_tworooms, door1 open).
A flat prop (the door's own model, door01_left, frozen, standing in the doorway's portal plane)
covers part of the doorway. The same part is then given to the portal as a door leaf instead
(door state ajar, aperture = the free interval that the prop leaves, as P.Aperture measures a leaf).
The portal path must have the same loss within 1 dB and the same lowpass level:
  2 placements (hinge y 92 yaw 0: covers y ~91..112, the jamb the default pair bends round;
  hinge y 84 yaw 180: covers the doorway up to y ~85),
  x 3 source / listener pairs whose straight line hits the wall (bend round the y = 112 jamb,
  bend round the y = 64 jamb, oblique).
The former amplitude law (pba_path_props_slit 0) is printed too, for comparison, not checked.
Settings are forced by in-memory overrides on the client (pba.SetOverride), never written.
Offline prediction (portal as measured in game: x = 512, y 72..112, z 8..112; shipped defaults; the
prop passing 14 to 18 dB, wood leaf): prop 0.0 to 0.3 dB above the leaf (what passes the prop then goes
through the doorway, a leaf radiates from the opening itself); former law 0.7 to 3.0 dB above.
Usage: python -I -u mask_equivalence.py <mcp.py>
"""
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _cvsnap  # noqa: E402

MCP = sys.argv[1]
TOL_DB = 1.0


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


PAIRS = [("bend y=112 jamb", "784, 256, 40", "256, 256, 64"),
         ("bend y=64 jamb", "700, 20, 40", "300, 20, 64"),
         ("oblique", "784, 400, 40", "300, 20, 64")]
# hinge y and yaw of the prop (door01_left: origin on the hinge, leaf along local +y, 48.5 x 108.5)
PLACEMENTS = [("hinge y 92, covering the y = 112 side", 92, 0), ("hinge y 84 turned, covering the other side", 84, 180)]

PORTAL = """local P = pba.Paths P.InvalidateCache()
local r = P.Compute(Vector(784, 256, 40), Vector(256, 256, 64), 75)
local p = r.paths and r.paths[1] and r.paths[1].chain[1]
if not p then return nil end
local y0, y1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge
for _, v in ipairs(p.poly) do y0, y1, z0, z1 = math.min(y0, v.y), math.max(y1, v.y), math.min(z0, v.z), math.max(z1, v.z) end
return { x = p.center.x, open = p.open, y0 = y0, y1 = y1, z0 = z0, z1 = z1 }"""

# loss of the single-portal path (before the loud-source headroom), its lowpass and what props added
PATH = """local P = pba.Paths
pba.SetOverride('path_props', 1, true) pba.SetOverride('path_props_slit', @SLIT, true)
P.InvalidateCache()
local ok, r = pcall(P.Compute, Vector(@S), Vector(@L), 75)
pba.SetOverride('path_props', nil, true) pba.SetOverride('path_props_slit', nil, true)
P.InvalidateCache()
if not ok then error(r) end
for _, p in ipairs(r.paths or {}) do
  if p.chain and #p.chain == 1 then return { loss = p.rawLossDb or p.lossDb, lp = p.lp, prop = p.propDb or 0 } end
end
return { none = true, clear = r.clear or false }"""

# the same path with the doorway's leaf ajar, leaving free what the prop leaves free (world y range)
LEAF = """local P = pba.Paths P.InvalidateCache()
local S, L = Vector(@S), Vector(@L)
local r0 = P.Compute(S, L, 75)
local p = r0.paths and r0.paths[1] and r0.paths[1].chain[1]
if not p then return { none = true } end
local n = p.normal local wax = n:Cross(Vector(0, 0, 1)) wax:Normalize()
local w0, w1 = math.huge, -math.huge
for _, v in ipairs(p.poly) do local u = (v - p.center):Dot(wax) w0, w1 = math.min(w0, u), math.max(w1, u) end
local ua = (Vector(p.center.x, @YA, p.center.z) - p.center):Dot(wax)
local ub = (Vector(p.center.x, @YB, p.center.z) - p.center):Dot(wax)
if ua > ub then ua, ub = ub, ua end
ua, ub = math.max(ua, w0), math.min(ub, w1)
local free, area = {}, 0
if ua > w0 then free[#free + 1] = { w0, ua } end
if ub < w1 then free[#free + 1] = { ub, w1 } end
for _, iv in ipairs(free) do area = area + (iv[2] - iv[1]) / (w1 - w0) end
local o, a = p.open, p.ap
p.open, p.ap = 0.5, { key = math.Round(0.5 * 255), w0 = w0, w1 = w1, wax = wax, intervals = free, area = area }
P.InvalidateCache()
local ok, r = pcall(P.Compute, S, L, 75)
p.open, p.ap = o, a
P.InvalidateCache()
if not ok then error(r) end
for _, q in ipairs(r.paths or {}) do
  if q.chain and #q.chain == 1 then return { loss = q.rawLossDb or q.lossDb, lp = q.lp, area = area } end
end
return { none = true }"""

SPAWN = """if IsValid(PBA_MASK) then PBA_MASK:Remove() end
local e = ents.Create('prop_physics') e:SetModel('models/props_c17/door01_left.mdl')
e:SetPos(Vector(@X, @Y, @Z)) e:SetAngles(Angle(0, @YAW, 0)) e:Spawn()
local ph = e:GetPhysicsObject() if IsValid(ph) then ph:EnableMotion(false) end
PBA_MASK = e
local mn, mx = e:WorldSpaceAABB() return { mn.x, mn.y, mn.z, mx.x, mx.y, mx.z }"""

SEEN = """for _, e in ipairs(ents.FindInBox(Vector(500, 0, 0), Vector(540, 160, 120))) do
  if e:GetModel() == 'models/props_c17/door01_left.mdl' and e:GetClass() == 'prop_physics' then return true end
end return false"""


def sub(code, **kw):
    # longest keys first: "@Y" must not eat the start of "@YAW", nor "@S" that of "@SLIT"
    for k in sorted(kw, key=len, reverse=True):
        code = code.replace("@" + k, str(kw[k]))
    return code


if call("status", {}).get("map") != "pba_tworooms":
    call("map_load", {"map": "pba_tworooms", "maxplayers": 4})
    time.sleep(4)
_cvsnap.guard(call)  # nothing is written (in-memory overrides on the client), kept as a safety net
lua("server", "for _, d in ipairs(ents.FindByName('door1')) do d:Fire('Open') end return true")
portal = None
for _ in range(20):
    time.sleep(0.5)
    portal = lua("client", PORTAL)
    if portal and portal.get("open", 0) >= 0.99:
        break
if not portal:
    print("FAIL no portal path through door1")
    sys.exit(1)
print(f"portal plane x = {portal['x']:.1f}, y {portal['y0']:.0f}..{portal['y1']:.0f}, z {portal['z0']:.0f}..{portal['z1']:.0f}, "
      f"door1 open = {portal['open']:.2f}", flush=True)

fails, n = [], 0
for label, hinge, yaw in PLACEMENTS:
    # leaf top flush with the opening's top (the leaf is 108.5 tall, its origin at mid height): no free
    # strip above it that the leaf injected below (full height) would not have
    box = lua("server", sub(SPAWN, X=portal["x"], Y=hinge, YAW=yaw, Z=portal["z1"] - 54.25))
    if not box:
        print(f"FAIL {label}: prop not spawned")
        fails.append(label)
        continue
    for _ in range(20):
        time.sleep(0.25)
        if lua("client", SEEN):
            break
    time.sleep(0.5)
    ya, yb = max(box[1], portal["y0"]), min(box[4], portal["y1"])  # covered part of the doorway (world y)
    objs = [(lua("client", sub(PATH, S=s, L=l, SLIT=1)), lua("client", sub(PATH, S=s, L=l, SLIT=0))) for _, s, l in PAIRS]
    lua("server", "if IsValid(PBA_MASK) then PBA_MASK:Remove() end return true")
    for _ in range(20):
        time.sleep(0.25)
        if not lua("client", SEEN):
            break
    for (name, s, l), (obj, old) in zip(PAIRS, objs):
        n += 1
        leaf = lua("client", sub(LEAF, S=s, L=l, YA=ya, YB=yb))
        if not obj or obj.get("none") or not old or old.get("none") or not leaf or leaf.get("none"):
            fails.append(f"{label}, {name}: no portal path (prop {obj}, former {old}, leaf {leaf})")
            print("FAIL " + fails[-1], flush=True)
            continue
        d = obj["loss"] - leaf["loss"]
        ok = abs(d) <= TOL_DB and obj["lp"] == leaf["lp"] and obj["prop"] > 0
        line = (f"{label} (y {ya:.1f}..{yb:.1f}), {name}: leaf {leaf['loss']:.2f} dB lp{leaf['lp']} "
                f"(free {leaf['area']:.2f}), prop {obj['loss']:.2f} dB lp{obj['lp']} (props +{obj['prop']:.2f}) "
                f"-> diff {d:+.2f} dB (want |diff| <= {TOL_DB}, same lp, props > 0); former law {old['loss']:.2f} dB lp{old['lp']}")
        print(("PASS " if ok else "FAIL ") + line, flush=True)
        if not ok:
            fails.append(line)
print(f"{n - len(fails)}/{n} passed")
sys.exit(0 if not fails else 1)
