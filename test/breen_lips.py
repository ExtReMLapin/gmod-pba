"""Breen's lip sync on the station's screens (d1_trainstation_03; HL2 mounted). His Breencast lines are long
one-shots on npc_breen's CHAN_VOICE, 4000 u from the screens: pba takes them over (sv_loops long sound) and
the screens' speakers play them. The client moves a face only from a voice the ENGINE plays on that entity
(C_BaseFlex::ProcessVisemes): with the line taken over, nothing played on Breen and his face stayed still.
Probe: snd_dumpclientsounds once a second, standing by the screens. Pass: while a Breencast line plays, an
engine channel plays it on npc_breen too in most samples (vanilla: 22 of 24).
Usage: python -I test/breen_lips.py <mcp.py> [seconds]"""
import json, re, subprocess, sys, time
MCP = sys.argv[1]
SECS = int(sys.argv[2]) if len(sys.argv) > 2 else 25

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

lua("server", "local p = player.GetAll()[1] p:SetPos(Vector(-4440, -4910, 256)) return true")
breen = lua("client", "for _, e in ipairs(ents.FindByClass('npc_breen')) do return e:EntIndex() end return -1")
line = on_breen = 0
for _ in range(SECS):
    r = call("console_exec", {"realm": "menu", "cmd": "snd_dumpclientsounds"})
    tv = br = False
    for ln in r.get("output", []):
        t = ln.get("text", "")
        if "breencast" not in t:
            continue
        m = re.search(r"chan:(-?\d+) ent\((-?\d+)\)", t)
        if not m:
            continue
        if int(m.group(2)) == breen:
            br = True
        else:
            tv = True
    line += 1 if (tv or br) else 0
    on_breen += 1 if br else 0
    time.sleep(1)
ok = breen and breen > 0 and line >= 5 and on_breen >= 0.7 * line
print(json.dumps({"pass": bool(ok), "breen": breen, "samplesWithLine": line, "samplesWithBreenChannel": on_breen,
                  "mouthLong": lua("server", "return pba.stats.mouthLong or 0")}))
sys.exit(0 if ok else 1)
