"""T7 option_sweep: every option of A.CONFIG at its minimum, maximum and default, in both realms, on several
scenes (pba_tworooms door closed / ajar, pba_twodoors, pba_lcorridor, pba_noportal, pba_demo): no Lua error (the
game's error channel is read before and after), no NaN / inf in the voices P.Compute returns, and for every
option listed in test/option_sweep_expect.json the table of what position 0 must give:
  pos0 "differs"  min and max give different voices on at least one scene (the option is wired to the model)
  pos0 "same"     they never differ on these scenes (the reason says why: the scenes do not exercise it)
  pos0 "hook"     acts outside P.Compute (hooks, relay, native rendering): not judged here, only swept for errors
The server realm also plays a sound at every position (relay and re-emission paths run with the option set).

Usage: python -I option_sweep.py <mcp.py> [--measure] [--judge] [--pre=file.lua] [--scenes=a,b] [--only=opt,opt]
  --judge     judge the position 0 table even on a partial scene list (red proofs)
  --measure   prints, for every option, whether min / max differ (to write or review the expectation table)
"""
import json, os, re, subprocess, sys, time

TEST = os.path.dirname(os.path.abspath(__file__))
MCP = sys.argv[1]
opts = sys.argv[2:]
EXPECT = os.path.join(TEST, "option_sweep_expect.json")


def call(tool, args, mx=2000000, timeout=900):
    a = json.dumps(args)
    if len(a) > 20000:
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as f:
            f.write(a)
        a = "@" + f.name
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, a, str(mx)], capture_output=True, text=True,
                         encoding="utf-8", errors="replace", timeout=timeout).stdout
    if a.startswith("@"):
        os.remove(a[1:])
    try:
        return json.loads(out)
    except ValueError:
        return {"raw": out}


sys.path.insert(0, TEST)
import _cvsnap
_cvsnap.guard(call)

# scene: (map, pba_demo scenario that sets the doors, or None)
# the server realm (sound emission at each position too) runs on three of them: the code is the same
SCENES = {
    "tworooms_closed": ("pba_tworooms", "tworooms_closed", ("client", "server")),
    "tworooms_half": ("pba_tworooms", "tworooms_half", ("client",)),
    "twodoors": ("pba_twodoors", "twodoors_south", ("client", "server")),
    "lcorridor": ("pba_lcorridor", None, ("client",)),
    "noportal": ("pba_noportal", None, ("client",)),
    "demo": ("pba_demo", "OPEN_BOOMBOX", ("client", "server")),
}
# extra scenes (same maps, a Lua scene of option_sweep.lua and what the realms need set up around it):
# name -> (map, demo scenario, realms, lua scene, server setup, client setup, client teardown, server teardown)
PROP_SPAWN = """if IsValid(PBA_OBS) then PBA_OBS:Remove() end
local e = ents.Create('prop_physics') e:SetModel('models/props_interiors/VendingMachineSoda01a.mdl')
e:SetPos(Vector(550, 90, 0)) e:SetAngles(Angle(0, 180, 0)) e:Spawn()
local ph = e:GetPhysicsObject() if IsValid(ph) then ph:EnableMotion(false) end
local mn = e:WorldSpaceAABB() e:SetPos(Vector(550 - (mn.x - 526), 90, -e:OBBMins().z)) PBA_OBS = e return true"""
WATER_ON = """PBA_OLD_PC = PBA_OLD_PC or util.PointContents
util.PointContents = function(p) return ((p.x < 300 and p.z < 100) or (p.x > 500 and p.z < 200)) and CONTENTS_WATER or CONTENTS_EMPTY end return true"""
WATER_OFF = "if PBA_OLD_PC then util.PointContents = PBA_OLD_PC PBA_OLD_PC = nil end return true"
EXTRA = {
    "doorline_closed": ("pba_tworooms", "tworooms_closed", ("client",), "doorline", None, None, None, None),
    "doorline_half": ("pba_tworooms", "tworooms_half", ("client",), "doorline", None, None, None, None),
    "prop": ("pba_tworooms", "tworooms_open", ("client",), "prop", PROP_SPAWN, None, None, "if IsValid(PBA_OBS) then PBA_OBS:Remove() end return true"),
    "water": ("pba_tworooms", "tworooms_closed", ("client",), "water", None, WATER_ON, WATER_OFF, None),
}
SCENES.update(EXTRA)
want = next((a[9:].split(",") for a in opts if a.startswith("--scenes=")), list(SCENES))
only = next((a[7:].split(",") for a in opts if a.startswith("--only=")), None)

SOUND = """
local emitter
PBA_SWEEP_SOUND = function(name, pos)
	if not IsValid(emitter) then emitter = ents.Create("info_target") emitter:SetPos(Vector(784, 256, 40)) emitter:Spawn() end
	emitter:EmitSound("buttons/button14.wav", 80)
end
"""


