"""Steam Audio options of the native module.
1. Ray tracer cost: reflection thread (main + long-window reverb) with Embree vs the built-in tracer,
   on pba_tworooms and pba_demo (printed; check: Embree not slower).
2. Baked room reverb (pba_native_baked_reverb): the bake finishes, the reverb time then comes from the
   probes, within 35 % of the run-time estimate (pba_tworooms).
3. Echo directivity: on gm_flatgrass (only the ground reflects), a cardioid source (dipole 0.5) aimed at
   the ground must echo far more than the same source aimed at the sky (its rear lobe is zero).
   Without directivity both are equal.
Usage: python -I -u native_options.py <mcp.py>
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
_cvsnap.guard(call)


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


def cvar(name, value):
    call("console_exec", {"realm": "client", "cmd": f"{name} {value}"})


def load(m):
    if call("status", {}).get("map") != m:
        call("map_load", {"map": m, "maxplayers": 4})
        time.sleep(3)
    return ready()


def ready():
    for _ in range(120):
        if m_is_demo():
            lua("server", "pba.DemoMap.SetMode(3) return true")
        if lua("client", "return pba.Native and pba.Native.ready and pba.Native.render and not pba.Native.building or false"):
            return True
        cvar("pba_native_render", 1)
        time.sleep(1)
    return False


def m_is_demo():
    return call("status", {}).get("map") == "pba_demo"


def rebuild():
    lua("client", "pba.Native.Start() return true")
    time.sleep(2)
    return ready()


results = []


def check(name, ok, info):
    results.append((name, ok))
    print(("PASS " if ok else "FAIL ") + name + ": " + info, flush=True)


def cost(samples=12):
    """Average reflection-thread pass time (ms) over a few seconds, listener moving a little."""
    lua("client", "pba_native.Stats() return true")
    refl, rev = [], []
    for k in range(samples):
        lua("server", f"local p = player.GetAll()[1] p:SetPos(p:GetPos() + Vector({(-1) ** k * 40}, 0, 0)) return true")
        time.sleep(1)
        s = lua("client", "local s = pba_native.Stats() return { s.reflMs, s.revMs, s.backend }")
        refl.append(s[0])
        rev.append(s[1])
    return sum(refl) / len(refl), sum(rev) / len(rev), s[2]


cvar("pba_native_render", 1)
cvar("pba_native_reverb", 0.15)

# ---- 1. Embree vs built-in
for m in ("pba_tworooms", "pba_demo"):
    if not load(m):
        check(f"cost-{m}", False, "native module not ready")
        continue
    if m == "pba_demo":
        lua("server", "local DM = pba.DemoMap local b = DM.byId.reverb.boxes[1] local p = player.GetAll()[1] "
            "p:SetPos(Vector((b[1]+b[4])/2,(b[2]+b[5])/2,b[3]+2)) return true")
    res = {}
    for scene in (0, 1):
        cvar("pba_native_scene", scene)
        time.sleep(1)
        rebuild()
        time.sleep(6)
        res[scene] = cost()
        print(f"  {m} {res[scene][2]:8s}: reflections {res[scene][0]:.2f} ms, long reverb {res[scene][1]:.2f} ms", flush=True)
    t0, t1 = res[0][0] + res[0][1], res[1][0] + res[1][1]
    check(f"cost-{m}", res[1][2] == "embree" and t1 <= t0 * 1.1,
          f"built-in {t0:.2f} ms, Embree {t1:.2f} ms per pass ({t0 / max(t1, 1e-3):.1f}x)")
cvar("pba_native_scene", 1)

# ---- 2. baked reverb
if load("pba_tworooms"):
    rebuild()
    time.sleep(8)
    live = lua("client", "return pba_native.Stats().rtMid")
    cvar("pba_native_baked_reverb", 1)
    st, t0 = None, time.time()
    while time.time() - t0 < 240:
        time.sleep(2)
        st = lua("client", "return pba.Native.revBake or 'none'")
        if st in ("ready", "error"):
            break
    time.sleep(8)
    s = lua("client", "local s = pba_native.Stats() return { s.rtSource, s.rtMid }") or ["?", 0]
    ok = st == "ready" and s[0] == "baked" and live > 0 and abs(s[1] / live - 1) <= 0.35
    check("baked-reverb", ok, f"bake {st} in {time.time() - t0:.0f} s, source {s[0]}, RT mid baked {s[1]:.2f} s vs run time {live:.2f} s")
    cvar("pba_native_baked_reverb", 0)
else:
    check("baked-reverb", False, "native module not ready")

# ---- 3. echo directivity
if load("gm_flatgrass"):
    cvar("pba_native_reverb", 0)  # the room reverb would add energy of its own
    cvar("pba_native_echo", 1)
    time.sleep(3)  # the player stands on the ground at spawn
    snd = "weapons/357/357_fire2.wav"
    lua("client", f"pba.Native.EnsureSound('{snd}') return true")
    time.sleep(1)
    energy = {}
    for k, (label, aim) in enumerate((("ground", "Vector(0, 0, -1)"), ("sky", "Vector(0, 0, 1)"), ("ground", "Vector(0, 0, -1)"), ("sky", "Vector(0, 0, 1)"))):
        e = lua("client", f"""local ok, n = pba.Native.EnsureSound('{snd}')
local P = LocalPlayer():GetPos() + Vector(300, 0, 40)
pba_native.RenderDebug()
pba_native.Echo(n, P, 1, {9000 + k}, 100, 0, {aim}, 0.5)
return true""")
        time.sleep(2.0)
        d = lua("client", "local a = pba_native.RenderDebug() return a.y + a.z")
        energy.setdefault(label, []).append(d or 0)
        print(f"  echo aimed at the {label}: energy {d:.4g}", flush=True)
    g, s_ = sum(energy["ground"]) / 2, sum(energy["sky"]) / 2
    check("echo-directivity", g > 0 and g > 4 * s_, f"aimed at the ground {g:.4g}, at the sky {s_:.4g} (want ground > 4x sky)")
else:
    check("echo-directivity", False, "native module not ready on gm_flatgrass")

n = sum(1 for _, ok in results if ok)
print(f"{n}/{len(results)} passed", flush=True)
sys.exit(0 if n == len(results) else 1)
