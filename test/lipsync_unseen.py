"""Lip sync of a speaker the client has not received (pba_tworooms, door closed). A citizen spawned in room B,
behind the closed door's areaportal, is never sent to the player in room A: his client has no such entity.
In vanilla the engine still plays his line on a channel keyed by his entity index (snd_dumpclientsounds:
"chan:2 ent(N):NULL"), and the face that comes into view during the line moves its mouth from it. pba relays
the line (a wall between) and played no mouth copy for a speaker it could not find: no channel on the index.
Fix: the relay says the line is on a face, the client plays its copy by index (lipsync_unseen).
Probe: snd_dumpclientsounds during the line.
Pass: the client really lacks the entity, pba relayed the line, and a channel of the line plays on the citizen's index.
Usage: python -I test/lipsync_unseen.py <mcp.py>"""
import json, re, subprocess, sys, time
MCP = sys.argv[1]
LINE = "vo/npc/male01/question06.wav"


def call(tool, args):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), "200000"],
                         capture_output=True, text=True, encoding="utf-8", errors="replace").stdout
    try:
        return json.loads(out)
    except ValueError:
        return {}


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.abspath(__file__)))
import _cvsnap
_cvsnap.guard(call)

idx = lua("server", """if game.GetMap() ~= "pba_tworooms" then return -1 end
local d = ents.FindByName("door1")[1] if IsValid(d) then d:Fire("Close") end
local p = player.GetHumans()[1] p:SetPos(Vector(256, 256, 1)) p:SetEyeAngles(Angle(0, 0, 0))
if IsValid(PBA_LIPUNSEEN) then PBA_LIPUNSEEN:Remove() end
local n = ents.Create("npc_citizen") n:SetPos(Vector(900, 400, 0)) n:Spawn() PBA_LIPUNSEEN = n
return n:EntIndex()""")
if not idx or idx <= 0:
    print(json.dumps({"pass": False, "err": "needs pba_tworooms"}))
    sys.exit(1)
time.sleep(1.5)


def phase():
    time.sleep(0.6)
    missing = lua("client", f"return not IsValid(Entity({idx}))")
    r0 = lua("server", "return pba.stats.relayed or 0")
    lua("server", f'PBA_LIPUNSEEN:EmitSound("{LINE}", 75, 100, 1, CHAN_VOICE) return true')
    time.sleep(0.3)
    on_idx = 0
    for _ in range(3):
        r = call("console_exec", {"realm": "menu", "cmd": "snd_dumpclientsounds"})
        for ln in r.get("output", []):
            t = ln.get("text", "")
            m = re.search(r"chan:(-?\d+) ent\((-?\d+)\)", t)
            if "question06" in t and m and int(m.group(2)) == idx:
                on_idx += 1
                break
        time.sleep(0.4)
    relayed = (lua("server", "return pba.stats.relayed or 0") or 0) - (r0 or 0)
    time.sleep(2)
    return {"clientLacksEntity": missing, "relayed": relayed, "samplesOnIndex": on_idx}


a = phase()
lua("server", "if IsValid(PBA_LIPUNSEEN) then PBA_LIPUNSEEN:Remove() end return true")
ok = a["clientLacksEntity"] and a["relayed"] >= 1 and a["samplesOnIndex"] >= 1
print(json.dumps({"pass": bool(ok), "idx": idx, "on": a}))
sys.exit(0 if ok else 1)