def lua(realm, code, t=900):
    r = call("lua_job", {"realm": realm, "code": code, "timeout_s": t}, timeout=t + 60)
    v = r.get("values")
    return v[0] if v else r


def errors_count():
    return len(call("errors_since", {"cursor": 0, "limit": 2000}).get("errors", []))


def load(m):
    st = call("status", {})
    if st.get("map") != m:
        call("map_load", {"map": m, "maxplayers": 4}, timeout=300)
        time.sleep(4)
    for _ in range(60):
        if call("lua_exec", {"realm": "client", "code": "return pba ~= nil and pba.Paths ~= nil and IsValid(LocalPlayer())"}).get("values") == [True]:
            break
        time.sleep(2)
    for _ in range(30):  # the status may still say "loading" / no map for a moment after the client answered
        if call("status", {}).get("map") == m:
            return
        time.sleep(2)
    raise RuntimeError("map not loaded: " + m)


src = open(os.path.join(TEST, "option_sweep.lua"), encoding="utf-8").read()
# --pre=file.lua: Lua run in each realm just before the sweep (red proofs: break the model, see the sweep go red)
PRE = next((open(a[6:], encoding="utf-8").read() + chr(10) for a in opts if a.startswith("--pre=")), "")
pre = "PBA_SWEEP_ONLY = nil" + chr(10)  # a global of the realm: never left over from an earlier run
if only:
    pre += "PBA_SWEEP_ONLY = {" + ",".join(f"['{o}']=true" for o in only) + "}\n"

agg = {}      # option -> {"mm": bool, "min": bool, "max": bool}
problems = []
e0 = errors_count()
for name in want:
    m, demo, realms = SCENES[name][:3]
    ex = SCENES[name][3:] if len(SCENES[name]) > 3 else (None,) * 5
    load(m)
    if demo == "OPEN_BOOMBOX":
        call("lua_exec", {"realm": "server", "code": "for _, d in ipairs(ents.FindByName('pba_boombox_door')) do d:Fire('Open') end return true"})
        time.sleep(3)
    elif demo:
        call("console_exec", {"realm": "server", "cmd": f"pba_demo {demo}"})
        time.sleep(3.5)
        call("console_exec", {"realm": "server", "cmd": "pba_demo stop"})
        time.sleep(0.5)
    if ex[1]:
        lua("server", ex[1])
        time.sleep(1.5)
    if ex[2]:
        lua("client", ex[2])
    for realm in realms:
        scn = "PBA_SWEEP_SCENE = " + (f"'{ex[0]}'" if ex[0] else "nil") + chr(10)
        r = lua(realm, scn + PRE + pre + (SOUND if realm == "server" else "") + src)
        if not isinstance(r, dict) or "differs" not in r:
            problems.append(f"{name}/{realm}: sweep did not return: {json.dumps(r)[:200]}")
            continue
        n_opt = r["options"]
        print(f"{name}/{realm}: {n_opt} options x 3 positions, {r['couples']} couples, {len(r['errors'])} errors", flush=True)
        for e in r["errors"]:
            problems.append(f"{name}/{realm}: {e}")
        for o, d in r["differs"].items():
            a = agg.setdefault(o, {"mm": False, "min": False, "max": False})
            for k in a:
                a[k] = a[k] or bool(d[k])
    if ex[3]:
        lua("client", ex[3])
    if ex[4]:
        lua("server", ex[4])
    time.sleep(1)
e1 = errors_count()
if e1 > e0:
    errs = call("errors_since", {"cursor": 0, "limit": 2000}).get("errors", [])[e0:]
    for e in errs[:5]:
        problems.append("game Lua error: " + json.dumps(e)[:300])
    if len(errs) > 5:
        problems.append(f"... and {len(errs) - 5} more game Lua errors")

if "--measure" in opts:
    for o in sorted(agg):
        a = agg[o]
        print(f"{o:28} min!=max {a['mm']!s:5}  min!=def {a['min']!s:5}  max!=def {a['max']!s:5}")

# position 0 table
table = json.load(open(EXPECT, encoding="utf-8")) if os.path.exists(EXPECT) else {}
checked = 0
for o, row in table.items():
    if o not in agg or row["pos0"] == "hook" or (only and o not in only):
        continue
    if len(want) < len(SCENES) and "--judge" not in opts:
        continue  # a partial scene list cannot judge "same" (--judge: judge anyway, for the red proofs)
    checked += 1
    got = "differs" if agg[o]["mm"] else "same"
    if got != row["pos0"]:
        problems.append(f"position 0 of {o}: expected {row['pos0']} ({row['why']}), got {got}")
print(f"position 0 table: {checked} options judged, {len(table)} rows")
res = {"pass": not problems, "scenes": want, "options": len(agg), "problems": problems[:30]}
print(json.dumps(res, indent=1))
sys.exit(0 if not problems else 1)
