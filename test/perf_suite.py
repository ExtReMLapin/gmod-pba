"""Perf bench (docs/PLAN_PERF.md), minimal version: S0 (idle overhead), S1 (barrels), S2 (mass breakage),
S3 (frag grenades: a staggered, b same frame), S11 (d1_canals_01's own explosive barrels), S12 (echo burst,
native modes), S8 (campaign map load + changelevel, probe / native caches moved aside then present).

Usage: MCP_INSTANCE=<id> python -I -u perf_suite.py <mcp.py> [--only=S0,S1,S2,S8] [--s0maps=a,b] [--variants=vue,mur]
       [--modes=off,engine,native,native_noecho,native_echo] [--repeat=5] [--cold] [--diag] [--update-baseline]
       [--knob=pba_x=v ...]  (repeatable: a setting applied after the defaults, before every mode; A/B of an option)
       [--overlay=lua/pba/x.lua,...]  (client files of THIS checkout run over the game's after each map load: a branch's
                                       code A/B'd without touching the installed addon)
       [--profile[=N]]  (N more bursts per mode with test/perf/profile.lua: per-function cost in the worst frames)

ONE game instance on the machine (the others closed): parallel games distort every number.
Launch it with instances_launch preset normal (640x360): the suite sets fps_max 0 / fps_max_nofocus 0 /
mat_vsync 0 (archived: close the game with instances_close / game_terminate, never host_writeconfig).
Default variants and modes per scenario (SCENES below) unless --variants / --modes are given.

Per scenario and variant: fresh map, probes ready; with --cold one burst per mode with the path cache
invalidated (the first native burst of a game session also decodes its sounds: native cold); then one
discarded burst per mode and R repetitions, modes interleaved (off, engine, native, off, ...). Each burst:
reset (map cleanup, stopsound, native voices back to 0, garbage collected in both realms), scene setup,
2 s settle, collectors armed, burst fired from server timers 1 s later, 4.5 s recorded.
Every Lua file of the bench (collectors, scenes, diag) is copied to garrysmod/lua/mcpagent_tmp/pba_perf/ and
compiled IN THE GAME from a timer (file.Read + CompileString): gmod-mcp's lua_exec turns the JIT off for its
chunk AND every function it defines (jit.off(fn, true): hooks, timers), so a collector or a scene sent
through lua_exec would run interpreted (measured 2026-11-13: same loop 16.7 ms from a file, 44 ms from
lua_exec). lua_exec only calls functions; nothing is sent to the game during a window.
--diag: one more pass per scenario in native mode with test/perf/diag.lua (cache hits, keys vs cells,
synchronous computations per frame); never timed. Needs pba_allow_debug 1 (set by the suite).
--profile[=N] (default 3): after the timed bursts, N bursts per mode with test/perf/profile.lua (every pba
function called through its table, pba_native.*, traces and pba hooks wrapped, JIT on): per frame, exclusive
and inclusive ms and calls per function; prints the worst frames' rows and the per-function worst frame,
writes test/perf/last/<scenario>_<variant>_profile.json. Never timed (wrappers cost ~0.2-0.5 us per call).

A burst is INVALID (not compared) when the system was not active: no sound seen by pba (processed +
played clear + native direct) in a pba mode, or the reset failed (voices left), or the scene did not
reproduce (sounds seen off by more than 15 % from the mode's median), or the frames were capped
(idle median >= 10 ms).
Prints per mode: median (and MAD) over repetitions of p50, p99, max, worst3, excess, hitches, PBA ms
per frame (p99, max, sum), KB allocated, GC drops, decode (ensure) ms, server us per sound.
Writes test/perf/last/<scenario>_<variant>.json; --update-baseline also writes
test/perf/baselines/<scenario>_<variant>__<mode>.json.
Exit codes: 0 ran, 2 some burst INVALID, 3 usage.
"""
import json, os, re, shutil, statistics, subprocess, sys, time

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
KNOBS = [a.split("=", 1)[1] for a in OPTS if a.startswith("--knob=")]  # "pba_x=v", each applied after defaults()
for _k in KNOBS:
    if not re.match(r"^pba_\w+=[-0-9.]+$", _k):
        sys.exit(f"--knob={_k}: expected pba_<name>=<number>")
