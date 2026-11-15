"""Relayed sounds after a campaign level transition and after a savegame load (real engine, singleplayer).
Both restart the Lua state of both realms (the relay's sound-name dictionaries start over) but restore the
player entity's table, with the ids his client acknowledged before (ply.pba_known). Before the fix the server
sent bare ids his fresh client did not know and the client dropped every relayed sound: own footsteps silent,
gunfire handed back late by the safety net (user, d1_trainstation_02 -> 03: server known ids 89, server
dictionary 53, client dictionary 0).
Scenario A: fresh d1_trainstation_02 (maxplayers 1), 75 footstep names emitted on the player (his client
acknowledges their ids), a marker written on his entity table, then the player is moved into the
trigger_changelevel that leads to d1_trainstation_03 (the engine's real transition, Host_Changelevel with the
02-03 landmark). Scenario B, on that map: the same names again, `save pbatest`, `load pbatest`.
After each: the marker must have survived (the table did: else the test would prove nothing), then 30 of the
same names are emitted on the player and counted on the client: pba.stats.relayedIn (the relay reached the
client's name check), A.Process calls for relayed sounds, and, with the module, pba_native.Play calls for the
footsteps. pass = the relay budget is not capped after the restart (server pba.stats.relayCapped and relayMuffled
stay 0, every emission relayed: the budget's clock, ply.pba_relayBucket, came from the previous map: -24800 tokens
in the user's d1_trainstation_03 -> 04, every relay refused for minutes, lines played as engine copies muffled
at -24 dB), and every emitted name was relayed (>= 90 %) and, with the module, played (>= 70 %: the module's own
masking and voice cap drop a few; green measured 26 of 30), in both.
Prints one JSON verdict. The savegame pbatest.* is deleted at the end (the engine's own transition files, shared
with every game of this machine, are left alone).
(The module is needed: own sounds and pba_native_all, the relays under test, exist with it only.)
Usage: MCP_INSTANCE=<id> python -I relay_transition.py <mcp.py> [transition|save]   (default: both)
"""
import json
import os
import subprocess
import sys
import time

MCP = sys.argv[1]
WHAT = sys.argv[2] if len(sys.argv) > 2 else "both"
TEST = os.path.dirname(os.path.abspath(__file__))
GAME = os.environ.get("PBA_GAME_DIR", r"D:\SteamLibrary\steamapps\common\GarrysMod\garrysmod")
SRC, DST = "d1_trainstation_02", "d1_trainstation_03"
MARK, PRE_N, POST_N = 424242, 75, 30


def call(tool, args, mx=2_000_000, timeout=400):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), str(mx)],
                         capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout).stdout
    try:
        return json.loads(out)
    except ValueError:
        return {"raw": out}


sys.path.insert(0, TEST)
import _cvsnap  # noqa: E402  restores every pba_* setting at exit
_cvsnap.guard(call)


def lua(realm, code):
    r = call("lua_exec", {"realm": realm, "code": code})
    return (r.get("values") or [None])[0] if isinstance(r, dict) else None


def job(realm, pre, fname, timeout_s=60):
    code = pre + "\n" + open(os.path.join(TEST, fname), encoding="utf-8").read()
    r = call("lua_job", {"realm": realm, "code": code, "timeout_s": timeout_s}, timeout=timeout_s + 60)
    return (r.get("values") or [r])[0] if isinstance(r, dict) else r


def gens():
    rl = call("status", {}).get("realms", {})
    return rl.get("server", {}).get("generation", 0), rl.get("client", {}).get("generation", 0)


def wait_realms(g0, timeout=150):
    """Both realms recreated after g0 = (server, client) generations, pba up on both, the player alive."""
    t = time.time()
    while time.time() - t < timeout:
        st = call("status", {})
        rl = st.get("realms", {}) if isinstance(st, dict) else {}
        sv, cl = rl.get("server", {}), rl.get("client", {})
        if not st.get("loading") and sv.get("available") and cl.get("available") \
                and sv.get("generation", 0) > g0[0] and cl.get("generation", 0) > g0[1]:
            if lua("client", "return IsValid(LocalPlayer()) and LocalPlayer():Alive() and pba ~= nil and pba.stats ~= nil") is True \
                    and lua("server", "return IsValid(player.GetHumans()[1]) and pba ~= nil and pba.dict ~= nil") is True:
                return True
        time.sleep(1)
    return False


def ready():
    """The map's pba client up (module built when there is one)."""
    for _ in range(60):
        if lua("client", "local N = pba.Native return N == nil or pba_native == nil or (not N.building and N.ready == true)") is True:
            return True
        time.sleep(2)
    return False


