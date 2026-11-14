"""A line's inaudible mouth copy stops with the line (pba_lipsync_stop, K1 / bug 27).
pba plays a copy of a taken voice line on the speaker itself at -60 dB so the engine moves its mouth. When the
line stops (StopSound on the speaker, a cancelled choreographed scene) that copy must stop too, or the mouth
keeps moving after the voice. mouth_stop only sees that a stop call is made; this test reads the engine's own
channel list (snd_dumpclientsounds: "chan:N ent(I):..." lines) and asks that no channel of the line is left on
the speaker's index 0.2 s after the stop.
Phases (speaker, stop):
  seen_server    a citizen in clear sight (the client has him), short line, server StopSound (relayed)
  seen_client    same, the client's own Entity:StopSound
  seen_scene     same, a choreographed scene cancelled
  unseen_server  citizen in room B behind the closed door (never sent to the client: pba_lipsync_unseen), server StopSound
  unseen_scene   same, scene cancelled
  seen_pba       the stop pba itself sends (pba_snd_stop) without the engine's own StopSound: the engine broadcasts its
                 stop to every client by name, which hides a mouth copy pba forgot; this one cannot
  unseen_pba     same, unseen speaker
  long_server    Barney in clear sight, a 10.5 s line taken over by sv_loops (pba_long_lipsync), server StopSound
  long_pba       same, pba's own stop of the followed line (sv_loops LP.Stop, MouthStop) without the engine's StopSound
  long_scene     same line on CHAN_VOICE, the scene-cancel stop (pba_scenes' OnCanceled input) fired for the speaker
Pass: before each stop a channel of the line is on the speaker's index (the copy exists), 0.2 s after it none.
Usage: python -I test/mouth_chan.py <mcp.py> [phase,...] [--off]   (--off: the stop option off, must fail)"""
import json, re, subprocess, sys, time, os
args = [a for a in sys.argv[1:] if not a.startswith("--")]
OFF = "--off" in sys.argv
MCP = args[0]
LINE = "vo/npc/male01/question06.wav"
SCENE = "scenes/npc/male01/question06.vcd"
LONG = "Trainyard.ba_getoutfast_cc"
PHASES = ["seen_server", "seen_client", "seen_scene", "seen_pba", "unseen_server", "unseen_scene", "unseen_pba", "long_server", "long_pba", "long_scene"]


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


def on_idx(idx, key):
    """Number of engine channels of the line (file name containing key) on entity index idx."""
    r = call("console_exec", {"realm": "menu", "cmd": "snd_dumpclientsounds"})
    n = 0
    for ln in r.get("output", []):
        t = ln.get("text", "")
        m = re.search(r"chan:(-?\d+) ent\((-?\d+)\)", t)
        if key in t and m and int(m.group(2)) == idx:
            n += 1
    return n


def spawn(unseen, cls):
    pos = "Vector(784, 256, 0)" if unseen else "Vector(400, 256, 0)"
    return lua("server", f"""if game.GetMap() ~= "pba_tworooms" then return -1 end
local d = ents.FindByName("door1")[1] if IsValid(d) then d:Fire("Close") end
local p = player.GetHumans()[1] p:SetPos(Vector(256, 256, 1)) p:SetEyeAngles(Angle(0, 0, 0))
if IsValid(PBA_MC_NPC) then PBA_MC_NPC:Remove() end
local n = ents.Create("{cls}") n:SetPos({pos}) n:Spawn() n:Activate() PBA_MC_NPC = n
return n:EntIndex()""")


def phase(name):
    where, kind = name.split("_")
    long = where == "long"
    idx = spawn(where == "unseen", "npc_barney" if long else "npc_citizen")
    if not idx or idx <= 0:
        return {"pass": False, "err": "needs pba_tworooms"}
    time.sleep(1.5)
    for _ in range(6):
        missing = lua("client", f"return not IsValid(Entity({idx}))")
        if missing == (where == "unseen"):
            break
        time.sleep(0.5)
    key = "getoutfast" if long else "question06"
    if kind == "scene" and not long:
        lua("server", f"PBA_MC_NPC:PlayScene('{SCENE}') return true")
    elif long:
        lua("server", f'PBA_MC_NPC:EmitSound("{LONG}", 75, 100, 1, CHAN_VOICE) return true')
    else:
        lua("server", f'PBA_MC_NPC:EmitSound("{LINE}", 75, 100, 1, CHAN_VOICE) return true')
    time.sleep(0.8)
    before = on_idx(idx, key)
    if kind == "server":
        lua("server", f'PBA_MC_NPC:StopSound("{LONG if long else LINE}") return true')
    elif kind == "pba":
        if long:
            lua("server", f'pba.Loops.Stop({idx}, "{LONG}") return true')
        else:
            lua("server", f'pba.RelayStop(PBA_MC_NPC, "{LINE}") return true')
    elif kind == "client":
        lua("client", f'Entity({idx}):StopSound("{LINE}") return true')
    elif kind == "scene" and long:
        # (the output a cancelled scene fires: sv_relay wireScene; no scene here carries a 10 s line)
        lua("server", f'pba.sceneTarget:Fire("PbaSceneCanceled", "{idx}") return true')
    elif kind == "scene":
        lua("server", """for _, e in ipairs(ents.FindByClass("instanced_scripted_scene")) do
if e:GetInternalVariable("m_hOwner") == PBA_MC_NPC then e:Fire("Cancel") end end return true""")
    time.sleep(0.2)
    after = on_idx(idx, key)
    time.sleep(0.3)
    later = on_idx(idx, key)
    lua("server", "if IsValid(PBA_MC_NPC) then PBA_MC_NPC:Remove() end return true")
    time.sleep(3.5)
    ok = before >= 1 and after == 0 and (missing if where == "unseen" else not missing)
    return {"pass": bool(ok), "clientLacksEntity": missing, "before": before, "after02s": after, "after05s": later}


if OFF:
    call("console_exec", {"realm": "client", "cmd": "pba_lipsync_stop 0"})
phases = args[1].split(",") if len(args) > 1 else PHASES
res = {p: phase(p) for p in phases}
ok = all(v["pass"] for v in res.values())
print(json.dumps({"pass": ok, **res}))
sys.exit(0 if ok else 1)
