"""The range-edge fade-in only for a loop joined near the edge of its range (review M6).
pba_loops_edge_fade fades in a loop this player joins midway (the server's join flag), from -60 dB over a second: right
for a car driving into the 2500 u radius, where the module's 1/r law is far from silent. But the server flags EVERY join
that way: a spawn, a teleport or a noclip next to a loud machine also started it at -60 dB and faded it in.
pba_tworooms: a server loop (ambient/machines/spin_loop.wav, level 55: a 500 u radius) on a prop in room B, the host in
room A (530 u: out of range). The host is then moved 100 u from it (in range, joined midway). Pass: the client's mirror
of the loop takes no fade (no edge factor) and its voice's first gain is within 2 dB of its gain 1.5 s later; a join at
the edge (450 u, over 0.8 of the radius) still fades.
Usage: python -I test/edge_fade_near.py <mcp.py>"""
import json, os, subprocess, sys, time
args = [a for a in sys.argv[1:] if not a.startswith("--")]
MCP = args[0]


def call(tool, a):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(a), "200000"],
                         capture_output=True, text=True, encoding="utf-8", errors="replace").stdout
    try:
        return json.loads(out)
    except ValueError:
        return {}


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _cvsnap
_cvsnap.guard(call)

SPY = r"""
PBA_EN = { gains = {} }
PBA_EN.up0 = PBA_EN.up0 or pba_native.Update
PBA_EN.play0 = PBA_EN.play0 or pba_native.Play
pba_native.Play = function(n, pos, g, ...)
  local id = PBA_EN.play0(n, pos, g, ...)
  if string.find(tostring(n), "spin_loop", 1, true) and id and id > 0 then PBA_EN.gains[id] = { g } PBA_EN.id = id PBA_EN.t = RealTime() end
  return id
end
pba_native.Update = function(id, pos, g, ...)
  local l = PBA_EN.gains[id]
  if l and #l < 400 then l[#l + 1] = g end
  return PBA_EN.up0(id, pos, g, ...)
end
return true"""
UNSPY = "if PBA_EN then pba_native.Update = PBA_EN.up0 pba_native.Play = PBA_EN.play0 end return true"
READ = r"""
local m
for _, x in pairs(pba.Loops.mirrors) do if not x.client and x.name == "ambient/machines/spin_loop.wav" then m = x end end
local l = PBA_EN.id and PBA_EN.gains[PBA_EN.id]
return { mirror = m ~= nil, edge = m and m.edgeK ~= nil or false, edgeT0 = m and m.edgeT0 ~= nil or false,
  first = l and l[1], last = l and l[#l], n = l and #l or 0 }"""


def run(x):
    """Host at (256, 256) (out of range), the loop started, then the host moved to (x, 256); the mirror read after 1.5 s."""
    lua("server", """local p = player.GetHumans()[1] p:SetPos(Vector(256, 256, 1))
hook.Add("SetupPlayerVisibility", "pba_edge_near", function() AddOriginToPVS(Vector(784, 256, 40)) end)
local e = ents.Create("prop_physics") e:SetModel("models/props_c17/oildrum001.mdl") e:SetPos(Vector(784, 256, 10)) e:Spawn()
local ph = e:GetPhysicsObject() if IsValid(ph) then ph:EnableMotion(false) end
PBA_EN_ENT = e
PBA_EN_SND = CreateSound(e, "ambient/machines/spin_loop.wav") PBA_EN_SND:SetSoundLevel(55) PBA_EN_SND:Play()
return true""")
    time.sleep(1.5)
    lua("client", SPY)
    lua("server", "local p = player.GetHumans()[1] p:SetPos(Vector(%d, 256, 1)) return true" % x)
    time.sleep(1.5)
    r = lua("client", READ) or {}
    lua("client", UNSPY)
    lua("server", """if PBA_EN_SND then PBA_EN_SND:Stop() end if IsValid(PBA_EN_ENT) then PBA_EN_ENT:Remove() end
hook.Remove("SetupPlayerVisibility", "pba_edge_near") local p = player.GetHumans()[1] p:SetPos(Vector(256, 256, 1)) return true""")
    time.sleep(1.0)
    import math
    f, l = r.get("first"), r.get("last")
    r["firstDb"] = 20 * math.log10(f / l) if f and l and f > 0 and l > 0 else None
    return r


res = {"near": run(684), "edge": run(350)}
near, edge = res["near"], res["edge"]
faded_near = near.get("edge") or (near.get("firstDb") is not None and near["firstDb"] < -2)
edge_fades = edge.get("mirror") and (edge.get("edge") or (edge.get("firstDb") is not None and edge["firstDb"] < -20))
ok = near.get("mirror") and not faded_near and edge_fades
res["pass"] = bool(ok)
print(json.dumps(res))
sys.exit(0 if ok else 1)
