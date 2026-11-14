"""T12 doppler_render + T13 air_absorption_render: what a moving or distant source is really handed to the
module with, measured at the boundary of the audio thread (pba_native.Play / Update arguments of a real
EmitSound from a real prop through the whole addon path: hook, render choice, followers), not on the formulas.
Map gm_flatgrass (open field, clear line), the listener frozen at the spawn, native rendering, pba_native_all 1.
  T12 a prop flying at 1000 u/s (frozen drag and gravity) emits a loud shot every 0.4 s:
      approaching, the pitch given to the voices is c / (c - v) = 1.0588 (measured 105.88 %), receding 0.9474 (94.74 %);
      bound +-2 % of the formula computed from the entity's measured velocity; a still source: 100 %;
      pba_native_doppler 0: 100 % in both directions
  T13 the same still source at 10 m (525 u) and at 100 m (5249 u): the high band given to the voice is lower at
      100 m by exp(-0.0182 x 90 m) = -14.2 dB (bound -14 +-4); pba_native_air 0: < 1 dB apart
PBA_T_RED=1 breaks the feature under test (doppler 0 / air 0 during the "on" measures): the test must go red.
Usage: python -I -X utf8 doppler_air_render.py <mcp.py>
"""
import json
import math
import os
import statistics
import subprocess
import sys
import time

MCP = sys.argv[1]
RED = os.environ.get("PBA_T_RED") == "1"


def call(tool, args, mx=2_000_000, timeout=400):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), str(mx)],
                         capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout).stdout
    try:
        return json.loads(out)
    except ValueError:
        return {"raw": out}


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _cvsnap  # restores every pba_* setting at exit, even on failure
_cvsnap.guard(call)


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


def job(realm, code, timeout_s=120):
    r = call("lua_job", {"realm": realm, "code": code, "timeout_s": timeout_s}, timeout=timeout_s + 60)
    v = r.get("values")
    return v[0] if v else r


def cmd(realm, c):
    call("console_exec", {"realm": realm, "cmd": c})


def wait_lua(realm, code, timeout=15.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if lua(realm, code) is True:
            return True
        time.sleep(1.0)
    return False


results = []


def check(name, cond, detail):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name + " :: " + detail, flush=True)


READY = "local N = pba.Native return N ~= nil and not N.building and N.ready == true and N.render == true"
# listener frozen at the spawn, one prop (no gravity, no drag) at x with velocity vx, shooting every 0.4 s
SV = """for _, e in ipairs(ents.FindByClass('prop_physics')) do if e.PBA_T12 then e:Remove() end end
timer.Remove('pba_t12')
local p = player.GetHumans()[1]
p:SetPos(Vector(0, 0, -12287)) p:SetEyeAngles(Angle(0, 0, 0)) p:Freeze(true)
local e = ents.Create('prop_physics') e:SetModel('models/props_junk/PopCan01a.mdl')
e:SetPos(Vector(%d, 0, -12150)) e:Spawn() e.PBA_T12 = true
local ph = e:GetPhysicsObject() ph:EnableGravity(false) ph:EnableDrag(false)
ph:SetVelocity(Vector(%d, 0, 0)) %s
timer.Create('pba_t12', 0.4, 0, function() if IsValid(e) then e:EmitSound('weapons/ar2/fire1.wav', 140, 100, 1) end end)
return true"""
CLEAN = "for _, e in ipairs(ents.FindByClass('prop_physics')) do if e.PBA_T12 then e:Remove() end end timer.Remove('pba_t12') player.GetHumans()[1]:Freeze(false) return true"
# records the arguments of every Update in a window (pitch, high band), median of each; v = the prop's velocity
CL = """local pitch, eqh, n = {}, {}, 0
local upd = pba_native.Update
pba_native.Update = function(id, ...) local a = { ... } pitch[#pitch + 1] = a[6] eqh[#eqh + 1] = a[5] return upd(id, ...) end
job:sleep(%f) pitch, eqh = {}, {}
job:sleep(%f)
pba_native.Update = upd
local e for _, x in ipairs(ents.FindByClass('prop_physics')) do e = x end
table.sort(pitch) table.sort(eqh)
return { n = #pitch, pitch = pitch[math.ceil(#pitch / 2)], eqh = eqh[math.ceil(#eqh / 2)], vx = IsValid(e) and e:GetVelocity().x or nil }"""


