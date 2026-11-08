"""Saved games (singleplayer, d1_town_01): a loaded save must leave pba's loops coherent.
On `load`, the engine restores the playing ambient_generic loops itself (StaticSound at load, no
EntityEmitSound) and Lua starts over: pba must adopt them again (pba.Loops.AdoptAmbients, run when its
hooks go in), so they are mirrored and muffled, not left vanilla through every wall.
Steps: fresh d1_town_01 (maxplayers 1), player 150 u from the fire ambient (d1_town.SmallFireLoop), a
Lua loop on a prop (Entity:EmitSound steam_loop1, which no save restores, vanilla GMod included),
`save pba_test`, `load pba_test`, then compares pba.Loops.active (server) and pba.Loops.mirrors
(client) with the looping ambient_generic entities actually active, and reads the engine's own starts
and stops from the console (developer 1 + snd_showstart 1, restored at the end). The save files
(garrysmod/save/pba_test.*, d1_town_01.HL1-3) are deleted afterwards.
pass: every active looping ambient is in pba.Loops.active after the load, the one in range has a client
mirror, its engine copy was stopped after the restore, no stale key (dead entity) and no Lua error.
Usage: MCP_INSTANCE=<id> python -I save_load_loops.py <mcp.py> [<garrysmod dir>]
"""
import json
import os
import re
import subprocess
import sys
import time

MCP = sys.argv[1]
GAME = sys.argv[2] if len(sys.argv) > 2 else os.environ.get(
    "PBA_GAME_DIR", r"D:\SteamLibrary\steamapps\common\GarrysMod\garrysmod")


def call(tool, args, mx=2_000_000, timeout=400):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), str(mx)],
                         capture_output=True, text=True, encoding="utf-8", timeout=timeout).stdout
    try:
        return json.loads(out)
    except ValueError:
        return {"raw": out}


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _cvsnap  # noqa: E402  restores every pba_* setting at exit
_cvsnap.guard(call)


def lua(realm, code):
    r = call("lua_exec", {"realm": realm, "code": code})
    return (r.get("values") or [None])[0] if isinstance(r, dict) else None


def wait_realms(gen0, timeout=120):
    """Server and client realms recreated after a load (generation above gen0) and ready."""
    t = time.time()
    while time.time() - t < timeout:
        st = call("status", {})
        rl = st.get("realms", {}) if isinstance(st, dict) else {}
        sv, cl = rl.get("server", {}), rl.get("client", {})
        if not st.get("loading") and sv.get("available") and cl.get("available") \
                and sv.get("generation", 0) > gen0 and cl.get("generation", 0) > gen0:
            if lua("client", "return IsValid(LocalPlayer()) and pba ~= nil and pba.Loops ~= nil") is True:
                return True
        time.sleep(1)
    return False


STATE = r"""
local act, stale = {}, 0
for k, l in pairs(pba.Loops.active) do
  act[#act + 1] = { key = k, name = l.name, cls = IsValid(l.ent) and l.ent:GetClass() or "?", subs = table.Count(l.subs) }
  if not IsValid(l.ent) then stale = stale + 1 end
end
local amb = {}
for _, e in ipairs(ents.FindByClass("ambient_generic")) do
  local msg = e:GetInternalVariable("message") or ""
  local p = msg ~= "" and sound.GetProperties(msg)
  local wav = p and (istable(p.sound) and p.sound[1] or p.sound) or msg
  if e:GetInternalVariable("m_fActive") and bit.band(e:GetSpawnFlags(), 1) == 0 and pba.IsLooping(wav) then
    amb[#amb + 1] = { idx = e:EntIndex(), wav = wav, d = math.Round(e:GetPos():Distance(Entity(1):GetPos())) }
  end
end
local prop = ents.FindByName("pba_t_emit")[1]
return { active = act, stale = stale, ambients = amb, prop = IsValid(prop) and prop:EntIndex() or false }
"""
MIRRORS = "local o = {} for k in pairs(pba.Loops.mirrors) do o[#o + 1] = k end return o"

