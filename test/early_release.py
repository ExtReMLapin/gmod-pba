"""An early line's engine copy is heard again when its module voice ends before the line (review C7).
pba_early_line_takeover: a line the engine started before this client was ready is handed to the module once it is,
the engine copy muted (kept: it moves the mouth). Set up as early_line.py (pba_tworooms, a citizen in room B behind
the closed door says vo/trainyard/al_thisday.wav, 2.67 s, the host marked not ready, ready 0.7 s in). Once the module
has the line, its voice ends early (stopped in the module, as its voice cap reaping it or a module stop would): nothing
plays the line any more but the muted engine copy, which stayed muted to its end (silence for the rest of the line).
Pass: 0.6 s after the voice ended, the engine channel of the line on the citizen is audible again (vol > 0) and the
mirror is over. --control (pba_early_release 0): pass = the channel still muted (the old behaviour).
Usage: python -I test/early_release.py <mcp.py> [--control]"""
import json, os, re, subprocess, sys, time
args = [a for a in sys.argv[1:] if not a.startswith("--")]
CONTROL = "--control" in sys.argv
MCP = args[0]
LINE = "vo/trainyard/al_thisday.wav"
KEY = "al_thisday"


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
    lua("client", 'MsgN("PBA_ER_MARK %s") RunConsoleCommand("snd_dumpclientsounds") return true' % tag)
    time.sleep(0.4)
    lines = call("console_read", {"regex": "PBA_ER_MARK|" + KEY, "limit": 60}).get("lines", [])
    out, on = [], False
    for ln in lines:
        t = ln.get("text", "")
        if t.startswith("PBA_ER_MARK"):
            on = t.split()[1] == tag
            out = []
            continue
        m = re.search(r"vol\((\d+)\).*ent\((-?\d+)\)", t)
        if on and m and int(m.group(2)) == idx:
            out.append(int(m.group(1)))
    return out


if lua("client", "local N = pba.Native return N ~= nil and N.render == true and pba_native ~= nil") is not True:
    print(json.dumps({"pass": False, "err": "needs native rendering"}))
    sys.exit(1)
call("console_exec", {"realm": "client", "cmd": "pba_early_release %d" % (0 if CONTROL else 1)})
idx = lua("server", """if game.GetMap() ~= "pba_tworooms" then return -1 end
local d = ents.FindByName("door1")[1] if IsValid(d) then d:Fire("Close") end
local p = player.GetHumans()[1] p:SetPos(Vector(256, 256, 1)) p:SetEyeAngles(Angle(0, 0, 0))
if IsValid(PBA_ER_NPC) then PBA_ER_NPC:Remove() end
local n = ents.Create("npc_citizen") n:SetPos(Vector(784, 256, 0)) n:Spawn() n:Activate() PBA_ER_NPC = n
return n:EntIndex()""")
res = {"idx": idx}
try:
    time.sleep(1.5)
    lua("server", """local p = player.GetHumans()[1] local st = pba.PState(p)
st.ready = false st.earlyDone = nil st.early = nil st.earlyT0 = nil
PBA_ER_NPC:EmitSound("%s", 80, 100, 1, CHAN_VOICE) return true""" % LINE)
    time.sleep(0.7)
    lua("client", "pba.SayReady() return true")
    r = call("lua_job", {"realm": "client", "timeout_s": 10, "code": """
local found
job:wait(function()
	for _, m in pairs(pba.Loops.mirrors) do if m.early and m.nativeId and m.early.muted then found = m return true end end
end, 1.2)
if not found then return false end
PBA_ER_M = found
pba_native.StopVoice(found.nativeId)
return true"""})
    res["taken"] = (r.get("values") or [None])[0]
    res["killedAt"] = time.time()
    time.sleep(0.6)
    res["after"] = dump(idx, "after")
    res["mirrorOver"] = lua("client", "return PBA_ER_M == nil or PBA_ER_M.done == true or pba.Loops.mirrors[PBA_ER_M.key] ~= PBA_ER_M")
finally:
    lua("server", "if IsValid(PBA_ER_NPC) then PBA_ER_NPC:Remove() end local p = player.GetHumans()[1] pba.PState(p).ready = true return true")
    lua("client", "PBA_ER_M = nil return true")
audible = any(v > 0 for v in res["after"])
if CONTROL:
    ok = res.get("taken") is True and len(res["after"]) >= 1 and not audible
else:
    ok = res.get("taken") is True and audible and res.get("mirrorOver") is True
res["pass"] = bool(ok)
print(json.dumps(res))
sys.exit(0 if ok else 1)
