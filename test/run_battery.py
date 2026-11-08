"""Full PBA test battery, sequential (about 15 min; the game changes maps). Prints one ##progress line
per step and a summary. Usage: python -I -u run_battery.py <path to mcp.py> [--quick | --only=step,step]. Needs ffmpeg on
PATH. --quick: the fast checks only (about 2 minutes), to run before each commit."""
import json, os, subprocess, sys, time
TEST = os.path.dirname(os.path.abspath(__file__))
MCP = sys.argv[1]  # path to the gmod-mcp client (mcp.py)
GAME = r"D:\SteamLibrary\steamapps\common\GarrysMod\garrysmod"
sys.path.insert(0, TEST)

def call(tool, args, mx=200000, timeout=600):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), str(mx)],
                         capture_output=True, text=True, encoding="utf-8", timeout=timeout).stdout
    try:
        return json.loads(out)
    except ValueError:
        return {"raw": out}

import _cvsnap
_cvsnap.guard(call)

def load(m, mp=4):
    st = call("status", {})
    if st.get("map") != m or st.get("maxplayers") != mp:
        call("map_load", {"map": m, "maxplayers": mp}, timeout=300)
        time.sleep(4)
    for _ in range(60):
        # the demo map holds the module aside outside mode C (pba_demoHeld): loaded all the same
        r = call("lua_exec", {"realm": "client", "code": "local N = pba.Native return N == nil or pba_native == nil or (not N.building and (N.ready == true or N.pba_demoHeld == true))"})
        if r.get("values") == [True]:
            break
        time.sleep(2)

def job(realm, file, timeout_s=120):
    code = open(os.path.join(TEST, file), encoding="utf-8").read()
    r = call("lua_job", {"realm": realm, "code": code, "timeout_s": timeout_s}, timeout=timeout_s + 60)
    return r.get("values", [r])[0] if isinstance(r, dict) else r

def py(script, *args, timeout=1500):
    p = subprocess.run([sys.executable, "-I", os.path.join(TEST, script), MCP, *args], capture_output=True,
                       text=True, encoding="utf-8", timeout=timeout)
    return (p.stdout + p.stderr)[-2500:]

def doors_open(m="pba_twodoors"):
    load(m)
    call("lua_exec", {"realm": "server", "code": "for _, n in ipairs({'door_s', 'door_n'}) do for _, d in ipairs(ents.FindByName(n)) do d:Fire('Open') end end return true"})
    time.sleep(3)
    return "ok"

def door(action):
    """pba_demo boombox room: mode C, door opened or closed (the sweep waits for its state)."""
    call("lua_exec", {"realm": "server", "code": "pba.DemoMap.SetMode(3) ents.FindByName('pba_boombox_door')[1]:Fire('%s') return true" % action})
    time.sleep(3)
    return "ok"

results = []
def step(i, n, label, fn):
    print(f'##progress step={i}/{n} label="Battery" msg="{label}"', flush=True)
    t0 = time.time()
    try:
        out = fn()
    except Exception as e:
        out = f"EXCEPTION {e!r}"
    dt = time.time() - t0
    txt = out if isinstance(out, str) else json.dumps(out, ensure_ascii=False)
    results.append((label, round(dt), txt))
    print(f"=== {label} ({dt:.0f}s)\n{txt[-1500:]}\n", flush=True)

def native_on(on):
    call("console_exec", {"realm": "client", "cmd": f"pba_native_render {1 if on else 0}"})
    time.sleep(1.5)

def make_ogg():
    d = os.path.join(GAME, "sound", "pba_test")
    os.makedirs(d, exist_ok=True)
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
                    "-c:a", "libvorbis", os.path.join(d, "tone.ogg")], check=False)

def drop_ogg():
    import shutil
    shutil.rmtree(os.path.join(GAME, "sound", "pba_test"), ignore_errors=True)

def pure():
    code = open(os.path.join(TEST, "gluatest", "run_pure.lua"), encoding="utf-8").read()
    import shutil
    shutil.copy(os.path.join(TEST, "gluatest", "pba_pure_test.lua"),
                os.path.join(GAME, "lua", "mcpagent_tmp", "pba_pure_test.lua"))
    return call("lua_exec", {"realm": "client", "code": code}).get("values")

