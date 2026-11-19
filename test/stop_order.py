"""An explicit stop sent in the same tick as a relayed copy of the sound it stops reaches the client behind that copy
(pba_stop_order).
Seen on d3_citadel_01 (skylift pods): at each stop, the map fires PlaySound twice in one tick on each of two
non-looped ambient_generic (sound_digger3_hit, ambient/machines/floodgate_stop1.wav, CHAN_STATIC). Each PlaySound
sends SND_STOP, SND_STOP, then the new sound: stop, stop, play, stop, stop, play on one entity. The engine plays one
sound per entity (snd_dumpclientsounds with pba off: one channel). pba relayed both plays (pba_snd, unreliable) and the
stops between them (pba_snd_stop, reliable); the client reads a packet's reliable messages BEFORE its unreliable ones,
so the stop meant for the first play found nothing yet, and both plays became module voices: +6 dB and a doubled attack.
Here on pba_tworooms: an ambient_generic in room B (door closed, the host in room A, native rendering: relayed), its
PlaySound fired twice in one tick, as the map's outputs do.
Phases:
  vanilla  pba off (enable override 0, both realms): the engine's channels of the file on the entity, read with
           snd_dumpclientsounds. The reference: 1.
  pba      module voices of the file started (pba_native.Play) and not stopped 0.8 s later. Pass: exactly 1, as the engine.
Pass: both. --off (pba_stop_order 0): must fail (2 voices). --control: the same run with the option off, judged the
other way (the battery's control step): pass = 2 voices left.
--apart (pba_stop_both): the second PlaySound one tick after the first, not in the same tick: a client at 20 fps (or a low
cl_updaterate) reads both ticks in one packet, its reliable stop before both copies; --off / --control then turn
pba_stop_both off (pba_stop_order stays on: the same-tick rule does not cover it).
Usage: python -I test/stop_order.py <mcp.py> [--off | --control] [--apart] [vanilla,pba]"""
import json, os, re, subprocess, sys, time
args = [a for a in sys.argv[1:] if not a.startswith("--")]
CONTROL = "--control" in sys.argv
APART = "--apart" in sys.argv
OFF = "--off" in sys.argv or CONTROL
MCP = args[0]
PHASES = args[1].split(",") if len(args) > 1 else ["vanilla", "pba"]
WAV = "ambient/machines/floodgate_stop1.wav"
KEY = "floodgate_stop1"


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

SETUP = """if game.GetMap() ~= "pba_tworooms" then return -1 end
local d = ents.FindByName("door1")[1] if IsValid(d) then d:Fire("Close") end
local p = player.GetHumans()[1] p:SetPos(Vector(256, 256, 1)) p:SetEyeAngles(Angle(0, 0, 0))
if IsValid(PBA_SO_AMB) then PBA_SO_AMB:Remove() end
local e = ents.Create("ambient_generic")
e:SetPos(Vector(784, 256, 48))
e:SetKeyValue("message", "%s")
e:SetKeyValue("spawnflags", "48") -- start silent, not looped
e:SetKeyValue("health", "10")
e:SetKeyValue("radius", "4000")
e:Spawn() e:Activate()
PBA_SO_AMB = e
return e:EntIndex()""" % WAV
# the map's outputs: two PlaySound in one tick (each one: SND_STOP, SND_STOP, the sound)
FIRE = "PBA_SO_AMB:Fire('PlaySound') PBA_SO_AMB:Fire('PlaySound') return true"
if APART:  # one tick apart (engine.TickInterval later): two ticks of one packet
    FIRE = "PBA_SO_AMB:Fire('PlaySound') PBA_SO_AMB:Fire('PlaySound', '', engine.TickInterval() * 1.5) return true"
SPY = r"""
local NA = pba_native
PBA_SO = { plays = {}, stops = {} }
PBA_SO.play0, PBA_SO.stop0 = NA.Play, NA.StopVoice
NA.Play = function(n, ...)
  local id = PBA_SO.play0(n, ...)
  if id and string.find(string.lower(tostring(n)), "%KEY%", 1, true) then PBA_SO.plays[#PBA_SO.plays + 1] = id end
  return id
end
NA.StopVoice = function(id, ...)
  PBA_SO.stops[id] = true
  return PBA_SO.stop0(id, ...)
end
return true""".replace("%KEY%", KEY)
UNSPY = """if PBA_SO and PBA_SO.play0 then pba_native.Play, pba_native.StopVoice = PBA_SO.play0, PBA_SO.stop0 end
local live = 0
for _, id in ipairs(PBA_SO.plays) do if not PBA_SO.stops[id] then live = live + 1 end end
return { played = #PBA_SO.plays, live = live }"""


def channels(idx):
    """The engine's channels of the file on index idx (snd_dumpclientsounds)."""
    cur = call("console_read", {"limit": 1}).get("next_cursor", 0)
    lua("client", 'RunConsoleCommand("snd_dumpclientsounds") return true')
    time.sleep(0.5)
    lines = call("console_read", {"cursor": cur, "regex": KEY, "limit": 100}).get("lines", [])
    n = 0
    for ln in lines:
        m = re.search(r"ent\((-?\d+)\)", ln.get("text", ""))
        if m and int(m.group(1)) == idx:
            n += 1
    return n


def phase(name):
    idx = lua("server", SETUP)
    if not idx or idx <= 0:
        return {"pass": False, "err": "needs pba_tworooms"}
    time.sleep(1.0)
    try:
        if name == "vanilla":
            lua("server", "pba.SetOverride('enable', 0) return true")
            lua("client", "pba.SetOverride('enable', 0) return true")
            time.sleep(0.5)
            lua("server", FIRE)
            time.sleep(0.4)
            n = channels(idx)
            return {"pass": n == 1, "engineChannels": n}
        if lua("client", "local N = pba.Native return N ~= nil and N.render == true and pba_native ~= nil") is not True:
            return {"pass": False, "err": "needs native rendering (pba_native_render 1)"}
        lua("client", SPY)
        lua("server", FIRE)
        time.sleep(0.8)
        r = lua("client", UNSPY) or {}
        return {"pass": r.get("live") == 1, **r}
    finally:
        lua("server", "pba.SetOverride('enable', nil) return true")
        lua("client", "pba.SetOverride('enable', nil) return true")
        lua("server", "if IsValid(PBA_SO_AMB) then PBA_SO_AMB:Remove() end return true")
        time.sleep(3.5)  # (the file's end: the next phase starts clean)


if OFF:
    call("console_exec", {"realm": "server", "cmd": "pba_stop_both 0" if APART else "pba_stop_order 0"})
    time.sleep(1)
res = {}
for ph in PHASES:
    res[ph] = phase(ph)
ok = all(v.get("pass") for v in res.values())
if CONTROL:  # the old behaviour: both plays left as module voices
    ok = res.get("pba", {}).get("live") == 2
print(json.dumps({"pass": ok, "off": OFF, "control": CONTROL, "apart": APART, **res}))
