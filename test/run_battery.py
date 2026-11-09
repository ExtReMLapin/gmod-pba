"""Full PBA test battery, sequential (about 20 min; the game changes maps). Prints one ##progress line
per step, the verdict of each step, then a verdict table.

Usage: python -I -u run_battery.py <path to mcp.py> [--quick | --special | --only=step,step]
  (no option)  every step, then the special-sound scenarios (test/special/steps.py)
  --quick      the fast checks only (about 3 minutes, three maps), to run before each commit
  --special    the special-sound scenarios only
  --only=a,b   just these steps (exact labels, comma separated), in battery order
Needs ffmpeg on PATH (water_ogg).

Every step sets the state it needs itself (map, demo mode, door, player position, pba_native_render),
so any subset runs in any order. Verdicts:
  PASS          the test's criterion holds (pass = true; a PASS line, n/n passed or a JSON pass = true
                with exit code 0 for a Python test)
  FAIL          pass = false or missing (nil), an exception, a string answer ("no door"), a FAIL line,
                a non-zero exit code of a Python test
  INCONCLUSIVE  a Python test exited 0 without printing any verdict, or a special scenario returned
                pass = nil (it could not set itself up)
  REPORT        report-only steps (no criterion by design): listed, never counted
The full output of every FAIL / INCONCLUSIVE step goes to test/battery_last.log (rewritten each run).
Exit code: 0 every step PASS (or REPORT); 1 at least one FAIL; 2 no FAIL but at least one
INCONCLUSIVE; 3 usage error (missing mcp.py path, unknown --only label).
"""
import json, os, re, subprocess, sys, time
TEST = os.path.dirname(os.path.abspath(__file__))
if len(sys.argv) < 2 or sys.argv[1].startswith("--"):
    print(__doc__)
    sys.exit(3)
MCP = sys.argv[1]  # path to the gmod-mcp client (mcp.py)
GAME = os.environ.get("PBA_GAME_DIR", r"D:\SteamLibrary\steamapps\common\GarrysMod\garrysmod")  # garrysmod/ folder
LOG = os.path.join(TEST, "battery_last.log")
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

def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None

def wait_lua(realm, code, timeout=15.0):
    """Polls a Lua condition (returns true) for up to `timeout` s; returns whether it held."""
    t0 = time.time()
    while time.time() - t0 < timeout:
        if lua(realm, code) is True:
            return True
        time.sleep(0.5)
    return False

# ------------------------------------------------------------------ state setters (one per kind of state)

def load(m, mp=4):
    """Map m (maxplayers mp) loaded and pba's client ready; raises when the map is not there."""
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
    st = call("status", {})
    if st.get("map") != m:
        raise RuntimeError(f"map {m} not loaded (current: {st.get('map')})")
    return "ok"

def fresh(m, mp=4):
    """Map loaded anew, even when it is already the current one (map-start state under test)."""
    call("map_load", {"map": m, "maxplayers": mp}, timeout=300)
    time.sleep(4)
    return load(m, mp)

def any_map():
    """Steps that run on any map: keep the current one, load pba_tworooms when none is loaded."""
    if not call("status", {}).get("map"):
        load("pba_tworooms")

def native_on(on):
    """pba_native_render on / off, and wait until the client renderer follows (when the module exists)."""
    call("console_exec", {"realm": "client", "cmd": f"pba_native_render {1 if on else 0}"})
    want = "true" if on else "false"
    wait_lua("client", "local N = pba.Native return N == nil or pba_native == nil or (N.render == true) == " + want, 15)
    time.sleep(1)

def cheats():
    call("console_exec", {"realm": "server", "cmd": "sv_cheats 1"})
    time.sleep(0.5)

def demo_mode(m):
    """pba_demo desk mode (1 A vanilla, 2 B pba engine, 3 C pba native). Mode C needs native rendering:
    switched on here, and waited for (the demo releases the module it held aside)."""
    lua("server", f"pba.DemoMap.SetMode({m}) return true")
    time.sleep(1)
    if m == 3:
        native_on(True)
        wait_lua("client", "local N = pba.Native return N ~= nil and N.ready == true and N.render == true", 20)

