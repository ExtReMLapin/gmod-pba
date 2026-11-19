"""A line spoken while this player's pba client is not ready yet is handed to the module once it is
(pba_early_line_takeover).
On a map load the scenes start before the client's pba Lua runs (d1_trainstation_05: Alyx's al_thisday emitted
1.25 s after PlayerInitialSpawn, the client's pba loaded 0.04 s later, native rendering 0.5 s after that): the
server leaves such a line to the engine for him (sv_sound: a player who is not ready is treated as a far one), so
the engine played all of it, dry, through the lab's walls, and pba never knew it.
Simulated here on pba_tworooms (the real map load: early_line_map.py): the host is marked not ready on the server
(as at join: A.PState(ply).ready = false, his early window opened again), a citizen in room B behind the closed door
says vo/trainyard/al_thisday.wav (2.67 s, CHAN_VOICE, level 80), then his client says it is ready (A.SayReady, as
at load) READY_AFTER seconds later.
Phases:
  mid    ready 0.7 s into the line. Pass: the module plays the line once (pba_native.Play of its file) from where
         the engine copy is (offset = Play time - emission time, +-0.12 s, and >= 0.5 s), the engine copy is then
         muted on the speaker's index (snd_dumpclientsounds: its channel still there, the mouth moves from it, at
         vol(000)), and its time left agrees with the module's (+-0.15 s).
  ended  ready 3.2 s after the line started (it is over): nothing plays it again (no Play of its file).
Pass: both. --off (pba_early_line_takeover 0): must fail (the engine keeps the whole line). --control: the same run,
judged the other way (the battery's control step): pass = no Play of the line and its engine copy still audible.
Usage: python -I test/early_line.py <mcp.py> [--off | --control] [mid,ended]"""
import json, os, re, subprocess, sys, time
args = [a for a in sys.argv[1:] if not a.startswith("--")]
CONTROL = "--control" in sys.argv  # the battery's control: --off, and pass = the bug shows
OFF = "--off" in sys.argv or CONTROL
MCP = args[0]
PHASES = args[1].split(",") if len(args) > 1 else ["mid", "ended"]
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


def dump(idx):
    """The engine's channels of the line on index idx: [(vol 0-255, timeleft s)], and the client's SysTime of the
    dump: a marker line printed with SysTime just before it, the console's own line clock giving the gap."""
    lua("client", 'MsgN("PBA_EL_MARK ", string.format("%.4f", SysTime())) RunConsoleCommand("snd_dumpclientsounds") return true')
    time.sleep(0.4)
    lines = call("console_read", {"regex": "PBA_EL_MARK|" + KEY, "limit": 40}).get("lines", [])
    mark = None
    out, t_line = [], None
    for ln in lines:
        t = ln.get("text", "")
        if t.startswith("PBA_EL_MARK"):
            mark, out, t_line = (float(t.split()[1]), ln.get("t", 0)), [], None
            continue
        m = re.search(r"vol\((\d+)\).*timeleft\(([-\d.]+)\).*chan:(-?\d+) ent\((-?\d+)\)", t)
        if mark and m and int(m.group(4)) == idx and t_line is None:
            out.append((int(m.group(1)), float(m.group(2))))
            t_line = ln.get("t", 0)
    if not mark:
        return [], 0
    return out, mark[0] + ((t_line - mark[1]) if t_line is not None else 0)


SPY = r"""
local NA = pba_native
PBA_EL = { plays = {} }
PBA_EL.play0 = PBA_EL.play0 or NA.Play
NA.Play = function(n, ...)
  if string.find(string.lower(tostring(n)), "%KEY%", 1, true) then
    local off = select(12, ...)
    PBA_EL.plays[#PBA_EL.plays + 1] = { t = SysTime(), offset = off }
  end
  return PBA_EL.play0(n, ...)
end
return true""".replace("%KEY%", KEY)
UNSPY = "if PBA_EL and PBA_EL.play0 then pba_native.Play = PBA_EL.play0 end return true"


def phase(name):
    if lua("client", "local N = pba.Native return N ~= nil and N.render == true and pba_native ~= nil") is not True:
        return {"pass": False, "err": "needs native rendering (pba_native_render 1)"}
    ready_after = 0.7 if name == "mid" else 3.2
    idx = lua("server", """if game.GetMap() ~= "pba_tworooms" then return -1 end
local d = ents.FindByName("door1")[1] if IsValid(d) then d:Fire("Close") end
local p = player.GetHumans()[1] p:SetPos(Vector(256, 256, 1)) p:SetEyeAngles(Angle(0, 0, 0))
if IsValid(PBA_EL_NPC) then PBA_EL_NPC:Remove() end
local n = ents.Create("npc_citizen") n:SetPos(Vector(784, 256, 0)) n:Spawn() n:Activate() PBA_EL_NPC = n
return n:EntIndex()""")
    if not idx or idx <= 0:
        return {"pass": False, "err": "needs pba_tworooms"}
    time.sleep(1.5)
    lua("client", SPY)
    # his client not ready, as at join (the early window open again: the fix's fields; harmless before it)
    t_emit = lua("server", """local p = player.GetHumans()[1] local st = pba.PState(p)
st.ready = false st.earlyDone = nil st.early = nil st.earlyT0 = nil
PBA_EL_NPC:EmitSound("%s", 80, 100, 1, CHAN_VOICE) return SysTime()""" % LINE)
    time.sleep(ready_after)
    lua("client", "pba.SayReady() return true")
    # the takeover: settle poll, request, answer, path evaluation, decode
    time.sleep(0.8 if name == "mid" else 1.5)
    chans, t_dump = dump(idx)
    plays = lua("client", "return PBA_EL.plays") or []
    time.sleep(3.0)
    lua("client", UNSPY)
    lua("server", "if IsValid(PBA_EL_NPC) then PBA_EL_NPC:Remove() end return true")
    lua("server", "local p = player.GetHumans()[1] pba.PState(p).ready = true return true")
    dur = lua("client", 'return SoundDuration("%s")' % LINE) or 2.67
    res = {"plays": len(plays), "readyAfter": ready_after, "channels": chans, "dur": dur}
    if name == "ended":
        res["pass"] = len(plays) == 0
        return res
    if len(plays) != 1 or not t_emit:
        res["pass"] = False
        return res
    p = plays[0]
    off = p.get("offset")
    res["offset"] = off
    res["elapsedAtPlay"] = p["t"] - t_emit
    ok = off is not None and abs(off - res["elapsedAtPlay"]) <= 0.12 and off >= 0.5
    # the engine copy: still there (the mouth's source), muted, at the module's point of the line
    if len(chans) == 1:
        vol, left = chans[0]
        res["engineVol"], res["engineLeft"] = vol, left
        module_left = dur - (off + (t_dump - p["t"])) if off is not None else None
        res["moduleLeft"] = module_left
        ok = ok and vol == 0 and module_left is not None and abs(left - module_left) <= 0.15
    else:
        ok = False
    res["pass"] = bool(ok)
    return res


if OFF:
    call("console_exec", {"realm": "server", "cmd": "pba_early_line_takeover 0"})
    time.sleep(1)
res = {}
for ph in PHASES:
    res[ph] = phase(ph)
ok = all(v.get("pass") for v in res.values())
if CONTROL:  # the old behaviour: the engine keeps the whole line, audible, and the module never plays it
    m = res.get("mid", {})
    ok = m.get("plays") == 0 and len(m.get("channels", [])) == 1 and m["channels"][0][0] > 0
print(json.dumps({"pass": ok, "off": OFF, "control": CONTROL, **res}))
sys.exit(0 if ok else 1)