if KNOBS and "--update-baseline" in OPTS:
    sys.exit("--knob with --update-baseline: the baselines are the defaults' (A/B against them instead)")
VARIANTS_OPT = opt("variants", None)
MODES_OPT = opt("modes", None)
MODES = (MODES_OPT or "off,engine,native").split(",")
REPEAT = int(opt("repeat", "5"))
COLD = "--cold" in OPTS
DIAG = "--diag" in OPTS
OVERLAY = [x for x in opt("overlay", "").split(",") if x]
PROFILE = next((int(a.split("=", 1)[1]) if "=" in a else 3 for a in OPTS if a.startswith("--profile")), 0)
UPDATE = "--update-baseline" in OPTS
PRE, POST, SETTLE = 1.0, 4.5, 2.0
# scenario -> (scene file, {variant: map}, default variants, default modes)
SCENES = {
    "S1": ("s1_barrels.lua", {"vue": "gm_construct", "mur": "gm_construct"}, "vue,mur", None),
    "S2": ("s2_breaks.lua", {"vue": "gm_construct", "mur": "gm_construct"}, "vue", None),
    "S3": ("s3_grenades.lua", {"a": "gm_construct", "b": "gm_construct"}, "a,b", None),
    "S11": ("s11_hl2_barrels.lua", {"canals": "d1_canals_01"}, "canals", None),
    "S12": ("s12_echoes.lua", {"tworooms": "pba_tworooms", "construct": "gm_construct"}, "tworooms,construct",
            "native,native_echo"),
}
IDLE_CAP_MS = 10.0
S0_MAPS = opt("s0maps", "gm_construct,d1_canals_01").split(",")
S8_FROM, S8_TO = "d1_canals_01", "d1_canals_01a"
GAME_DATA = os.environ.get("PBA_GAME_DIR", r"D:\SteamLibrary\steamapps\common\GarrysMod\garrysmod")
LUA_TMP = os.path.join(GAME_DATA, "lua", "mcpagent_tmp", "pba_perf")
MODE_CVARS = {
    "off": ["pba_enable 0"],
    "engine": ["pba_enable 1", "pba_native_render 0"],
    "native": ["pba_enable 1", "pba_native_render 1", "pba_native_all 1"],
    "native_noecho": ["pba_enable 1", "pba_native_render 1", "pba_native_all 1", "pba_native_echo 0"],
    # module on, sounds left to the engine except the walled ones: the loud ones get N.Echo (with
    # pba_native_all 1, N.Echo skips them: their reflections come from their source slot)
    "native_echo": ["pba_enable 1", "pba_native_render 1", "pba_native_all 0"],
}
MODE_KNOBS = ("enable", "native_render", "native_all", "native_echo")  # set by the modes, not by defaults()


def call(tool, args, timeout=600):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), "400000"],
                         capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout).stdout
    try:
        return json.loads(out)
    except ValueError:
        return {"raw": out[-400:]}


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


def load(realm, *parts):
    """Runs a bench file in the game with the JIT on (see the docstring): copied to lua/mcpagent_tmp/pba_perf/,
    compiled and run from a timer. Returns the file's first return value, or raises."""
    name = "_".join(parts)
    os.makedirs(LUA_TMP, exist_ok=True)
    shutil.copyfile(os.path.join(PERF, *parts), os.path.join(LUA_TMP, name))
    lua(realm, "PBA_PERF_LOAD = nil timer.Simple(0, function() "
               f"local s = file.Read('lua/mcpagent_tmp/pba_perf/{name}', 'GAME') "
               f"local f = CompileString(s or '', 'pba_perf/{name}', false) "
               "if not isfunction(f) then PBA_PERF_LOAD = { ok = false, err = tostring(f) } return end "
               "local ok, r = pcall(f) PBA_PERF_LOAD = { ok = ok, r = r, err = not ok and tostring(r) or nil } end) return true")
    for _ in range(50):
        v = lua(realm, "return PBA_PERF_LOAD")
        if v:
            if not v.get("ok"):
                raise RuntimeError(f"{name} ({realm}): {v.get('err')}")
            return v.get("r")
        time.sleep(0.1)
    raise RuntimeError(f"{name} ({realm}): not loaded")


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
    overlay()
    uncap()
    defaults()
    load("client", "collector.lua")
    load("server", "collector_sv.lua")


