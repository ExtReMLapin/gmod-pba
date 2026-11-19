"""A client-side volume / pitch change of a short sound pba took over does not restart the original (review C1).
A client-side EmitSound of a short line (vo/breencast/br_welcome01.wav, 3.9 s, CHAN_BODY) on a prop in pba_tworooms'
room B (kept in the host's PVS by the test) is suppressed by pba and re-emitted (copies, a module voice). The same
entity then sends SND_CHANGE_VOL (volume 0.5) for it, as an addon fading its sound does. The engine finds no such
sound on that channel and starts it from its top, clear through the wall (measured on main: snd_dumpclientsounds,
vol(127) timeleft 3.38 s on the prop's index right after the change, none before it). With pba_change_copies 1 the
change is taken: no engine channel, the followed copy's volume follows.
Pass: before and after the change, no engine channel of the line on the prop's index above vol 3 (/255).
--control (pba_change_copies 0): pass = the engine channel appears (the old behaviour).
Usage: python -I test/change_taken.py <mcp.py> [--control]"""
import json, os, re, subprocess, sys, time
args = [a for a in sys.argv[1:] if not a.startswith("--")]
CONTROL = "--control" in sys.argv
MCP = args[0]
LINE = "vo/breencast/br_welcome01.wav"
KEY = "br_welcome01"


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


def dump(idx, tag):
    """The engine's channels of the line on index idx: [vol 0-255], from the dump after marker `tag`."""
    lua("client", 'MsgN("PBA_CT_MARK %s") RunConsoleCommand("snd_dumpclientsounds") return true' % tag)
    time.sleep(0.5)
    lines = call("console_read", {"regex": "PBA_CT_MARK|" + KEY, "limit": 60}).get("lines", [])
    out, on = [], False
    for ln in lines:
        t = ln.get("text", "")
        if t.startswith("PBA_CT_MARK"):
            on = t.split()[1] == tag
            out = []
            continue
        m = re.search(r"vol\((\d+)\).*ent\((-?\d+)\)", t)
        if on and m and int(m.group(2)) == idx:
            out.append(int(m.group(1)))
    return out


call("console_exec", {"realm": "client", "cmd": "pba_change_copies %d" % (0 if CONTROL else 1)})
idx = lua("server", """
for _, p in ipairs(player.GetHumans()) do p:SetPos(Vector(256, 256, 0)) end
hook.Add("SetupPlayerVisibility", "pba_change_taken", function() AddOriginToPVS(Vector(784, 256, 40)) end)
local e = ents.Create("prop_physics") e:SetModel("models/props_c17/oildrum001.mdl") e:SetPos(Vector(784, 256, 20)) e:Spawn()
local ph = e:GetPhysicsObject() if IsValid(ph) then ph:EnableMotion(false) end
PBA_CT_ENT = e
return e:EntIndex()""")
res = {"idx": idx}
try:
    time.sleep(1.5)
    r = call("lua_job", {"realm": "client", "timeout_s": 30, "code": """
job:wait(function() return IsValid(Entity(%d)) end, 5)
local e = Entity(%d)
if not IsValid(e) then return { err = "prop not networked" } end
e:EmitSound("%s", 75, 100, 1, CHAN_BODY)
local l = pba.emitted[%d]
return { copies = l and #l or 0 }""" % (idx, idx, LINE, idx)})
    res["emit"] = (r.get("values") or [r])[0]
    time.sleep(0.4)
    res["before"] = dump(idx, "before")
    lua("client", 'Entity(%d):EmitSound("%s", 75, 100, 0.5, CHAN_BODY, SND_CHANGE_VOL) return true' % (idx, LINE))
    time.sleep(0.15)
    res["after"] = dump(idx, "after")
    res["recVol"] = lua("client", """for _, r in ipairs(pba.OneShots.recs) do if r.name == "%s" then return r.vol end end return -1""" % LINE)
finally:
    lua("server", 'hook.Remove("SetupPlayerVisibility", "pba_change_taken") if IsValid(PBA_CT_ENT) then PBA_CT_ENT:StopSound("%s") PBA_CT_ENT:Remove() end return true' % LINE)
    lua("client", 'for _, e in ipairs(ents.FindByClass("prop_physics")) do e:StopSound("%s") end return true' % LINE)
taken = isinstance(res.get("emit"), dict) and res["emit"].get("copies", 0) >= 1
loud_before = any(v > 3 for v in res["before"])
loud_after = any(v > 3 for v in res["after"])
res["taken"] = taken
if CONTROL:
    ok = taken and not loud_before and loud_after
else:
    ok = taken and not loud_before and not loud_after
res["pass"] = bool(ok)
print(json.dumps(res))
sys.exit(0 if ok else 1)