def measure(x, vx, cvs, warm=1.5, win=2.0):
    for k, v in cvs.items():
        cmd("client", f"{k} {v}")
    time.sleep(0.5)
    lua("server", SV % (x, vx, ""))
    r = job("client", CL % (warm, win))
    lua("server", CLEAN)
    return r


C = 343 / 0.01905  # speed of sound in units / s
try:
    call("map_load", {"map": "gm_flatgrass", "maxplayers": 4}, timeout=300) if call("status", {}).get("map") != "gm_flatgrass" else None
    cmd("client", "pba_native_render 1")
    cmd("client", "pba_native_all 1")
    check("T12-module-up", wait_lua("client", READY, 120), "native module ready and rendering on gm_flatgrass")
    time.sleep(2)
    on = {"pba_native_doppler": 0 if RED else 1, "pba_native_air": 0 if RED else 1}
    # --- T12 Doppler
    app = measure(8000, -1000, on)
    rec = measure(500, 1000, on)
    still = measure(2000, 0, on)
    print("approach", app, "recede", rec, "still", still, flush=True)
    for name, r, sign in (("approach", app, 1), ("recede", rec, -1)):
        if r and r.get("n", 0) >= 3 and r.get("vx") is not None:
            v = abs(r["vx"])  # the unit vector source -> listener is along the velocity (approach) or against it
            want = 100 * C / (C - sign * v)
            check(f"T12-{name}", abs(r["pitch"] - want) <= 2, f"pitch given to the voices {r['pitch']:.2f} % vs c/(c -+ v) = {want:.2f} % at {v:.0f} u/s ({r['n']} updates; 105.88 / 94.74 measured, bound +-2)")
        else:
            check(f"T12-{name}", False, f"no measure: {r}")
    check("T12-still", bool(still) and still.get("n", 0) >= 3 and abs(still["pitch"] - 100) <= 0.5, f"still source: {still and still.get('pitch')} % (bound 100 +-0.5)")
    off = measure(8000, -1000, {"pba_native_doppler": 0})
    check("T12-doppler-off", bool(off) and off.get("n", 0) >= 3 and abs(off["pitch"] - 100) <= 0.5, f"pba_native_doppler 0, same flight: {off and off.get('pitch')} % (bound 100 +-0.5)")
    # --- T13 air absorption
    near = measure(525, 0, on)
    far = measure(5249, 0, on)
    print("near", near, "far", far, flush=True)
    if near and far and near.get("n", 0) >= 3 and far.get("n", 0) >= 3 and near["eqh"] > 0 and far["eqh"] > 0:
        d = 20 * math.log10(far["eqh"] / near["eqh"])
        check("T13-air", -18 <= d <= -10, f"high band at 100 m vs 10 m: {d:.1f} dB (-14.2 measured and by exp(-0.0182 x 90 m), bound -14 +-4)")
    else:
        check("T13-air", False, f"no measure: {near} / {far}")
    cmd("client", "pba_native_air 0")
    near0 = measure(525, 0, {"pba_native_air": 0})
    far0 = measure(5249, 0, {"pba_native_air": 0})
    if near0 and far0 and near0.get("n", 0) >= 3 and far0.get("n", 0) >= 3 and near0["eqh"] > 0 and far0["eqh"] > 0:
        d0 = 20 * math.log10(far0["eqh"] / near0["eqh"])
        check("T13-air-off", abs(d0) < 1, f"pba_native_air 0: {d0:.2f} dB apart (bound < 1)")
    else:
        check("T13-air-off", False, f"no measure: {near0} / {far0}")
finally:
    lua("server", CLEAN)

print(f"{sum(results)}/{len(results)} passed")
sys.exit(0 if results and all(results) else 1)