def overlay():
    """--overlay: each file of this checkout (path from the repo root) compiled in the client realm from a timer
    (JIT on, as the bench files), over the installed addon's version; the pba files are written to be run again."""
    root = os.path.dirname(HERE)
    for rel in OVERLAY:
        name = "ov_" + rel.replace("/", "_").replace("\\", "_")
        os.makedirs(LUA_TMP, exist_ok=True)
        shutil.copyfile(os.path.join(root, rel), os.path.join(LUA_TMP, name))
        lua("client", "PBA_PERF_LOAD = nil timer.Simple(0, function() "
                      f"local s = file.Read('lua/mcpagent_tmp/pba_perf/{name}', 'GAME') "
                      f"local f = CompileString(s or '', '{rel}', false) "
                      "if not isfunction(f) then PBA_PERF_LOAD = { ok = false, err = tostring(f) } return end "
                      "local ok, r = pcall(f) PBA_PERF_LOAD = { ok = ok, err = not ok and tostring(r) or nil } end) return true")
        for _ in range(50):
            v = lua("client", "return PBA_PERF_LOAD")
            if v:
                if not v.get("ok"):
                    raise RuntimeError(f"overlay {rel}: {v.get('err')}")
                break
            time.sleep(0.1)
        else:
            raise RuntimeError(f"overlay {rel}: not loaded")
    if OVERLAY:
        print(f"overlay: {' '.join(OVERLAY)}", flush=True)


def uncap():
    con("fps_max 0")
    con("fps_max_nofocus 0")
    con("mat_vsync 0")


def defaults():
    """Every pba_* setting back to its default (A.CONFIG), overrides cleared: the convars are archived and
    shared by every instance, another session's test leaves its values (seen 2026-11-13: pba_native_echo 0).
    The mode knobs are left to set_mode; pba_native_echo's default is read here for the native modes."""
    skip = "{" + ",".join(f"{k}=true" for k in MODE_KNOBS) + "}"
    body = ("local skip, n = " + skip + ", {} for name, c in pairs(pba.CONFIG) do "
            "local cv = GetConVar('pba_' .. name) "
            "if c[4] == '%s' and cv and not skip[name] and math.abs(cv:GetFloat() - c[1]) > 1e-4 * math.max(1, math.abs(c[1])) then "
            "RunConsoleCommand('pba_' .. name, tostring(c[1])) n[#n + 1] = name .. '=' .. cv:GetString() end end "
            "for k in pairs(pba.override or {}) do pba.SetOverride(k, nil) n[#n + 1] = 'override ' .. k end "
            "return table.concat(n, ' ')")
    changed = [lua("server", body % "sv"), lua("client", body % "cl")]
    echo = lua("client", "return pba.CONFIG.native_echo[1]")
    MODE_CVARS["native"] = [c for c in MODE_CVARS["native"] if not c.startswith("pba_native_echo")] + [f"pba_native_echo {echo}"]
    for m in ("engine", "native_echo"):
        MODE_CVARS[m] = [c for c in MODE_CVARS[m] if not c.startswith("pba_native_echo")] + [f"pba_native_echo {echo}"]
    print(f"defaults restored: sv [{changed[0]}] cl [{changed[1]}]", flush=True)
    for k in KNOBS:
        name, v = k.split("=", 1)
        con(f"{name} {v}")
    if KNOBS:
        print(f"knobs: {' '.join(KNOBS)}", flush=True)


def set_mode(mode):
    for c in MODE_CVARS[mode]:
        con(c)
    time.sleep(0.5)