steps = [
    ("load pba_tworooms", lambda: load("pba_tworooms") or "ok"),
    ("GLuaTest pure suite", pure),
    ("menu_fit", lambda: job("client", "menu_fit.lua")),
    # engine rendering: with "everything native" the server relays every sound to this client and the
    # "untouched" scenarios cannot hold (by design)
    ("run_scenarios", lambda: (native_on(False), py("run_scenarios.py"))[1]),
    ("ab_counts tworooms_open", lambda: (load("pba_tworooms"), py("ab_counts.py", "tworooms_open"))[1]),
    ("ab_counts lcorridor", lambda: py("ab_counts.py", "lcorridor")),
    ("native_lr", lambda: py("native_lr.py")),
    ("long_and_all", lambda: py("long_and_all.py")),
    ("moving_source", lambda: py("moving_source.py")),
    ("predicted_fire", lambda: py("predicted_fire.py")),
    ("lifecycle", lambda: py("lifecycle.py")),
    ("bot_gunfire", lambda: (load("pba_tworooms"), job("server", "bot_gunfire.lua"))[1]),
    ("loop_removed", lambda: job("server", "loop_removed.lua")),
    ("native_doors", lambda: (native_on(True), job("client", "native_doors.lua"))[1]),
    ("native_features", lambda: job("client", "native_features.lua")),
    ("streams_test", lambda: job("client", "streams_test.lua")),
    ("portal_sweep tworooms", lambda: job("client", "portal_sweep.lua")),
    ("water_ogg gm_construct", lambda: (load("gm_construct", 1), native_on(True), make_ogg(), job("client", "water_ogg.lua"), drop_ogg())[3]),
    ("paths_numeric_equiv pba_demo", lambda: (load("pba_demo", 1), job("client", "paths_numeric_equiv.lua"))[1]),
    # door leaf crossed by the line = its doorway (one model): no jump at the leaf / wall boundary
    # continuous sounds: no flip-flop between two equal paths, a real move still switches once
    ("path_hysteresis twodoors", lambda: (doors_open(), job("client", "path_hysteresis.lua"))[1]),
    # continuous sounds glide to each re-evaluation: no gain / EQ / direction step between frames
    ("continuous_ramp twodoors", lambda: py("continuous_ramp.py")),
    ("door_sweep open", lambda: (load("pba_demo"), door("Open"), job("client", "door_sweep.lua"))[2]),
    ("door_sweep closed", lambda: (door("Close"), job("client", "door_sweep.lua"))[1]),
    ("native_water", lambda: py("native_water.py")),  # still on pba_demo: one load less
    ("reverb_rt", lambda: py("reverb_rt.py")),
    ("native_options", lambda: py("native_options.py")),
    # room reverb tail EQ: air absorption counted once (Steam Audio bug 6, fixed in the fork's DLL)
    ("native_tail_eq", lambda: py("native_tail_eq.py")),
    # props on the paths through openings (portal and probe paths), not only on the straight line
    ("path_obstruction", lambda: py("path_obstruction.py")),
    # path quality against an independent single-bend reference (maps without areaportals: probes)
    ("path_quality", lambda: py("path_quality.py", "--check", "d1_town_01", "gm_construct")),
    # the path SEARCH through pba_demo's doorways (doors opened) against the single-bend reference, same
    # physics: the diffuse leak through an opening (portal_diffuse_db) is a model the reference lacks
    ("path_quality pba_demo search", lambda: py("path_quality.py", "--check", "--set=pba_portal_diffuse_db=60",
                                                "--max-under6=0.05", "--max-over6=0.05", "pba_demo")),
    # the listener field alone (no immediate search): no cold silence beyond the warm ones
    ("path_quality field only", lambda: py("path_quality.py", "--check", "--no-gap", "--set=pba_probe_inline_ms=0",
                                           "d1_town_01", "gm_construct")),
]
# --quick: the fast checks (about 2 minutes, two maps) to run before each commit; the full battery
# before merging into main or a release
QUICK = {"load pba_tworooms", "GLuaTest pure suite", "menu_fit", "portal_sweep tworooms", "bot_gunfire",
         "loop_removed", "native_doors", "native_features", "path_hysteresis twodoors", "door_sweep open",
         "door_sweep closed"}
if "--quick" in sys.argv[2:]:
    steps = [s_ for s_ in steps if s_[0] in QUICK]
    # bot_gunfire and portal_sweep expect pba_tworooms: keep it loaded for them
    steps = [("load pba_tworooms", lambda: load("pba_tworooms") or "ok")] + [s_ for s_ in steps if s_[0] != "load pba_tworooms"]
# --only=a,b: just these steps (exact names), in battery order, after loading pba_tworooms
ONLY = next((a[len("--only="):].split(",") for a in sys.argv[2:] if a.startswith("--only=")), None)
if ONLY:
    steps = [("load pba_tworooms", lambda: load("pba_tworooms") or "ok")] + [s_ for s_ in steps if s_[0] in ONLY]
for i, (label, fn) in enumerate(steps, 1):
    step(i, len(steps), label, fn)
print("##progress done=ok", flush=True)
print("\n===== SUMMARY =====")
for label, dt, txt in results:
    print(f"{label} ({dt}s): {txt[-300:]}")
