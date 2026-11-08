"""Closed captions of a voice heard through a wall (closecaption 1).
The engine shows a caption when it emits the ORIGINAL sound of a soundscript that has a caption
token (OnCloseCaptionEmit fires on the client). pba's server hook suppresses the original for a
blocked listener and relays the resolved .wav, which has no token: the caption is lost.
pba_tworooms: listener at (256, 256, 0) in room A; an npc_citizen says "npc_citizen.answer01"
(CHAN_VOICE, level 75, caption "That's you all over.") from room A (control, 400, 256, 0) and from
room B (784, 256, 0), with pba_enable 0 (vanilla) then 1 (pba).
pass = pba shows the room-B caption whenever vanilla does (and the control caption in both modes);
a caption counts when its token is the soundscript or its text is the token's localized text.
Usage: MCP_INSTANCE=<id> python -I -u caption_check.py <mcp.py>
Prints one JSON line { pass, vanilla, pba }.
"""
import json
import os
import subprocess
import sys
import time

MCP = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "mcp.py")


def call(tool, args, mx=2_000_000):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), str(mx)],
                         capture_output=True, text=True, encoding="utf-8").stdout
    try:
        return json.loads(out)
    except Exception:
        return {}


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _cvsnap  # restores every pba_* setting at exit
_cvsnap.guard(call)


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


TOKEN = "npc_citizen.answer01"
if call("status", {}).get("map") != "pba_tworooms":
    call("map_load", {"map": "pba_tworooms", "maxplayers": 4})
    time.sleep(3)

enable0 = lua("server", "return GetConVarString('pba_enable')")
cc0 = lua("client", "return GetConVarString('closecaption')")
TEXT = lua("client", f"return language.GetPhrase('{TOKEN}')")
call("console_exec", {"realm": "client", "cmd": "closecaption 1"})

lua("client", """_G.__pba_cc = {}
hook.Add("OnCloseCaptionEmit", "pba_caption_check", function(s, dur, fp, txt)
	table.insert(_G.__pba_cc, { s = s, txt = txt, dur = dur })
end) return true""")
lua("server", """local p = player.GetHumans()[1]
p:SetPos(Vector(256, 256, 0)) p:SetEyeAngles(Angle(0, 0, 0))
for _, e in ipairs(ents.FindByName("pba_cc_npc")) do e:Remove() end
local n = ents.Create("npc_citizen") n:SetPos(Vector(784, 256, 0)) n:SetName("pba_cc_npc") n:Spawn()
return true""")
time.sleep(1)


def say(where):
    """Moves the NPC, has it say TOKEN, returns the captions the client showed and pba's counters."""
    lua("client", "_G.__pba_cc = {} return true")
    st = lua("server", f"""local n = ents.FindByName("pba_cc_npc")[1]
n:SetPos(Vector({where}, 256, 0))
local r0 = pba.stats.relayed
timer.Simple(0.3, function() if IsValid(n) then n:EmitSound("{TOKEN}") end end)
return r0""")
    time.sleep(2.0)
    caps = lua("client", "return _G.__pba_cc") or []
    rel = lua("server", "return pba.stats.relayed")
    # the engine's own caption (token = the soundscript) or one pushed by gui.AddCaption (same text)
    shown = [c for c in caps if c.get("txt") and (str(c.get("s", "")).lower().startswith(TOKEN) or c.get("txt") == TEXT)]
    return {"captions": len(shown), "relayed": (rel or 0) - (st or 0), "tokens": [c.get("s") for c in caps]}


res = {}
try:
    for mode, en in (("vanilla", 0), ("pba", 1)):
        call("console_exec", {"realm": "server", "cmd": f"pba_enable {en}"})
        time.sleep(1)
        res[mode] = {"control_roomA": say(400), "blocked_roomB": say(784)}
finally:
    lua("client", 'hook.Remove("OnCloseCaptionEmit", "pba_caption_check") _G.__pba_cc = nil return true')
    lua("server", 'for _, e in ipairs(ents.FindByName("pba_cc_npc")) do e:Remove() end return true')
    if enable0 is not None:
        call("console_exec", {"realm": "server", "cmd": f"pba_enable {enable0}"})
    if cc0 is not None:
        call("console_exec", {"realm": "client", "cmd": f"closecaption {cc0}"})

v, p = res.get("vanilla", {}), res.get("pba", {})
ok = (v.get("control_roomA", {}).get("captions", 0) > 0 and p.get("control_roomA", {}).get("captions", 0) > 0
      and (p.get("blocked_roomB", {}).get("captions", 0) > 0 or v.get("blocked_roomB", {}).get("captions", 0) == 0))
print(json.dumps({"pass": ok, "vanilla": v, "pba": p}))
