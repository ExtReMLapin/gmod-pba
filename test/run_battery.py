"""Full PBA test battery, sequential (about 15 min; the game changes maps). Prints one ##progress line
per step and a summary. Usage: python -I -u run_battery.py <path to mcp.py> [--quick | --only=step,step]. Needs ffmpeg on
PATH. --quick: the fast checks only (about 2 minutes), to run before each commit."""
import json, os, subprocess, sys, time
TEST = os.path.dirname(os.path.abspath(__file__))
MCP = sys.argv[1]  # path to the gmod-mcp client (mcp.py)
GAME = os.environ.get("PBA_GAME_DIR", r"D:\SteamLibrary\steamapps\common\GarrysMod\garrysmod")  # garrysmod/ folder
sys.path.insert(0, TEST)

def call(tool, args, mx=200000, timeout=600):
    a = json.dumps(args)
    if len(a) > 20000:  # Windows command line limit: pass the arguments in a temp file (outside lua/)
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as f:
            f.write(a)
        a = "@" + f.name
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, a, str(mx)],
                         capture_output=True, text=True, encoding="utf-8", timeout=timeout).stdout
    if a.startswith("@"):
        os.remove(a[1:])
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

def fresh(m, mp=4):
    """Map loaded anew, even when it is already the current one (map-start state under test)."""
    call("map_load", {"map": m, "maxplayers": mp}, timeout=300)
    time.sleep(4)
    load(m, mp)

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
    # the suite is sent inline, not copied into lua/: parallel game instances share that folder (and its
    # autorefresh), a written file would be seen by every instance
    code = open(os.path.join(TEST, "gluatest", "run_pure.lua"), encoding="utf-8").read()
    src = open(os.path.join(TEST, "gluatest", "pba_pure_test.lua"), encoding="utf-8").read()
    assert "]=======]" not in src
    return call("lua_exec", {"realm": "client", "code": "local PBA_PURE_SRC = [=======[" + src + "]=======]" + chr(10) + code}).get("values")

