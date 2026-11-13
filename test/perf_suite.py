"""Perf bench (docs/PLAN_PERF.md), minimal version: S0 (idle overhead), S1 (barrels), S2 (mass breakage),
S8 (campaign map load + changelevel, probe / native caches moved aside then present).

Usage: MCP_INSTANCE=<id> python -I -u perf_suite.py <mcp.py> [--only=S0,S1,S2,S8] [--s0maps=a,b] [--variants=vue,mur]
       [--modes=off,engine,native] [--repeat=5] [--cold] [--diag] [--update-baseline]

ONE game instance on the machine (the others closed): parallel games distort every number.
Launch it with instances_launch preset normal (640x360): the suite sets fps_max 0 / fps_max_nofocus 0.

Per scenario and variant: fresh map, probes ready; with --cold one burst per mode with the path cache
invalidated (the first native burst of a game session also decodes its sounds: native cold); then one
discarded burst per mode and R repetitions, modes interleaved (off, engine, native, off, ...). Each burst:
reset (map cleanup, stopsound, native voices back to 0, garbage collected in both realms), scene setup,
2 s settle, collectors armed, burst fired from server timers 1 s later, 4.5 s recorded.
The collectors (test/perf/collector.lua, collector_sv.lua) only define hooks: they run outside the
gmod-mcp debug hook (which turns LuaJIT off), and nothing is sent to the game during a window.
--diag: one more pass per scenario in native mode with test/perf/diag.lua (cache hits, keys vs cells,
synchronous computations per frame); never timed. Needs pba_allow_debug 1 (set by the suite).

A burst is INVALID (not compared) when the system was not active: sounds processed 0 in a pba mode,
or the reset failed (voices left), or the scene did not reproduce (sounds seen off by more than 15 %
from the mode's median).
Prints per mode: median (and MAD) over repetitions of p50, p99, max, worst3, excess, hitches, PBA ms
per frame (p99, max, sum), KB allocated, GC drops, decode (ensure) ms, server us per sound.
Writes test/perf/last/<scenario>_<variant>.json; --update-baseline also writes
test/perf/baselines/<scenario>_<variant>__<mode>.json.
Exit codes: 0 ran, 2 some burst INVALID, 3 usage.
"""
import json, os, statistics, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
PERF = os.path.join(HERE, "perf")
if len(sys.argv) < 2 or sys.argv[1].startswith("--"):
    print(__doc__)
    sys.exit(3)
MCP = sys.argv[1]
OPTS = sys.argv[2:]


def opt(name, default):
    for a in OPTS:
        if a.startswith(f"--{name}="):
            return a.split("=", 1)[1]
    return default


ONLY = opt("only", "S1").split(",")
VARIANTS = opt("variants", "vue,mur").split(",")
MODES = opt("modes", "off,engine,native").split(",")
REPEAT = int(opt("repeat", "5"))
COLD = "--cold" in OPTS
DIAG = "--diag" in OPTS
UPDATE = "--update-baseline" in OPTS
PRE, POST, SETTLE = 1.0, 4.5, 2.0
SCENES = {"S1": ("s1_barrels.lua", "gm_construct"), "S2": ("s2_breaks.lua", "gm_construct")}
S0_MAPS = opt("s0maps", "gm_construct,d1_canals_01").split(",")
S8_FROM, S8_TO = "d1_canals_01", "d1_canals_01a"
GAME_DATA = os.environ.get("PBA_GAME_DIR", r"D:\SteamLibrary\steamapps\common\GarrysMod\garrysmod")
MODE_CVARS = {
    "off": ["pba_enable 0"],
    "engine": ["pba_enable 1", "pba_native_render 0"],
    "native": ["pba_enable 1", "pba_native_render 1", "pba_native_all 1"],
    "native_noecho": ["pba_enable 1", "pba_native_render 1", "pba_native_all 1", "pba_native_echo 0"],
}