def reset():
    con("stopsound")
    ok = wait("client", "(not pba_native or not pba_native.Stats or pba_native.Stats().voices == 0)"
                        " and (not pba.Loops or not pba.Loops.mirrors or next(pba.Loops.mirrors) == nil)"
                        " and next(pba.emitted or {}) == nil", 10)
    lua("client", "collectgarbage('collect') return true")
    lua("server", "collectgarbage('collect') return true")
    return ok


def burst(scene_file, variant, mode, seed, invalidate=False, profile=False):
    set_mode(mode)
    load("server", "scenes", scene_file)
    setup = lua("server", f"return PBA_SCENE.Setup({{ variant = '{variant}', seed = {seed} }})")
    clean = reset()
    if invalidate:
        lua("client", "pba.Paths.InvalidateCache() return true")
    time.sleep(SETTLE)
    lua("server", f"PBA_PERF_SV.Arm({PRE + POST}) return PBA_SCENE.Fire({PRE})")
    lua("client", f"PBA_PERF.Arm({PRE}, {POST}) " + (f"PBA_PROF.Arm({PRE}, {POST}) " if profile else "") + "return true")
    time.sleep(PRE + POST + 0.5)
    res = None
    for _ in range(20):
        res = lua("client", "return PBA_PERF.Result()")
        if res and res.get("done"):
            break
        time.sleep(0.5)
    res = res or {}
    res["server"] = lua("server", "return PBA_PERF_SV.Result()")
    if profile:
        raw = lua("client", "return PBA_PROF.Result(5, 15)")
        try:
            res["profile"] = json.loads(raw) if isinstance(raw, str) else raw
        except ValueError:
            res["profile"] = {"raw": str(raw)[:300]}
    res["setup"], res["clean"], res["mode"] = setup, clean, mode
    why = []
    if not clean:
        why.append("reset: voices or mirrors left")
    if mode != "off" and not res.get("seen"):
        why.append("system inactive: 0 sounds seen by pba")
    if mode == "native_echo" and scene_file.startswith("s12") and not res.get("echoes"):
        why.append("echoes inactive: 0 N.Echo")
    if res.get("idle_p50", 0) >= IDLE_CAP_MS:
        why.append(f"frames capped: idle p50 {res.get('idle_p50')} ms")
    # module active: walled voices, clear sounds it plays (nativeDirect), echoes, or voices seen playing
    if mode.startswith("native") and not (res.get("voices") or res.get("ndirect") or res.get("echoes")
                                          or res.get("maxNativeVoices")):
        why.append("native inactive: no module voice")
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
    out["sounds"] = statistics.median([r.get("seen", 0) for r in runs]) if runs else 0
    out["idle_p50"] = statistics.median([r.get("idle_p50", 0) for r in runs]) if runs else 0
    return out


def check_scene(runs):
    """Scene reproduced: sounds seen within 15 % of the mode's median (pba modes)."""
    seen = [r.get("seen", 0) for r in runs]
    if not seen or max(seen) == 0:
        return
    med = statistics.median(seen)
    for r in runs:
        if med and abs(r.get("seen", 0) - med) > 0.15 * med:
            r["invalid"].append(f"scene: {r.get('seen')} sounds vs median {med}")


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
    """Moves the map's probe / native caches (garrysmod/data/pba/<map>.txt, <map>_sa.dat) aside (away) or back.
    The folder is shared by every instance: run S8 with no other game open."""
    d = os.path.join(GAME_DATA, "data", "pba")
    stash = os.path.join(d, "_perf_stash")
    os.makedirs(stash, exist_ok=True)
    names = (mp + ".txt", mp + "_sa.dat")  # cl_probes cachePath, cl_native bakeCachePath (not d1_canals_01a.txt)
    if away:
        for f in [os.path.join(d, n) for n in names if os.path.exists(os.path.join(d, n))]:
            shutil.move(f, os.path.join(stash, os.path.basename(f)))
    else:
        for f in [os.path.join(stash, n) for n in names if os.path.exists(os.path.join(stash, n))]:
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
                call("map_load", {"map": S8_FROM, "maxplayers": 1}, timeout=300)
                defaults()
                set_mode(m)
                time.sleep(2)
                uncap()
                con(f"changelevel {S8_TO}")
                time.sleep(3)
                for _ in range(120):
                    st = call("status", {})
                    if st.get("map") == S8_TO and lua("client", "return IsValid(LocalPlayer()) and LocalPlayer():Alive()"):
                        break
                    time.sleep(0.5)
                load("client", "collector.lua")
                load("server", "collector_sv.lua")
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