def scenario(m, name):
    """pba_demo <name> (dev bench): player placed at the scenario's listener point, doors set; the source
    it spawns is removed again (pba_demo stop keeps the position and the doors)."""
    load(m)
    call("console_exec", {"realm": "server", "cmd": f"pba_demo {name}"})
    time.sleep(3)  # doors swing
    call("console_exec", {"realm": "server", "cmd": "pba_demo stop"})
    time.sleep(0.5)

def doors_open(m="pba_twodoors"):
    load(m)
    call("lua_exec", {"realm": "server", "code": "for _, n in ipairs({'door_s', 'door_n'}) do for _, d in ipairs(ents.FindByName(n)) do d:Fire('Open') end end return true"})
    time.sleep(3)

def door(action):
    """pba_demo boombox room: mode C, door opened or closed (the sweep waits for its state)."""
    load("pba_demo")
    demo_mode(3)
    call("lua_exec", {"realm": "server", "code": "ents.FindByName('pba_boombox_door')[1]:Fire('%s') return true" % action})
    time.sleep(3)

def echo_on():
    """Native echoes rendered by the client, and the server told so (pba_echo_want, set on the client's Think)."""
    native_on(True)
    call("console_exec", {"realm": "client", "cmd": "pba_native_echo 1"})
    wait_lua("server", "local p = player.GetHumans()[1] return IsValid(p) and p:GetInfoNum('pba_echo_want', 0) >= 1", 10)

# ------------------------------------------------------------------ test runners

def job(realm, file, timeout_s=120):
    code = open(os.path.join(TEST, file), encoding="utf-8").read()
    r = call("lua_job", {"realm": realm, "code": code, "timeout_s": timeout_s}, timeout=timeout_s + 60)
    return r.get("values", [r])[0] if isinstance(r, dict) else r

class PyOut:
    """Result of a Python test: exit code and full output (judged on stdout, logged whole)."""
    def __init__(self, rc, out, err):
        self.rc, self.out, self.err = rc, out, err
    def text(self):
        return self.out + (("\n[stderr]\n" + self.err) if self.err.strip() else "") + f"\n[exit code {self.rc}]"

def py(script, *args, timeout=1500):
    p = subprocess.run([sys.executable, "-I", os.path.join(TEST, script), MCP, *args], capture_output=True,
                       text=True, encoding="utf-8", timeout=timeout)
    return PyOut(p.returncode, p.stdout or "", p.stderr or "")

def make_ogg():
    d = os.path.join(GAME, "sound", "pba_test")
    os.makedirs(d, exist_ok=True)
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
                    "-c:a", "libvorbis", os.path.join(d, "tone.ogg")], check=False)

def drop_ogg():
    import shutil
    shutil.rmtree(os.path.join(GAME, "sound", "pba_test"), ignore_errors=True)

def water_ogg():
    load("gm_construct", 1)
    native_on(True)
    make_ogg()
    try:
        return job("client", "water_ogg.lua")
    finally:
        drop_ogg()

def pure():
    # the suite is sent inline, not copied into lua/: parallel game instances share that folder (and its
    # autorefresh), a written file would be seen by every instance
    load("pba_tworooms")
    code = open(os.path.join(TEST, "gluatest", "run_pure.lua"), encoding="utf-8").read()
    src = open(os.path.join(TEST, "gluatest", "pba_pure_test.lua"), encoding="utf-8").read()
    assert "]=======]" not in src
    return call("lua_exec", {"realm": "client", "code": "local PBA_PURE_SRC = [=======[" + src + "]=======]" + chr(10) + code}).get("values")

def seq(*fns):
    """Runs the setters then the test (last), returns the test's result."""
    out = None
    for f in fns:
        out = f()
    return out

