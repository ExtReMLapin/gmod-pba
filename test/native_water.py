"""Water in the Steam Audio scene (pba_native_water): pba_demo room 8, a radio on the pool floor.
With water: the surface stands between the radio and a point right above it (Steam Audio occlusion
~0), and the scene has more triangles. Without (the old behaviour): clear line (occlusion ~1).
The reverb time at the pool side is printed (not checked: the water hides the tiled pool, so the
volume shrinks while the surface reflects as much as the tile).
Usage: python -I -u native_water.py <mcp.py>
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
import _cvsnap  # restores every pba_* setting at exit
from _wait import wait_stable
_cvsnap.guard(call)


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


def ready():
    for _ in range(90):
        lua("server", "pba.DemoMap.SetMode(3) return true")
        if lua("client", "return pba.Native and pba.Native.ready and pba.Native.render and not pba.Native.building or false"):
            return True
        time.sleep(1)
    return False


if call("status", {}).get("map") != "pba_demo":
    call("map_load", {"map": "pba_demo", "maxplayers": 4})
    time.sleep(3)
call("console_exec", {"realm": "client", "cmd": "pba_native_render 1"})
src = lua("server", "local e = ents.FindByName('pba_pool_src')[1] local p = e:GetPos() return { p.x, p.y, p.z }")
lua("server", f"local p = player.GetAll()[1] p:SetPos(Vector({src[0]}, {src[1]} + 240, 0)) return true")
res = {}
for w in (0, 1):
    call("console_exec", {"realm": "client", "cmd": f"pba_native_water {w}"})
    time.sleep(1)
    lua("client", "pba.Native.Start() return true")  # rebuild even if the demo held the module aside
    time.sleep(2)
    if not ready():
        print(f"FAIL native module not ready (water {w})")
        sys.exit(1)
    # the occlusion is fixed once the scene is built; the reverb time (printed only) settles in a few s
    wait_stable(lambda: lua("client", "return pba_native.Stats().rtMid"), tol=0.03, n=3, tmin=2.0, tmax=10)
    res[w] = lua("client", f"""local S = Vector({src[0]}, {src[1]}, {src[2]} + 64) -- above the radio (in the scene), still under water
local d = pba_native.Direct({{ S }}, S + Vector(0, 0, 200), 2)[1]
local s = pba_native.Stats()
return {{ d.occlusion, pba.Native.nMats or 0, s.rtMid }}""")
    print(f"  water {w}: occlusion radio -> above {res[w][0]:.2f}, {res[w][1]} materials, RT mid at the pool side {res[w][2]:.2f} s", flush=True)

ok1 = res[0][0] > 0.9 and res[1][0] < 0.1
ok2 = res[1][1] == res[0][1] + 1
print(("PASS " if ok1 else "FAIL ") + f"water-occludes: without {res[0][0]:.2f} (want > 0.9), with {res[1][0]:.2f} (want < 0.1)")
print(("PASS " if ok2 else "FAIL ") + f"water-in-scene: {res[0][1]} -> {res[1][1]} materials (one more: the water)")
sys.exit(0 if ok1 and ok2 else 1)