def print_profile(sc, variant, m, runs):
    """Per run: the worst frame (frame time) and the worst pba frame, their top rows; then per function the
    median over runs of its worst frame (exclusive ms) and calls in it."""
    agg = {}
    for i, r in enumerate(runs):
        p = r.get("profile") or {}
        for lab, key in (("worst frame", "worst"), ("worst pba frame", "worstPba")):
            fr = (p.get(key) or [{}])[0]
            rows = ", ".join(f"{x['f']} {x['x']}/{x['t']} ms x{x['n']}" for x in (fr.get("rows") or [])[:10])
            print(f"  run {i + 1} {lab}: dt {fr.get('dt')} ms, pba {fr.get('pba')} ms, t+{fr.get('rel')} s: {rows}", flush=True)
        for x in p.get("totals") or []:
            agg.setdefault(x["f"], []).append((x["maxX"], x["maxT"], x["x"], x["n"]))
    rows = sorted(((statistics.median(v[0] for v in vs), statistics.median(v[1] for v in vs),
                    statistics.median(v[2] for v in vs), statistics.median(v[3] for v in vs), f) for f, vs in agg.items()),
                  reverse=True)
    print(f"{sc} {variant} {m} profile, per function (median over {len(runs)} runs): worst frame excl / incl ms, window excl ms, calls", flush=True)
    for mx, mt, tx, n, f in rows[:20]:
        print(f"  {f:45} {mx:8.3f} {mt:8.3f} {tx:9.3f} {n:7.0f}", flush=True)


invalid_any = False
os.makedirs(os.path.join(PERF, "last"), exist_ok=True)
os.makedirs(os.path.join(PERF, "baselines"), exist_ok=True)
if "S0" in ONLY:
    run_s0()
if "S8" in ONLY:
    run_s8()
for sc in [x for x in ONLY if x in SCENES]:
    scene_file, maps, dvar, dmodes = SCENES[sc]
    MODES = (MODES_OPT or dmodes or "off,engine,native").split(",")
    for variant in (VARIANTS_OPT or dvar).split(","):
        mp = maps[variant]
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
            d = load("client", "diag.lua")
            r = burst(scene_file, variant, "native", 1)
            report["diag"] = {"load": d, "result": r.get("diag")}
            lua("client", "if PBA_PERF.diagOff then PBA_PERF.diagOff() end return true")
            print(f"{sc} {variant} diag: {json.dumps(r.get('diag'))}", flush=True)
        if PROFILE:
            prof = {}
            for m in MODES:
                set_mode(m)
                info = load("client", "profile.lua")
                print(f"{sc} {variant} {m} profile: {json.dumps(info)}", flush=True)
                try:
                    prof[m] = [burst(scene_file, variant, m, 1, profile=True) for _ in range(PROFILE)]
                finally:
                    lua("client", "if PBA_PROF and PBA_PROF.Unload then PBA_PROF.Unload() end return true")
                print_profile(sc, variant, m, prof[m])
            with open(os.path.join(PERF, "last", f"{sc}_{variant}_profile.json"), "w", encoding="utf-8") as f:
                json.dump({m: [{"max": r.get("max"), "pba_max": r.get("pba_max"), "invalid": r.get("invalid"),
                                "profile": r.get("profile")} for r in rs] for m, rs in prof.items()}, f, indent=1)
        with open(os.path.join(PERF, "last", f"{sc}_{variant}.json"), "w", encoding="utf-8") as f:
            json.dump(report, f, indent=1)
print("##progress done=ok", flush=True)
sys.exit(2 if invalid_any else 0)