TW = "pba_tworooms"
steps = [
    ("GLuaTest pure suite", pure),
    # metrics of the perceptual bench (Python, no game): full battery only
    ("perceptual metrics (pure)", lambda: py("test_perceptual.py")),
    ("menu_fit", lambda: seq(lambda: load(TW), lambda: job("client", "menu_fit.lua"))),
    # SoundDuration of prefixed names ("^", ")", "*"...): pba's version in both realms
    ("sound_prefix_check", lambda: seq(lambda: load(TW), lambda: [job("client", "sound_prefix_check.lua", 15),
                                                                  job("server", "sound_prefix_check.lua", 15)])),
    # engine rendering: with "everything native" the server relays every sound to this client and the
    # "untouched" scenarios cannot hold (by design)
    ("run_scenarios", lambda: seq(lambda: load(TW), lambda: native_on(False), lambda: py("run_scenarios.py"))),
    ("ab_counts tworooms_open", lambda: seq(lambda: load(TW), lambda: py("ab_counts.py", "tworooms_open"))),
    ("ab_counts lcorridor", lambda: seq(lambda: load("pba_lcorridor"), lambda: py("ab_counts.py", "lcorridor"))),
    ("native_lr", lambda: py("native_lr.py")),
    ("long_and_all", lambda: py("long_and_all.py")),
    ("moving_source", lambda: py("moving_source.py")),
    ("predicted_fire", lambda: seq(lambda: load(TW), lambda: py("predicted_fire.py"))),
    ("lifecycle", lambda: py("lifecycle.py")),
    # engine-rendered block (pba_native_render 0)
    ("bot_gunfire", lambda: seq(lambda: load(TW), lambda: native_on(False), lambda: job("server", "bot_gunfire.lua"))),
    # special sounds: a sentence (metrocop radio) behind a wall is relayed and played muffled by the
    # client (EmitSentence), not left to the engine through the wall; pba_sentences 0: not relayed
    ("sentence_relay", lambda: seq(lambda: load(TW), lambda: native_on(False),
                                   lambda: [job("server", "sentence_relay.lua", 30), job("client", "sentence_client.lua", 10)])),
    # what EntityEmitSound sees of a sentence: "invalid.wav" + OriginalSoundName (what the relay carries)
    ("sentence_seen", lambda: seq(lambda: scenario(TW, "tworooms_closed"), lambda: job("server", "sentence_seen.lua", 15))),
    # env_microphone in speaker mode: routed before the hook, so pba only processes the speaker copy
    ("microphone_order", lambda: seq(lambda: load(TW), lambda: native_on(False), lambda: job("server", "microphone_order.lua", 20))),
    # a source left inside a wall: moved to the nearest free space (was heard clear through the wall)
    ("source_in_solid", lambda: seq(lambda: load(TW), lambda: job("client", "source_in_solid.lua", 15))),
    # captions of relayed (suppressed) server sounds are sent on their own (were lost)
    ("caption_check", lambda: py("caption_check.py")),
    # a parked vehicle between source and listener stands in the way like a big prop (was ignored)
    ("vehicle_obstacle", lambda: seq(lambda: load(TW), lambda: job("server", "vehicle_obstacle.lua", 15))),
    ("loop_removed", lambda: seq(lambda: load(TW), lambda: native_on(False), lambda: job("server", "loop_removed.lua"))),
    # a loop playing while pba is turned off then on: back to the engine, then mirrored again (and a still
    # prop_dynamic, MOVETYPE_PUSH like a door, keeps its loop)
    ("loop_reenable", lambda: seq(lambda: load(TW), lambda: native_on(False), lambda: job("server", "loop_reenable.lua", 20))),
    # loops born on the client (CreateSound of addons: vehicle engines): mirrored, stopped with Stop, GC, removal
    ("client_loop", lambda: seq(lambda: load(TW), lambda: native_on(False), lambda: job("client", "client_loop.lua", 20))),
    # native block (pba_native_render 1); native_doors closes then opens the door itself
    ("native_doors", lambda: seq(lambda: load(TW), lambda: native_on(True), lambda: job("client", "native_doors.lua"))),
    ("native_features", lambda: seq(lambda: scenario(TW, "tworooms_closed"), lambda: native_on(True),
                                    lambda: job("client", "native_features.lua"))),
    # engine traces from the module (pba_native.trace): identical to util.TraceLine / TraceHull / PointContents
    ("native_trace", lambda: seq(lambda: load(TW), lambda: native_on(True), lambda: job("client", "native_trace.lua", 60))),
    # a loud server sound in sight is relayed to a client rendering native echoes, a quiet one is not
    ("echo_relay", lambda: seq(lambda: scenario(TW, "tworooms_closed"), echo_on, lambda: job("server", "echo_relay.lua", 20))),
    # a radio stream of another addon: door closed, listener 256,256 (pba_demo tworooms_closed)
    ("streams_test", lambda: seq(lambda: scenario(TW, "tworooms_closed"), lambda: native_on(True),
                                 lambda: job("client", "streams_test.lua"))),
    # door closed: the doorway portal is crossed by a path or a transmission voice, a "clear" answer
    # must be backed by a free line
    ("portal_sweep tworooms", lambda: seq(lambda: scenario(TW, "tworooms_closed"), lambda: job("client", "portal_sweep.lua"))),
    # lip sync: a citizen speaking behind the glass cell keeps moving his mouth with pba (re-emitted voice)
    ("lipsync_glass pba_materials", lambda: seq(lambda: load("pba_materials"), lambda: native_on(True),
                                                lambda: [job("server", "lipsync_glass.lua", 30), job("client", "lipsync_client.lua", 10)])),
    ("water_ogg gm_construct", water_ogg),
    ("paths_numeric_equiv pba_demo", lambda: seq(lambda: load("pba_demo", 1), lambda: job("client", "paths_numeric_equiv.lua"))),
    # door leaf crossed by the line = its doorway (one model): no jump at the leaf / wall boundary
    # continuous sounds: no flip-flop between two equal paths, a real move still switches once
    ("path_hysteresis twodoors", lambda: seq(doors_open, lambda: job("client", "path_hysteresis.lua"))),
    # continuous sounds glide to each re-evaluation: no gain / EQ / direction step between frames
    ("continuous_ramp twodoors", lambda: py("continuous_ramp.py")),
    # a loop near a muffling threshold: no DSP flicker while the listener steps (pba_lp_hyst_db)
    ("lowpass_hysteresis twodoors", lambda: py("lowpass_hysteresis.py")),
    ("door_sweep open", lambda: seq(lambda: door("Open"), lambda: job("client", "door_sweep.lua"))),
    ("door_sweep closed", lambda: seq(lambda: door("Close"), lambda: job("client", "door_sweep.lua"))),
    # special sounds: a moving brush's loop (func_door noise1) is stopped by the engine's C++, never
    # seen by Lua: the server mirror must stop with the motion (sets mode B itself)
    ("brush_loop_stop pba_demo", lambda: seq(lambda: load("pba_demo"), lambda: job("server", "brush_loop_stop.lua", 60))),
    # diffuse model, room 14: the long corridor is heard diffuse (tunnel reverb preset) and a few dB lower, not faded out
    ("diffuse_detour pba_demo", lambda: seq(lambda: load("pba_demo"), lambda: job("client", "diffuse_detour.lua", 30))),
    # diffuse share in the native module: direct down, reverb up, total about constant (demo mode C)
    ("native_diffuse pba_demo", lambda: seq(lambda: load("pba_demo"), lambda: demo_mode(3),
                                            lambda: job("client", "native_diffuse.lua", 60))),
    # reverb send independent from the direct gain: a far source excites the room reverb as much as a near one
    ("native_reverb_distance pba_demo", lambda: seq(lambda: load("pba_demo"), lambda: demo_mode(3),
                                                    lambda: job("client", "native_reverb_distance.lua", 90))),
    ("native_water", lambda: py("native_water.py")),  # pba_demo (loads it if needed): one load less
    ("reverb_rt", lambda: py("reverb_rt.py")),
    ("native_options", lambda: py("native_options.py")),
    # room reverb tail EQ: air absorption counted once (Steam Audio bug 6, fixed in the fork's DLL)
    ("native_tail_eq", lambda: py("native_tail_eq.py")),
    # a one-shot followed while it plays: the voice reaches the source once the listener steps into sight
    # (pba_demo court, native then engine rendering)
    ("oneshot_follow pba_demo", lambda: py("oneshot_follow.py")),
    # props on the paths through openings (portal and probe paths), not only on the straight line
    ("path_obstruction", lambda: py("path_obstruction.py")),
    # one model for a partly blocked opening: a prop covering part of a doorway = a leaf covering the same part
    ("mask_equivalence", lambda: py("mask_equivalence.py")),
    # special sounds: grates and fences (CONTENTS_GRATE) cost no wall loss, do not cut probe links and
    # stay out of the Steam Audio scene (12 grates of d1_canals_01)
    ("grate_loss d1_canals_01", lambda: seq(lambda: load("d1_canals_01"), lambda: job("client", "grate_loss.lua", 60))),
    # how the map wires its broadcasts (microphones, speakers, scenes): read before the scene is started
    ("broadcast_wiring d1_trainstation_01", lambda: seq(lambda: load("d1_trainstation_01"),
                                                        lambda: job("server", "broadcast_wiring.lua", 15))),
    # HL2 Breencast: microphone -> jumbotron speaker copies (SND_SPEAKER); a long line followed as a mirror
    # keeps the speaker filter (dsp_speaker as the mirror's DSP)
    ("breencast_speaker d1_trainstation_01", lambda: seq(lambda: load("d1_trainstation_01"),
                                                         lambda: job("server", "breencast_speaker.lua", 60))),
    # special sounds: looping ambient_generic already playing at map load (before the hooks) taken over
    ("ambient_start d1_town_01", lambda: seq(lambda: fresh("d1_town_01"), lambda: job("server", "ambient_start.lua", 30))),
    # soundscape ambience around the ear (random positions) left to the engine: not muffled nor echoed
    ("soundscape_check d1_town_01", lambda: seq(lambda: load("d1_town_01"), cheats,
                                                lambda: job("client", "soundscape_check.lua", 90))),
    # Ravenholm fire: a probe near it, and a probe path that hugs the opening's frame (fixed positions)
    ("probe_coverage d1_town_01", lambda: seq(lambda: load("d1_town_01"), lambda: job("client", "probe_coverage.lua", 330))),
    # displacements are one-sided for traces: the same walls from both ends
    ("walls_symmetric gm_construct", lambda: seq(lambda: load("gm_construct"), lambda: job("client", "walls_symmetric.lua", 20))),
    # "^" distance-variant waves: the copy keeps the far wave of a far source (pushed to its real distance)
    ("distvariant gm_construct", lambda: seq(lambda: load("gm_construct"), cheats, lambda: job("client", "distvariant.lua", 60))),
    # golden results of the path computation (perf_crowd scene): bit for bit against paths_golden_ref.txt
    ("paths_golden gm_construct", lambda: py("paths_golden.py")),
    # invisible tool brushes (toolsblockbullets: compiled as glass) cost nothing, do not cut probe links
    ("tool_brushes d2_coast_04", lambda: seq(lambda: load("d2_coast_04"), lambda: job("client", "tool_brushes.lua", 120))),
    # time scale: long sounds end in real time (at 2x the server forgot them halfway); any map
    ("timescale", lambda: seq(any_map, lambda: job("server", "timescale.lua", 60))),
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
    ("field_continuity noportal", lambda: seq(lambda: load("pba_noportal"), lambda: job("client", "field_continuity.lua", 300))),
    # copies of one probe route counted once (report only: field and k-path, new vs former criterion)
    ("probe_dedupe gm_construct", lambda: seq(lambda: load("gm_construct"), lambda: job("client", "probe_dedupe.lua", 600))),
    # cases reported on rp_downtown: a radio upstairs heard through the ceiling (loudest voice first), and
    # behind a pillar of the same room (probes off the floor, no doubled vertex: the route hugs the corner)
    ("downtown_cases rp_downtown", lambda: seq(lambda: load("rp_downtown_v4c_v2"), lambda: job("client", "downtown_cases.lua", 400))),
    # end to end, native: a radio stream in the upper room is reverberant there, and from the street the
    # reverb does not swamp it (send capped by the listener's enclosure, passed on gliding updates too)
    ("downtown_stream rp_downtown", lambda: py("downtown_stream.py")),
    # end to end, native: outside, under an overhang vs one metre left under the open sky, same window: the same level, no enclosure-boosted reverb
    ("melancholia_overhang", lambda: py("melancholia_overhang.py")),
    # other addons' radios keep the distance law their addon chose (a 'same volume everywhere' radio came
    # out 14 dB weaker at 5 m under the physical law): native level = channel law, flat and 250 u ranges
    ("stream_addon_range", lambda: seq(any_map, lambda: native_on(True), lambda: job("client", "stream_addon_range.lua", 60))),
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
SPECIAL_LABELS = {label for label, _ in special_steps}
steps += special_steps

# ------------------------------------------------------------------ verdicts

PASS, FAIL, INCONC, REPORT = "PASS", "FAIL", "INCONCLUSIVE", "REPORT"
RANK = {PASS: 0, REPORT: 1, INCONC: 2, FAIL: 3}
# no criterion by design: listed, never counted
REPORT_ONLY = {"ab_counts tworooms_open", "ab_counts lcorridor", "probe_dedupe gm_construct"}

def _why(d):
    for k in ("err", "error", "why", "fail", "note", "fails", "raw"):
        if isinstance(d, dict) and d.get(k):
            return f"{k}: {json.dumps(d[k], ensure_ascii=False)[:200]}"
    return ""

def _num(x):
    return x if isinstance(x, (int, float)) and not isinstance(x, bool) else None

# criteria of tests that return measurements without a pass field (taken from their headers)
def _check_pure(v):
    d = v[0] if isinstance(v, list) and v else v
    if not isinstance(d, dict):
        return None
    ok, total = _num(d.get("ok")), _num(d.get("total"))
    if ok is not None and total and ok == total:
        return PASS, ""
    return FAIL, f"{ok}/{total} cases passed; fails: {json.dumps(d.get('fails'), ensure_ascii=False)[:200]}"

def _check_menu(d):
    if not isinstance(d, dict) or not d:
        return None
    bad = [f"{name}: {p.get('err') or p.get('overflow')}" for name, p in d.items()
           if not isinstance(p, dict) or p.get("ok") is not True or p.get("overflow")]
    return (PASS, "") if not bad else (FAIL, "; ".join(bad)[:300])

def _check_loop_removed(d):
    if not isinstance(d, dict) or "serverLeft" not in d:
        return None
    ok = (_num(d.get("trackedBeforeRemove")) or 0) >= 1 and d.get("serverLeft") == 0
    return (PASS, "") if ok else (FAIL, f"tracked {d.get('trackedBeforeRemove')} before removal (want >= 1), "
                                        f"{d.get('serverLeft')} mirrors left after (want 0)")

def _check_numeric_equiv(d):
    if not isinstance(d, dict) or "chainsDifferent" not in d:
        return None
    err = _num(d.get("maxPointError"))
    ok = (_num(d.get("pairs")) or 0) > 0 and d.get("chainsDifferent") == 0 and err is not None and err < 1e-3
    return (PASS, "") if ok else (FAIL, f"pairs {d.get('pairs')}, chainsDifferent {d.get('chainsDifferent')} (want 0), "
                                        f"maxPointError {err} (want < 1e-3)")

CHECKS = {"GLuaTest pure suite": _check_pure, "menu_fit": _check_menu, "loop_removed": _check_loop_removed,
          "paths_numeric_equiv pba_demo": _check_numeric_equiv}

def judge_py(o):
    lines = o.out.splitlines()
    last = next((l for l in reversed(lines) if l.strip()), "") or next((l for l in reversed(o.err.splitlines()) if l.strip()), "")
    fails = [l for l in lines if l.startswith("FAIL")]
    if o.rc != 0:
        return FAIL, f"exit code {o.rc}: " + (fails[0] if fails else last)[:200]
    if fails:
        return FAIL, fails[0][:200]
    for i in range(len(lines) - 1, -1, -1):  # last JSON object printed (possibly indented over several lines)
        if lines[i].startswith("{"):
            try:
                d = json.loads("\n".join(lines[i:]))
            except ValueError:
                continue
            if isinstance(d, dict) and "pass" in d:
                return (PASS, "") if d["pass"] is True else (FAIL, f"pass = {d['pass']!r}")
            break
    m = re.findall(r"^(\d+)/(\d+) passed", o.out, re.M)
    if m:
        n, t = map(int, m[-1])
        return (PASS, "") if n == t and t > 0 else (FAIL, f"{n}/{t} passed")
    if any(l.startswith("PASS") for l in lines):
        return PASS, ""
    return INCONC, "no PASS / FAIL / pass verdict in the output: " + last[:150]

def judge_value(v, nil=FAIL):
    if isinstance(v, PyOut):
        return judge_py(v)
    if isinstance(v, list):
        if not v:
            return FAIL, "empty result"
        worst = (PASS, "")
        for i, x in enumerate(v):
            s, r = judge_value(x, nil)
            if RANK[s] > RANK[worst[0]]:
                worst = (s, f"[{i + 1}/{len(v)}] {r}")
        return worst
    if isinstance(v, dict):
        if "pass" not in v:  # pass = nil arrives as a missing key
            return nil, ("pass = nil / missing " + _why(v)).strip()
        p = v["pass"]
        if p is True:
            return PASS, ""
        return FAIL, (f"pass = {json.dumps(p)} " + _why(v)).strip()
    if isinstance(v, str):
        return FAIL, (v if v.startswith("EXCEPTION") else f"returned a string: {v}")[:300]
    if v is None:
        return FAIL, "no result"
    return FAIL, f"unexpected result: {json.dumps(v)[:200]}"

def verdict(label, out):
    hard = isinstance(out, str) and out.startswith("EXCEPTION") or out is None \
        or isinstance(out, PyOut) and out.rc != 0
    if label in REPORT_ONLY:
        return judge_value(out) if hard else (REPORT, "report only (no criterion)")
    if label in CHECKS and not hard:
        r = CHECKS[label](out)
        if r is not None:
            return r
    return judge_value(out, INCONC if label in SPECIAL_LABELS else FAIL)

# ------------------------------------------------------------------ selection

opts = sys.argv[2:]
if "--special" in opts:
    steps = special_steps
# --quick: the fast checks (about 3 minutes, three maps) to run before each commit; the full battery
# before merging into main or a release
QUICK = {"GLuaTest pure suite", "menu_fit", "portal_sweep tworooms", "bot_gunfire", "loop_removed", "loop_reenable",
         "client_loop", "native_doors", "native_features", "path_hysteresis twodoors", "continuous_ramp twodoors",
         "lowpass_hysteresis twodoors", "door_sweep open", "door_sweep closed"}
if "--quick" in opts:
    steps = [s_ for s_ in steps if s_[0] in QUICK]
# --only=a,b: just these steps (exact labels), in battery order; each sets its own map and state
ONLY = next((a[len("--only="):].split(",") for a in opts if a.startswith("--only=")), None)
if ONLY:
    known = {s_[0] for s_ in steps}
    unknown = [n for n in ONLY if n not in known]
    if unknown:
        print("unknown step(s): " + ", ".join(unknown) + "\nknown steps:\n  " + "\n  ".join(s_[0] for s_ in steps))
        sys.exit(3)
    steps = [s_ for s_ in steps if s_[0] in ONLY]

# ------------------------------------------------------------------ run

results = []  # (label, seconds, verdict, reason)
with open(LOG, "w", encoding="utf-8") as f:
    f.write(f"PBA battery {time.strftime('%Y-%m-%d %H:%M:%S')} args {' '.join(opts) or '(full)'}\n"
            "Full output of every step that did not pass.\n\n")

def step(i, n, label, fn):
    print(f'##progress step={i}/{n} label="Battery" msg="{label}"', flush=True)
    t0 = time.time()
    try:
        out = fn()
    except Exception as e:
        out = f"EXCEPTION {e!r}"
    dt = time.time() - t0
    txt = out.text() if isinstance(out, PyOut) else out if isinstance(out, str) else json.dumps(out, ensure_ascii=False)
    v, why = verdict(label, out)
    results.append((label, round(dt), v, why))
    print(f"=== {label} ({dt:.0f}s): {v}{(' - ' + why) if why else ''}\n{txt[-1500:]}\n", flush=True)
    if v in (FAIL, INCONC):
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(f"===== {label} ({dt:.0f}s): {v} - {why}\n{txt}\n\n")

for i, (label, fn) in enumerate(steps, 1):
    step(i, len(steps), label, fn)
counts = {k: sum(1 for r in results if r[2] == k) for k in (PASS, FAIL, INCONC, REPORT)}
print("##progress done=" + ("ok" if counts[FAIL] == 0 and counts[INCONC] == 0 else "fail"), flush=True)
w = max([len(r[0]) for r in results] + [4])
table = [f"{'step'.ljust(w)}  {'verdict':12}  {'time':>5}  reason", "-" * (w + 40)]
table += [f"{label.ljust(w)}  {v:12}  {dt:>4}s  {why}" for label, dt, v, why in results]
table.append(f"\n{counts[PASS]} PASS, {counts[FAIL]} FAIL, {counts[INCONC]} INCONCLUSIVE, {counts[REPORT]} REPORT"
             f" ({len(results)} steps)" + (f"; full output of the failures in {LOG}" if counts[FAIL] + counts[INCONC] else ""))
print("\n===== VERDICTS =====\n" + "\n".join(table), flush=True)
with open(LOG, "a", encoding="utf-8") as f:
    f.write("===== VERDICTS =====\n" + "\n".join(table) + "\n")
sys.exit(1 if counts[FAIL] else 2 if counts[INCONC] else 0)
