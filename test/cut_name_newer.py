"""A deferred channel cut does not stop the newer copy of the same name (review C6).
A citizen in pba_tworooms' room A says a 3.9 s line on CHAN_VOICE (A.Process: a module voice, and the mouth copy, the
engine playing it at volume 0.001 on his index so his face moves). He says the same line again, starting 0.3 s later
(its stamp delay): the channel rule defers the cut of the first line's copies to that start (pba_cut_at_start). The
second line's mouth copy is emitted at once on the same channel. The deferred stop of the FIRST mouth copy is a stop
by name on the speaker (the engine has no other way): it stopped the second one, and the face froze for the rest of
the line. Pass: 0.7 s after the second line, an engine channel of the line is still on his index.
--control (pba_cut_name_newer 0): pass = no channel left (the old behaviour).
Usage: python -I test/cut_name_newer.py <mcp.py> [--control]"""
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
    lua("client", 'MsgN("PBA_CN_MARK %s") RunConsoleCommand("snd_dumpclientsounds") return true' % tag)
    time.sleep(0.5)
    lines = call("console_read", {"regex": "PBA_CN_MARK|" + KEY, "limit": 60}).get("lines", [])
    out, on = [], False
    for ln in lines:
        t = ln.get("text", "")
        if t.startswith("PBA_CN_MARK"):
            on = t.split()[1] == tag
            out = []
            continue
        m = re.search(r"vol\((\d+)\).*ent\((-?\d+)\)", t)
        if on and m and int(m.group(2)) == idx:
            out.append(int(m.group(1)))
    return out


call("console_exec", {"realm": "client", "cmd": "pba_cut_name_newer %d" % (0 if CONTROL else 1)})
idx = lua("server", """
for _, p in ipairs(player.GetHumans()) do p:SetPos(Vector(256, 256, 0)) end
local e = ents.Create("npc_citizen") e:SetPos(Vector(150, 450, 0)) e:Spawn()
PBA_CN_ENT = e
return e:EntIndex()""")
res = {"idx": idx}
try:
    time.sleep(1.5)
    r = call("lua_job", {"realm": "client", "timeout_s": 30, "code": """
local idx = %d
job:wait(function() return IsValid(Entity(idx)) end, 5)
local e = Entity(idx)
if not IsValid(e) then return { err = "npc not networked" } end
local function say(delay)
	return pba.Process({ SoundName = "%s", Pos = e:WorldSpaceCenter(), SoundLevel = 75, Pitch = 100, Volume = 1, Channel = CHAN_VOICE,
		Flags = 0, DSP = 0, EntIndex = idx, Entity = e, Delay = delay }, true)
end
local m0 = pba.stats.mouthCopies or 0
local a = say(nil)
job:sleep(0.5)
local b = say(0.3)
return { first = a, second = b, mouths = (pba.stats.mouthCopies or 0) - m0, flex = e:GetFlexNum() }""" % (idx, LINE)})
    res["say"] = (r.get("values") or [r])[0]
    time.sleep(0.7)
    res["after"] = dump(idx, "after")
finally:
    lua("client", 'pba.StopSource(%d, "%s") return true' % (idx, LINE))
    lua("server", 'if IsValid(PBA_CN_ENT) then PBA_CN_ENT:StopSound("%s") PBA_CN_ENT:Remove() end return true' % LINE)
say = res.get("say")
ok_setup = isinstance(say, dict) and say.get("first") is True and say.get("second") is True and say.get("mouths", 0) >= 2
res["setup"] = ok_setup
alive = len(res["after"]) > 0
res["pass"] = bool(ok_setup and (alive != CONTROL))
print(json.dumps(res))
sys.exit(0 if res["pass"] else 1)