res = {"pass": False}
cv0 = {}
try:
    call("map_load", {"map": "d1_town_01", "maxplayers": 1}, timeout=300)
    time.sleep(3)
    # the player beside the fire loop, a prop with a Lua loop beside him
    setup = lua("server", r"""
      local fire
      for _, e in ipairs(ents.FindByClass("ambient_generic")) do
        if string.find(e:GetInternalVariable("message") or "", "Fire", 1, true) then fire = e end
      end
      if not IsValid(fire) then return false end
      local ply = Entity(1)
      ply:GodEnable()
      local p = fire:GetPos() + Vector(150, 0, 0)
      local tr = util.TraceLine({ start = p + Vector(0, 0, 64), endpos = p - Vector(0, 0, 512), mask = MASK_PLAYERSOLID_BRUSHONLY })
      ply:SetPos(tr.HitPos)
      local e = ents.Create("prop_physics")
      e:SetModel("models/props_c17/oildrum001.mdl")
      e:SetPos(tr.HitPos + Vector(0, 96, 24))
      e:Spawn()
      e:GetPhysicsObject():EnableMotion(false)
      e:SetName("pba_t_emit")
      timer.Simple(0.5, function() if IsValid(e) then e:EmitSound("ambient/gas/steam_loop1.wav", 80, 100, 1, CHAN_STATIC) end end)
      return fire:EntIndex()
    """)
    time.sleep(2.5)  # pba_loops subscription tick (0.5 s) and the client mirror
    before = lua("server", STATE)
    before["mirrors"] = lua("client", MIRRORS)
    for n in ("developer", "snd_showstart"):
        cv0[n] = lua("client", f"return GetConVarString('{n}')")
    call("console_exec", {"cmd": "developer 1"})
    call("console_exec", {"cmd": "snd_showstart 1"})
    call("console_exec", {"cmd": "save pba_test", "wait_frames": 30})
    time.sleep(1)
    gen0 = call("status", {}).get("realms", {}).get("server", {}).get("generation", 0)
    cur = call("console_read", {"limit": 1}).get("next_cursor", 0)
    ecur = call("errors_since", {"cursor": 0, "limit": 2000}).get("next_cursor", 0)
    call("console_exec", {"cmd": "load pba_test", "wait_frames": 10})
    ok = wait_realms(gen0)
    time.sleep(4)  # AdoptAmbients (next tick) and the loops subscription tick
    after = lua("server", STATE) if ok else None
    if after is not None:
        after["mirrors"] = lua("client", MIRRORS)
    lines = [ln.get("text", "") for ln in call("console_read", {"cursor": cur, "limit": 5000}).get("lines", [])]
    load_errs = call("errors_since", {"cursor": ecur, "limit": 200}).get("errors") or []
    restored = sorted({m.group(1) for ln in lines for m in [re.match(r"(?:Static|Dynamic)Sound (\S+) :", ln)] if m
                       and "loop" in m.group(1)})
    stopped = sorted({m.group(1) for ln in lines for m in [re.match(r"S_StartStaticSound: (\S+) Stopped", ln)] if m})
    res.update({"setup_fire": setup, "before": before, "after": after, "engine_loop_starts_after_load": restored,
                "engine_stops_after_load": stopped, "pba_errors": load_errs[:5]})
    if after:
        names = {a["key"].split(":", 1)[0] for a in after["active"]}
        missing = [a for a in after["ambients"] if str(a["idx"]) not in names]
        near = [a for a in after["ambients"] if a["d"] < 600]
        mirrored = all(any(m.startswith(f"{a['idx']}:") for m in (after["mirrors"] or [])) for a in near)
        stopped_ok = all(any(a["wav"].replace("/", "\\").lower() in s.lower() for s in stopped) for a in near)
        res["missing_ambients"] = missing
        res["near_ambients_mirrored"] = mirrored
        res["near_engine_copy_stopped"] = stopped_ok
        res["lua_loop_after_load"] = any("steam_loop1" in a["name"] for a in after["active"]) or \
            any("steam_loop1" in s for s in restored)
        res["pass"] = bool(near) and not missing and mirrored and stopped_ok and after["stale"] == 0 and not load_errs
finally:
    for n, v in cv0.items():
        if v is not None:
            call("console_exec", {"cmd": f"{n} {v}"})
    # the save and the level-transition files it wrote
    for f in ("pba_test.sav", "pba_test.tga", "d1_town_01.HL1", "d1_town_01.HL2", "d1_town_01.HL3"):
        try:
            os.remove(os.path.join(GAME, "save", f))
        except OSError:
            pass
print(json.dumps(res, indent=1, ensure_ascii=False))