def call(tool, args, timeout=600):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), "400000"],
                         capture_output=True, text=True, encoding="utf-8", timeout=timeout).stdout
    try:
        return json.loads(out)
    except ValueError:
        return {"raw": out[-400:]}


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


def con(cmd):
    call("console_exec", {"realm": "menu", "cmd": cmd})


def src(*parts):
    with open(os.path.join(PERF, *parts), encoding="utf-8") as f:
        return f.read()


sys.path.insert(0, HERE)
import _cvsnap  # every pba_* setting restored at exit
_cvsnap.guard(call)


def wait(realm, cond, timeout=60.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if lua(realm, "return " + cond):
            return True
        time.sleep(0.5)
    return False


def fresh_map(m):
    call("map_load", {"map": m, "maxplayers": 1}, timeout=300)
    time.sleep(3)
    wait("client", "pba.Probes == nil or pba.Probes.current ~= nil", 180)
    wait("client", "not pba.Native or not pba.Native.render or pba.Native.ready", 60)
    con("fps_max 0")
    con("fps_max_nofocus 0")
    lua("client", src("collector.lua"))
    lua("server", src("collector_sv.lua"))


def set_mode(mode):
    for c in MODE_CVARS[mode]:
        con(c)
    time.sleep(0.5)


def reset():
    con("stopsound")
    ok = wait("client", "(not pba_native or not pba_native.Stats or pba_native.Stats().voices == 0)"
                        " and (not pba.Loops or not pba.Loops.mirrors or next(pba.Loops.mirrors) == nil)", 10)
    lua("client", "collectgarbage('collect') return true")
    lua("server", "collectgarbage('collect') return true")
    return ok


def burst(scene_file, variant, mode, seed, invalidate=False):
    set_mode(mode)
    lua("server", src("scenes", scene_file))
    setup = lua("server", f"return PBA_SCENE.Setup({{ variant = '{variant}', seed = {seed} }})")
    clean = reset()
    if invalidate:
        lua("client", "pba.Paths.InvalidateCache() return true")
    time.sleep(SETTLE)
    lua("server", f"PBA_PERF_SV.Arm({PRE + POST}) return PBA_SCENE.Fire({PRE})")
    lua("client", f"PBA_PERF.Arm({PRE}, {POST}) return true")
    time.sleep(PRE + POST + 0.5)
    res = None
    for _ in range(20):
        res = lua("client", "return PBA_PERF.Result()")
        if res and res.get("done"):
            break
        time.sleep(0.5)
    res = res or {}
    res["server"] = lua("server", "return PBA_PERF_SV.Result()")
    res["setup"], res["clean"], res["mode"] = setup, clean, mode
    why = []
    if not clean:
        why.append("reset: voices or mirrors left")
    if mode != "off" and not res.get("processed"):
        why.append("system inactive: 0 sounds processed")
    if mode.startswith("native") and not res.get("voices"):
        why.append("native inactive: 0 voices")
    res["invalid"] = why
    return res


KEYS = ["p50", "p99", "max", "excess", "hitches", "over16", "pba_p99", "pba_max", "pba_sum", "kb_alloc", "gc_drops"]


def summarize(runs):
    out = {}
    for k in KEYS:
        vals = [r.get(k, 0) for r in runs]
        if not vals:
            continue
        med = statistics.median(vals)
        out[k] = {"med": round(med, 3), "mad": round(statistics.median([abs(v - med) for v in vals]), 3)}
    out["ensure_ms"] = statistics.median([r.get("ensure", {}).get("ms", 0) for r in runs]) if runs else 0
    out["sv_us_sound"] = statistics.median([(r.get("server") or {}).get("us_per_sound", 0) for r in runs]) if runs else 0
    out["sounds"] = statistics.median([r.get("processed", 0) for r in runs]) if runs else 0
    out["idle_p50"] = statistics.median([r.get("idle_p50", 0) for r in runs]) if runs else 0
    return out


def check_scene(runs):
    """Scene reproduced: sounds processed within 15 % of the mode's median (pba modes)."""
    seen = [r.get("processed", 0) for r in runs]
    if not seen or max(seen) == 0:
        return
    med = statistics.median(seen)
    for r in runs:
        if med and abs(r.get("processed", 0) - med) > 0.15 * med:
            r["invalid"].append(f"scene: {r.get('processed')} sounds vs median {med}")


def idle_window(secs):
    """Records secs seconds with nothing scripted (collector already loaded): frame times, PBA cost,
    native door sync (H7) and the server timers."""
    lua("server", f"PBA_PERF_SV.Arm({secs}) return true")
    lua("client", f"PBA_PERF.Arm(0.2, {secs}) return true")
    time.sleep(secs + 1)
    r = lua("client", "return PBA_PERF.Result()") or {}
    r["server"] = lua("server", "return PBA_PERF_SV.Result()")
    r["timers_sv"] = lua("server", "local t = {} for k, v in pairs(pba.perfTimers or {}) do t[k] = { ms = math.Round(v.sum, 2), n = v.n, max = math.Round(v.max, 2) } end return t")
    return r


def run_s0():
    """S0: idle 20 s per mode on each map (on - off = PBA's fixed overhead per frame)."""
    out = {}
    for mp in S0_MAPS:
        fresh_map(mp)
        lua("server", "local p = player.GetAll()[1] p:GodEnable() return true")
        for m in MODES * 2:  # interleaved, twice
            set_mode(m)
            reset()
            time.sleep(2)
            lua("client", "pba.ResetPerf() return true")
            lua("server", "pba.perfTimers = {} return true")
            r = idle_window(20)
            out.setdefault(mp, {}).setdefault(m, []).append(r)
            print(f"S0 {mp} {m}: p50 {r.get('p50')} p99 {r.get('p99')} max {r.get('max')} pba_p99 {r.get('pba_p99')} "
                  f"doors {r.get('doors')} timers_cl {r.get('timers_ms')} timers_sv {json.dumps(r.get('timers_sv'))}", flush=True)
    with open(os.path.join(PERF, "last", "S0.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, indent=1)


def move_caches(mp, away):
    """Moves the map's probe / native caches (garrysmod/data/pba/<map>*) aside (away) or back."""
    import glob, shutil
    d = os.path.join(GAME_DATA, "data", "pba")
    stash = os.path.join(d, "_perf_stash")
    os.makedirs(stash, exist_ok=True)
    if away:
        for f in glob.glob(os.path.join(d, mp + "*")):
            shutil.move(f, os.path.join(stash, os.path.basename(f)))
    else:
        for f in glob.glob(os.path.join(stash, mp + "*")):
            dst = os.path.join(d, os.path.basename(f))
            if os.path.exists(dst):
                os.remove(dst)  # rebuilt by the cold run: the original goes back
            shutil.move(f, dst)


def run_s8():
    """S8: load d1_canals_01, then changelevel to d1_canals_01a; caches moved aside (cold) then present
    (warm); worst frame and p99 over the 30 s after the player spawns, per mode (off vs native)."""
    out = {}
    for temp in ("cold", "warm"):
        for m in [x for x in MODES if x != "engine"]:
            for mp in (S8_FROM, S8_TO):
                if temp == "cold":
                    move_caches(mp, True)
            try:
                set_mode(m)
                call("map_load", {"map": S8_FROM, "maxplayers": 1}, timeout=300)
                time.sleep(2)
                con("fps_max 0")
                con("fps_max_nofocus 0")
                con(f"changelevel {S8_TO}")
                time.sleep(3)
                for _ in range(120):
                    st = call("status", {})
                    if st.get("map") == S8_TO and lua("client", "return IsValid(LocalPlayer()) and LocalPlayer():Alive()"):
                        break
                    time.sleep(0.5)
                lua("client", src("collector.lua"))
                lua("server", src("collector_sv.lua"))
                r = idle_window(30)
                r["probes_ready"] = lua("client", "return pba.Probes == nil or pba.Probes.current ~= nil")
            finally:
                if temp == "cold":
                    for mp in (S8_FROM, S8_TO):
                        move_caches(mp, False)
            out.setdefault(temp, {})[m] = r
            print(f"S8 {temp} {m}: p50 {r.get('p50')} p99 {r.get('p99')} max {r.get('max')} worst3 {r.get('worst3')} "
                  f"hitches {r.get('hitches')} over16 {r.get('over16')} pba_max {r.get('pba_max')} probes {r.get('probes_ready')}", flush=True)
    with open(os.path.join(PERF, "last", "S8.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, indent=1)


invalid_any = False
os.makedirs(os.path.join(PERF, "last"), exist_ok=True)
os.makedirs(os.path.join(PERF, "baselines"), exist_ok=True)
if "S0" in ONLY:
    run_s0()
if "S8" in ONLY:
    run_s8()
for sc in [x for x in ONLY if x in SCENES]:
    scene_file, mp = SCENES[sc]
    for variant in VARIANTS:
        print(f"##progress label=\"{sc} {variant}\" msg=\"fresh map\"", flush=True)
        fresh_map(mp)
        report = {"scenario": sc, "variant": variant, "map": mp, "repeat": REPEAT, "cold": {}, "warm": {}}
        if COLD:
            for m in MODES:
                r = burst(scene_file, variant, m, 1, invalidate=True)
                report["cold"][m] = r
                print(f"cold {m}: max {r.get('max')} excess {r.get('excess')} pba_max {r.get('pba_max')} "
                      f"ensure {r.get('ensure')} invalid {r['invalid']}", flush=True)
        for m in MODES:  # discarded warm-up burst
            burst(scene_file, variant, m, 1)
        runs = {m: [] for m in MODES}
        for i in range(REPEAT):
            for m in MODES:
                print(f"##progress label=\"{sc} {variant}\" sub={i * len(MODES) + MODES.index(m) + 1}/{REPEAT * len(MODES)} sublabel=\"{m}\"", flush=True)
                runs[m].append(burst(scene_file, variant, m, 1))
        for m in MODES:
            check_scene(runs[m]) if m != "off" else None
            valid = [r for r in runs[m] if not r["invalid"]]
            if len(valid) < len(runs[m]):
                invalid_any = True
            report["warm"][m] = {"summary": summarize(valid), "valid": len(valid), "runs": runs[m]}
            s = report["warm"][m]["summary"]
            print(f"{sc} {variant} {m:7} valid {len(valid)}/{len(runs[m])}: " + ", ".join(
                f"{k} {v['med']}±{v['mad']}" for k, v in s.items() if isinstance(v, dict))
                + f", ensure {s.get('ensure_ms')} ms, sv {s.get('sv_us_sound')} us/sound, sounds {s.get('sounds')}", flush=True)
            if UPDATE and valid:
                with open(os.path.join(PERF, "baselines", f"{sc}_{variant}__{m}.json"), "w", encoding="utf-8") as f:
                    json.dump({"scenario": sc, "variant": variant, "mode": m, "map": mp, "repeat": REPEAT,
                               "commit": subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True,
                                                        text=True, cwd=HERE).stdout.strip(),
                               "warm": s, "cold": report["cold"].get(m)}, f, indent=1)
        if DIAG:
            con("pba_allow_debug 1")
            set_mode("native")
            d = lua("client", src("diag.lua"))
            r = burst(scene_file, variant, "native", 1)
            report["diag"] = {"load": d, "result": r.get("diag")}
            lua("client", "if PBA_PERF.diagOff then PBA_PERF.diagOff() end return true")
            print(f"{sc} {variant} diag: {json.dumps(r.get('diag'))}", flush=True)
        with open(os.path.join(PERF, "last", f"{sc}_{variant}.json"), "w", encoding="utf-8") as f:
            json.dump(report, f, indent=1)
print("##progress done=ok", flush=True)
sys.exit(2 if invalid_any else 0)
