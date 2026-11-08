"""Native rendering check (needs gmcl_pba + phonon.dll in lua/bin): with
pba_native_render 1, measures the left / right output energy of the module's mixer while
a scenario plays. Measures the interaural time difference of the module's mix (cross-correlation
lag, RenderDebug): door on the right -> the right ear leads (negative lag), and so on. Energy is
not a good cue here: the voices are low-passed, and below ~1.5 kHz direction is carried by the ITD.
Usage: python -I native_lr.py <mcp.py>
"""
import json
import subprocess
import sys
import time

MCP = sys.argv[1]


def call(tool, args, mx=2_000_000):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), str(mx)],
                         capture_output=True, text=True, encoding="utf-8").stdout
    try:
        return json.loads(out)
    except Exception:
        return {}


sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.abspath(__file__)))
import _cvsnap  # restores every pba_* setting at exit, even on failure
_cvsnap.guard(call)


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


CASES = [("tworooms_open", "pba_tworooms", "R"), ("tworooms_left", "pba_tworooms", "L"),
         ("window", "pba_window", "L"), ("twodoors_south", "pba_twodoors", "R"), ("lcorridor", "pba_lcorridor", "C")]
results = []
# the test changes archived client convars: keep the user's values and restore them at the end
saved = None
for sc, m, want in CASES:
    if call("status", {}).get("map") != m:
        call("map_load", {"map": m, "maxplayers": 4})
        time.sleep(3)
    if saved is None:
        saved = lua("client", "local c = pba.cfg return { c.native_render, c.native_reverb, c.native_echo }")
    call("console_exec", {"realm": "client", "cmd": "pba_native_render 1"})
    # direction of the direct paths only: reflections (room reverb, echoes) off during the measure
    call("console_exec", {"realm": "client", "cmd": "pba_native_reverb 0"})
    call("console_exec", {"realm": "client", "cmd": "pba_native_echo 0"})
    time.sleep(1.0)
    call("console_exec", {"realm": "server", "cmd": f"pba_demo {sc} voice 1.5"})
    time.sleep(1.5)
    lua("client", "pba_native.RenderDebug()")
    time.sleep(4)
    d = lua("client", "local a, b = pba_native.RenderDebug() return { lag = b.y, eL = a.y, eR = a.z, render = pba.Native.render }") or {}
    call("console_exec", {"realm": "server", "cmd": "pba_demo stop"})
    lag, tot = d.get("lag", 0), d.get("eL", 0) + d.get("eR", 0)
    ok = tot > 0 and ((want == "R" and lag <= -3) or (want == "L" and lag >= 3) or (want == "C" and abs(lag) <= 8))
    results.append((sc, ok))
    print(("PASS " if ok else "FAIL ") + f"N-{sc}: ITD lag={lag} samples ({lag / 48:.2f} ms), energy={tot:.3g} (want {want})", flush=True)
if saved:
    for name, v in zip(("native_render", "native_reverb", "native_echo"), saved):
        call("console_exec", {"realm": "client", "cmd": f"pba_{name} {v}"})
print(f"\n{sum(1 for _, o in results if o)}/{len(results)} passed")