WRAP = r"""
local A = pba
local T = { relayed = 0, play = 0, steps = 0, process = A.Process }
pba_trtest = T
A.Process = function(data, relayed)
  if relayed then T.relayed = T.relayed + 1 end
  return T.process(data, relayed)
end
if pba_native and pba_native.Play then
  T.play0 = pba_native.Play
  pba_native.Play = function(n, ...)
    T.play = T.play + 1
    if string.find(tostring(n), "footsteps", 1, true) then T.steps = T.steps + 1 end
    return T.play0(n, ...)
  end
end
return { relayedIn = A.stats.relayedIn, native = T.play0 ~= nil }
"""
UNWRAP = r"""
local T = pba_trtest
if T then
  pba.Process = T.process
  if T.play0 then pba_native.Play = T.play0 end
  pba_trtest = nil
end
return true
"""
READ = r"""
local T = pba_trtest
return { relayedIn = pba.stats.relayedIn, processed = T and T.relayed, play = T and T.play, steps = T and T.steps,
         clientDict = table.Count(pba.dict) }
"""
SV_STATE = r"""
local ply = player.GetHumans()[1]
local known = 0
for _ in pairs(ply.pba_known or {}) do known = known + 1 end
-- the relay budget: in the Lua state's table (A.PState) or, before that fix, on the entity
local b = pba.PState and pba.PState(ply).relayBucket or ply.pba_relayBucket
local S = pba.stats
return { marker = ply.pba_testMarker, rawKnown = known, knownSession = ply.pba_knownSession, session = pba.dict.session,
         dictN = pba.dict.n, relayKnownFn = pba.RelayKnown ~= nil, curTime = CurTime(), bucketTok = b and b.tok, bucketT = b and b.t,
         entityBucketTok = ply.pba_relayBucket and ply.pba_relayBucket.tok,
         relayed = S.relayed or 0, capped = S.relayCapped or 0, muffled = S.relayMuffled or 0 }
"""
GOTO_TRIGGER = r"""
local ply = player.GetHumans()[1]
local want = "%s"
for _, t in ipairs(ents.FindByClass("trigger_changelevel")) do
  local b = t:GetInternalVariable("m_szMapName")
  local s = istable(b) and string.char(unpack(b)):gsub("%%z.*", "") or tostring(b)
  if s == want then
    local c, mn = t:WorldSpaceCenter(), t:WorldSpaceAABB()
    ply:GodEnable()
    ply:SetPos(Vector(c.x, c.y, mn.z + 4))
    return { trigger = t:EntIndex(), pos = tostring(ply:GetPos()) }
  end
end
return nil
"""


def phase(label, how):
    """One run: the pre-phase on the current map (acks, marker), `how` restarts both Lua states, the
    post-phase counts what reaches the client."""
    r = {"label": label}
    pre = job("server", f"TR_N, TR_MARK = {PRE_N}, {MARK}", "relay_transition_emit.lua", 60)
    r["pre"] = pre
    r["sv_before"] = lua("server", SV_STATE)
    g0 = gens()
    r["how"] = how()
    if not r["how"]:
        r["err"] = "the restart did not start"
        return r
    if not wait_realms(g0):
        r["err"] = "realms did not come back"
        return r
    ready()
    time.sleep(2)
    r["map"] = call("status", {}).get("map")
    r["sv_after"] = lua("server", SV_STATE)
    w = lua("client", WRAP)
    r["native"] = (w or {}).get("native")
    base = lua("client", READ)
    sv0 = lua("server", SV_STATE) or {}
    r["post"] = job("server", f"TR_N = {POST_N}", "relay_transition_emit.lua", 60)
    time.sleep(1)
    now = lua("client", READ)
    lua("client", UNWRAP)
    sv1 = lua("server", SV_STATE) or {}
    # the relay budget: nothing refused (muffled engine copies instead of relays), every emission relayed
    r["svRelayed"], r["svCapped"], r["svMuffled"] = (sv1.get(k, 0) - sv0.get(k, 0) for k in ("relayed", "capped", "muffled"))
    r["budgetOK"] = not r["native"] or r["svCapped"] == 0 and r["svMuffled"] == 0 and r["svRelayed"] >= POST_N * 0.9
    for k in ("relayedIn", "processed", "play", "steps"):
        r[k] = (now or {}).get(k, 0) - (base or {}).get(k, 0)
    r["clientDictAtStart"] = (base or {}).get("clientDict")
    sv = r["sv_after"] or {}
    r["tableSurvived"] = sv.get("marker") == MARK
    need = POST_N * 0.9
    r["relayedOK"] = r["relayedIn"] >= need
    r["playedOK"] = (r["steps"] >= POST_N * 0.7) if r["native"] else True
    r["pass"] = bool(r["tableSurvived"] and r["relayedOK"] and r["playedOK"] and r["budgetOK"])
    return r


def transition():
    if not lua("server", GOTO_TRIGGER % DST):
        return False
    return True


def saveload():
    call("console_exec", {"cmd": "save pbatest", "wait_frames": 30})
    time.sleep(2)
    call("console_exec", {"cmd": "load pbatest", "wait_frames": 10})
    return True


res = {"pass": False}
try:
    if WHAT in ("both", "transition"):
        call("map_load", {"map": SRC, "maxplayers": 1}, timeout=300)
        time.sleep(4)
        if not ready():
            raise RuntimeError("pba client not ready on " + SRC)
        # the real transition: the engine saves the map, changes level, loads the new one with the landmark
        res["transition"] = phase("transition " + SRC + " -> " + DST, transition)
        if res["transition"].get("map") != DST and "err" not in res["transition"]:
            res["transition"]["err"] = "map is %s, not %s" % (res["transition"].get("map"), DST)
            res["transition"]["pass"] = False
    if WHAT in ("both", "save"):
        if WHAT == "save":
            call("map_load", {"map": DST, "maxplayers": 1}, timeout=300)
            time.sleep(4)
            ready()
        res["save"] = phase("save/load " + DST, saveload)
    res["pass"] = all(res[k].get("pass") is True for k in ("transition", "save") if k in res)
finally:
    for f in ("pbatest.sav", "pbatest.tga"):
        try:
            os.remove(os.path.join(GAME, "save", f))
        except OSError:
            pass
print(json.dumps(res, indent=1, ensure_ascii=False))
sys.exit(0 if res["pass"] else 1)
