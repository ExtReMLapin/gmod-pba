"""One caption per line (d1_trainstation_05; HL2 mounted). Eli speaks in his lab, 5000 u away; two microphones
(both named eli_mic) relay his line to two monitors, one in Kleiner's lab next to the player, one far away. The
engine plays the near monitor's copy (clear: untouched, its caption shown by the engine) while pba relays the
far one (suppressed: pba sends its caption on its own, sv_relay sendCaption): the line was captioned twice
("On est tous prets, ici" twice, user report 2026-11-14). The engine shows one caption per line (vanilla).
Probe: GM:OnCloseCaptionEmit on the client counts the captions of that line (by text, the engine's and the ones
pba adds with gui.AddCaption), for: pba off (vanilla reference), pba on, pba on with pba_caption_once 0.
Pass: vanilla shows >= 1, pba on shows as many as vanilla.
Usage: python -I test/caption_once.py <mcp.py>"""
import json, subprocess, sys, time
MCP = sys.argv[1]
TOK = "k_lab.eli_allset"


def call(tool, args):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), "200000"],
                         capture_output=True, text=True, encoding="utf-8").stdout
    try:
        return json.loads(out)
    except ValueError:
        return {}


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


if lua("server", "return game.GetMap()") != "d1_trainstation_05":
    print(json.dumps({"pass": False, "err": "needs d1_trainstation_05"}))
    sys.exit(1)
was_en = lua("server", "return GetConVar('pba_enable'):GetString()")
was_once = lua("client", "local c = GetConVar('pba_caption_once') return c and c:GetString() or nil")
# the captions of the line, by text without tags (the engine's and pba's gui.AddCaption ones)
lua("client", """
local function bare(s) return (string.gsub(s or "", "<[^>]*>", "")) end
PBA_TEST_CAP = { n = 0, want = bare(language.GetPhrase('""" + TOK + """')) }
-- pba's own caption hook (pba_caption_once, absent before it) is called from ours: a caption it drops is
-- not counted (hooks run in no fixed order)
local t = hook.GetTable().OnCloseCaptionEmit or {}
PBA_TEST_CAP.pba = t.pba_caption_once
if PBA_TEST_CAP.pba then hook.Remove("OnCloseCaptionEmit", "pba_caption_once") end
hook.Add("OnCloseCaptionEmit", "pba_test_caption_once", function(tok, dur, fromPlayer, text)
	if PBA_TEST_CAP.pba and PBA_TEST_CAP.pba(tok, dur, fromPlayer, text) == true then return true end
	if tok == '""" + TOK + """' or bare(text) == PBA_TEST_CAP.want then PBA_TEST_CAP.n = PBA_TEST_CAP.n + 1 end
end)
return true""")


def phase(enable, once):
    call("console_exec", {"realm": "server", "cmd": "pba_enable " + enable})
    if once is not None:
        call("console_exec", {"realm": "client", "cmd": "pba_caption_once " + once})
    time.sleep(1.5)
    lua("client", "PBA_TEST_CAP.n = 0 return true")
    lua("server", """
local p = player.GetHumans()[1]
p:SetPos(Vector(-6664, -1382, 10))
for _, m in ipairs(ents.FindByName("eli_mic")) do m:Fire("Enable") end
timer.Simple(0.5, function() local e = ents.FindByName("eli")[1] if IsValid(e) then e:EmitSound('""" + TOK + """') end end)
return true""")
    time.sleep(3)
    return lua("client", "return PBA_TEST_CAP.n")


res = {}
try:
    res["vanilla"] = phase("0", None)
    res["pba"] = phase("1", "1")
    res["pba_once0"] = phase("1", "0")
finally:
    call("console_exec", {"realm": "server", "cmd": "pba_enable " + (was_en or "1")})
    if was_once is not None:
        call("console_exec", {"realm": "client", "cmd": "pba_caption_once " + was_once})
    lua("client", "hook.Remove('OnCloseCaptionEmit', 'pba_test_caption_once') "
                  "if PBA_TEST_CAP and PBA_TEST_CAP.pba then hook.Add('OnCloseCaptionEmit', 'pba_caption_once', PBA_TEST_CAP.pba) end return true")
ok = (res.get("vanilla") or 0) >= 1 and res.get("pba") == res.get("vanilla")
res["pass"] = bool(ok)
print(json.dumps(res))
sys.exit(0 if ok else 1)