steps = [
    ("load pba_tworooms", lambda: load("pba_tworooms") or "ok"),
    ("GLuaTest pure suite", pure),
    # metrics of the perceptual bench (Python, no game): full battery only
    ("perceptual metrics (pure)", lambda: py("test_perceptual.py")),
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
    # special sounds: a sentence (metrocop radio) behind a wall is relayed and played muffled by the
    # client (EmitSentence), not left to the engine through the wall; pba_sentences 0: not relayed
    ("sentence_relay", lambda: [job("server", "sentence_relay.lua", 30), job("client", "sentence_client.lua", 10)]),
    # env_microphone in speaker mode: routed before the hook, so pba only processes the speaker copy
    ("microphone_order", lambda: job("server", "microphone_order.lua", 20)),
    # a source left inside a wall: moved to the nearest free space (was heard clear through the wall)
    ("source_in_solid", lambda: job("client", "source_in_solid.lua", 15)),
    # captions of relayed (suppressed) server sounds are sent on their own (were lost)
    ("caption_check", lambda: py("caption_check.py")),
    # a parked vehicle between source and listener stands in the way like a big prop (was ignored)
    ("vehicle_obstacle", lambda: job("server", "vehicle_obstacle.lua", 15)),
    ("loop_removed", lambda: job("server", "loop_removed.lua")),
    # a loop playing while pba is turned off then on: back to the engine, then mirrored again (and a still
    # prop_dynamic, MOVETYPE_PUSH like a door, keeps its loop)
    ("loop_reenable", lambda: job("server", "loop_reenable.lua", 20)),
    # loops born on the client (CreateSound of addons: vehicle engines): mirrored, stopped with Stop, GC, removal
    ("client_loop", lambda: job("client", "client_loop.lua", 20)),
    ("native_doors", lambda: (native_on(True), job("client", "native_doors.lua"))[1]),
    ("native_features", lambda: job("client", "native_features.lua")),
    ("streams_test", lambda: job("client", "streams_test.lua")),
    ("portal_sweep tworooms", lambda: job("client", "portal_sweep.lua")),
    # (loads pba_materials: last of the pba_tworooms block) lip sync: a citizen speaking behind the glass cell keeps moving his mouth with pba (re-emitted voice)
    ("lipsync_glass pba_materials", lambda: (load("pba_materials"), [job("server", "lipsync_glass.lua", 30), job("client", "lipsync_client.lua", 10)])[1]),
    ("water_ogg gm_construct", lambda: (load("gm_construct", 1), native_on(True), make_ogg(), job("client", "water_ogg.lua"), drop_ogg())[3]),
    ("paths_numeric_equiv pba_demo", lambda: (load("pba_demo", 1), job("client", "paths_numeric_equiv.lua"))[1]),
    # door leaf crossed by the line = its doorway (one model): no jump at the leaf / wall boundary
    # continuous sounds: no flip-flop between two equal paths, a real move still switches once
    ("path_hysteresis twodoors", lambda: (doors_open(), job("client", "path_hysteresis.lua"))[1]),
    # continuous sounds glide to each re-evaluation: no gain / EQ / direction step between frames
    ("continuous_ramp twodoors", lambda: py("continuous_ramp.py")),
    # a loop near a muffling threshold: no DSP flicker while the listener steps (pba_lp_hyst_db)
    ("lowpass_hysteresis twodoors", lambda: py("lowpass_hysteresis.py")),
    ("door_sweep open", lambda: (load("pba_demo"), door("Open"), job("client", "door_sweep.lua"))[2]),
    ("door_sweep closed", lambda: (door("Close"), job("client", "door_sweep.lua"))[1]),
    # special sounds: a moving brush's loop (func_door noise1) is stopped by the engine's C++, never
    # seen by Lua: the server mirror must stop with the motion
    ("brush_loop_stop pba_demo", lambda: job("server", "brush_loop_stop.lua", 60)),
    # diffuse model, room 14: the long corridor is heard diffuse (tunnel reverb preset) and a few dB lower, not faded out
    ("diffuse_detour pba_demo", lambda: job("client", "diffuse_detour.lua", 30)),
    ("native_water", lambda: py("native_water.py")),  # still on pba_demo: one load less
    ("reverb_rt", lambda: py("reverb_rt.py")),
    ("native_options", lambda: py("native_options.py")),
    # room reverb tail EQ: air absorption counted once (Steam Audio bug 6, fixed in the fork's DLL)
    ("native_tail_eq", lambda: py("native_tail_eq.py")),
    # props on the paths through openings (portal and probe paths), not only on the straight line
    ("path_obstruction", lambda: py("path_obstruction.py")),
    # one model for a partly blocked opening: a prop covering part of a doorway = a leaf covering the same part
    ("mask_equivalence", lambda: py("mask_equivalence.py")),
    # special sounds: grates and fences (CONTENTS_GRATE) cost no wall loss, do not cut probe links and
    # stay out of the Steam Audio scene (12 grates of d1_canals_01)
    ("grate_loss d1_canals_01", lambda: (load("d1_canals_01"), job("client", "grate_loss.lua", 60))[1]),
    # HL2 Breencast: microphone -> jumbotron speaker copies (SND_SPEAKER); a long line followed as a mirror
    # keeps the speaker filter (dsp_speaker as the mirror's DSP)
    ("breencast_speaker d1_trainstation_01", lambda: (load("d1_trainstation_01"), job("server", "breencast_speaker.lua", 60))[1]),
    # special sounds: looping ambient_generic already playing at map load (before the hooks) taken over
    ("ambient_start d1_town_01", lambda: (fresh("d1_town_01"), job("server", "ambient_start.lua", 30))[1]),
    # soundscape ambience around the ear (random positions) left to the engine: not muffled nor echoed
    ("soundscape_check d1_town_01", lambda: job("client", "soundscape_check.lua", 90)),
    # displacements are one-sided for traces: the same walls from both ends
    ("walls_symmetric gm_construct", lambda: (load("gm_construct"), job("client", "walls_symmetric.lua", 20))[1]),
    # "^" distance-variant waves: the copy keeps the far wave of a far source (pushed to its real distance)
    ("distvariant gm_construct", lambda: job("client", "distvariant.lua", 60)),
    # invisible tool brushes (toolsblockbullets: compiled as glass) cost nothing, do not cut probe links
    ("tool_brushes d2_coast_04", lambda: (load("d2_coast_04"), job("client", "tool_brushes.lua", 120))[1]),
    # time scale: long sounds end in real time (at 2x the server forgot them halfway)
    ("timescale", lambda: job("server", "timescale.lua", 60)),
    # saved games: ambiences restored by the engine on load are taken over again
    ("save_load_loops d1_town_01", lambda: py("save_load_loops.py")),
    # path quality against an independent single-bend reference (maps without areaportals: probes)
    ("path_quality", lambda: py("path_quality.py", "--check", "d1_town_01", "gm_construct")),
    # the path SEARCH through pba_demo's doorways (doors opened) against the single-bend reference, same
    # physics: the diffuse leak through an opening (portal_diffuse_db) is a model the reference lacks
    ("path_quality pba_demo search", lambda: py("path_quality.py", "--check", "--set=pba_portal_diffuse_db=60",
                                                "--max-under6=0.05", "--max-over6=0.05", "pba_demo")),
    # the listener field alone (no immediate search): no cold silence beyond the warm ones
    ("path_quality field only", lambda: py("path_quality.py", "--check", "--no-gap", "--set=pba_probe_inline_ms=0",
                                           "d1_town_01", "gm_construct")),
    # probe paths averaged over the probes the source sees (pba_probe_field_blend): same quality bar as the
    # field alone, and a source moving 4 u at a time gets no step of level or direction
    ("path_quality field blend", lambda: py("path_quality.py", "--check", "--no-gap", "--set=pba_probe_field_blend=1",
                                            "--set=pba_probe_inline_ms=0", "d1_town_01", "gm_construct")),
    ("field_continuity noportal", lambda: (load("pba_noportal"), job("client", "field_continuity.lua", 300))[1]),
    # copies of one probe route counted once (report only: field and k-path, new vs former criterion)
    ("probe_dedupe gm_construct", lambda: (load("gm_construct"), job("client", "probe_dedupe.lua", 600))[1]),
    # what a player can hear: level steps > 1 dB (JND) and
    # direction jumps when the source or the listener walks 16 u steps, level(S, L) vs level(L, S).
    # Limits None (report only) until the first in-game baseline; --check fails on too few walks.
    # gm_construct first: path_quality field only ends on it (one load less); pba_demo: portal paths
    ("path_perceptual", lambda: py("path_perceptual.py", "--check", "--pairs=15", "gm_construct", "pba_demo")),
    # continuous sounds re-evaluated only on change (pba_reeval_adaptive): still cost, listener move, door
    ("reeval_adaptive", lambda: py("reeval_adaptive.py")),
]
# special-sound scenarios (test/special/steps.py), grouped by map; --special: only these
sys.path.insert(0, os.path.join(TEST, "special"))
from steps import STEPS as SPECIAL  # noqa: E402
def _special(m, mp, realm, f, t, fr):
    return lambda: ((fresh(m, mp) if fr else load(m, mp)), job(realm, os.path.join("special", f), t))[1]
special_steps = [(label, _special(m, mp, realm, f, t, fr)) for (label, m, mp, realm, f, t, fr) in SPECIAL]
steps += special_steps
if "--special" in sys.argv[2:]:
    steps = special_steps
# --quick: the fast checks (about 2 minutes, two maps) to run before each commit; the full battery
# before merging into main or a release
QUICK = {"load pba_tworooms", "GLuaTest pure suite", "menu_fit", "portal_sweep tworooms", "bot_gunfire",
         "loop_removed", "loop_reenable", "client_loop", "native_doors", "native_features", "path_hysteresis twodoors", "door_sweep open",
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
