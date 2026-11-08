"""One-shot followed while it plays (pba_oneshot_follow): pba_demo room 6 (court), container obstacle,
the radio says question06.wav (3.4 s). The player stands at the court's listening point, behind the
container; the client job (oneshot_follow.lua) keeps the listener there until the line starts, then
steps it into clear sight of the radio. Fails when the heard voice has not reached the radio within
0.6 s of the step, or ends more than 2 dB from the direct level, or the line restarts.
Native rendering (mode C) then engine rendering (mode B, the Light version).
Usage: python -I -u oneshot_follow.py <mcp.py> [--set=pba_x=v ...]
  --set=pba_oneshot_follow=0 shows the bug (expected FAIL: the voice stays beside the container).
"""
import json
import os
import subprocess
import sys
import time

MCP = sys.argv[1]
SETS = [a[len("--set="):] for a in sys.argv[2:] if a.startswith("--set=")]
TEST = os.path.dirname(os.path.abspath(__file__))


def call(tool, args, mx=2_000_000, timeout=300):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), str(mx)],
                         capture_output=True, text=True, encoding="utf-8", timeout=timeout).stdout
    try:
        return json.loads(out)
    except ValueError:
        return {"raw": out}


sys.path.insert(0, TEST)
import _cvsnap  # restores every pba_* setting at exit, even on failure
_cvsnap.guard(call)


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


st = call("status", {})
if st.get("map") != "pba_demo":
    call("map_load", {"map": "pba_demo", "maxplayers": 4})
    time.sleep(4)
for s in SETS:
    name, val = s.split("=", 1)
    call("console_exec", {"realm": "client", "cmd": f"{name} {val}"})

# the court: listening point, radio, container (pressing 'Container' also plays the line once)
info = lua("server", """local DM = pba.DemoMap local r = DM.byId.court
local src = ents.FindByName('pba_court_src')[1]
local c = src:WorldSpaceCenter()
return { L = { r.listenPos.x, r.listenPos.y, r.listenPos.z }, S = { c.x, c.y, c.z }, idx = src:EntIndex() }""")
if not info:
    print("FAIL no court room / radio on this map")
    sys.exit(1)
L1 = [info["L"][0], info["L"][1], info["L"][2] + 64]


def run(mode):
    lua("server", f"pba.DemoMap.SetMode({mode}) return true")
    want = "true" if mode == 3 else "false"
    for _ in range(90):  # mode C: the module back and rendering; mode B: rendering off
        if lua("client", f"local n = pba.Native return (n ~= nil and n.render == true and not n.building) == {want}"):
            break
        time.sleep(1)
    else:
        return {"pass": False, "why": f"mode {mode}: native rendering never became {want}"}
    lua("server", f"""local p = player.GetHumans()[1] p:SetPos(Vector({info['L'][0]}, {info['L'][1]}, {info['L'][2]}))
p:SetEyeAngles((Vector({info['S'][0]}, {info['S'][1]}, {info['S'][2]}) - p:EyePos()):Angle())
local DM = pba.DemoMap DM.Press(DM.byId.court, {{ id = 'container' }}, p) return true""")
    time.sleep(4.5)  # the line played by the container button ends
    lua("server", """local DM = pba.DemoMap local p = player.GetHumans()[1]
timer.Simple(1.5, function() DM.Press(DM.byId.court, { id = 'play' }, p) end) return true""")
    code = open(os.path.join(TEST, "oneshot_follow.lua"), encoding="utf-8").read()
    r = call("lua_job", {"realm": "client", "code": code, "timeout_s": 30,
                         "args": {"S": info["S"], "L1": L1, "srcIdx": info["idx"], "step": 0.8}}, timeout=90)
    time.sleep(1)
    return (r.get("values") or [r])[0] if isinstance(r, dict) else r


ok = True
for mode, label in ((3, "native (mode C)"), (2, "engine (mode B)")):
    res = run(mode)
    good = isinstance(res, dict) and res.get("pass") is True
    ok = ok and good
    print(("PASS" if good else "FAIL") + f" {label}: {json.dumps(res, ensure_ascii=False)}", flush=True)
lua("server", "local DM = pba.DemoMap DM.ResetRoom(DM.byId.court) return true")
sys.exit(0 if ok else 1)
