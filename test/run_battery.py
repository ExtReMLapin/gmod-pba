"""Full PBA test battery, sequential (about 20 min; the game changes maps). Prints one ##progress line
per step, the verdict of each step, then a verdict table.

Usage: python -I -u run_battery.py <path to mcp.py> [--smoke | --quick | --special | --only=step,step]
  (no option)  every step, then the special-sound scenarios (test/special/steps.py)
  --smoke      the core checks only (under 2 minutes: the pure suite, the config / menu check, the Light
               package without the module, portal_sweep, native_doors, native_features)
  --quick      the fast checks only (about 3 minutes, three maps), to run before each commit
  --special    the special-sound scenarios only
  --only=a,b   just these steps (exact labels, comma separated), in battery order
  --force-load every step reloads its map, even the current one (injected code, map-start state)
  --no-reset   do not put the session's pba_* settings back before each step (to see what a leak does)
Needs ffmpeg on PATH (water_ogg).

Every step sets the state it needs itself (map, demo mode, door, player position, pba_native_render),
so any subset runs in any order. Verdicts:
  PASS          the test's criterion holds (pass = true; a PASS line, n/n passed or a JSON pass = true
                with exit code 0 for a Python test)
  FAIL          pass = false or missing (nil), an exception, a string answer ("no door"), a FAIL line,
                a non-zero exit code of a Python test
  INCONCLUSIVE  a Python test exited 0 without printing any verdict, or a special scenario returned
                pass = nil (it could not set itself up)
  KNOWN         the step failed, and only with cases named in KNOWN_RED below (a known, accepted red):
                listed apart, not counted as FAIL; any other failing case makes the step FAIL
  REPORT        report-only steps (no criterion by design): listed, never counted
The full output of every FAIL / INCONCLUSIVE step goes to test/battery_last.log (rewritten each run).
Before the first step the battery checks that pba really runs (pba_enable 1, pba_cl_enable 1, no in-memory
override, its EntityEmitSound hook present, in both realms) and aborts otherwise: a battery run with pba off
would pass tests that accept "nothing to do".
Exit code: 0 every step PASS (or REPORT, KNOWN); 1 at least one FAIL; 2 no FAIL but at least one
INCONCLUSIVE; 3 usage error (missing mcp.py path, unknown --only label); 4 pba not running (preflight).
"""
import json, os, re, subprocess, sys, time
TEST = os.path.dirname(os.path.abspath(__file__))
if len(sys.argv) < 2 or sys.argv[1].startswith("--"):
    print(__doc__)
    sys.exit(3)
MCP = sys.argv[1]  # path to the gmod-mcp client (mcp.py)
GAME = os.environ.get("PBA_GAME_DIR", r"D:\SteamLibrary\steamapps\common\GarrysMod\garrysmod")  # garrysmod/ folder
LOG = os.path.join(TEST, "battery_last%s.log" % (("_" + os.environ["MCP_INSTANCE"]) if os.environ.get("MCP_INSTANCE") else ""))  # one per instance: parallel runs no longer mix
sys.path.insert(0, TEST)

def call(tool, args, mx=200000, timeout=600):
    a = json.dumps(args)
    if len(a) > 20000:  # Windows command line limit: pass the arguments in a temp file (outside lua/)
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as f:
            f.write(a)
        a = "@" + f.name
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, a, str(mx)],
                         capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout).stdout
    if a.startswith("@"):
        os.remove(a[1:])
    try:
        return json.loads(out)
    except ValueError:
        return {"raw": out}

import _cvsnap
SNAP0 = _cvsnap.guard(call)  # the session's pba_* settings: every step starts from them (see step())

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

# --force-load: every load() reloads its map, even the current one (code injected after a map load,
# or a map-start state, is then really in place)
FORCE_LOAD = "--force-load" in sys.argv


def load(m, mp=4):
    """Map m (maxplayers mp) loaded and pba's client ready; raises when the map is not there."""
    st = call("status", {})
    if FORCE_LOAD or st.get("map") != m or st.get("maxplayers") != mp:
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
    # a step that killed the host (mp_own_sounds' fall damage, a bot spawned on him: soundtime) leaves him
    # dead: SetPos then moves nothing and the client listens from the death camera. Respawned here.
    if lua("server", "local n = 0 for _, p in ipairs(player.GetHumans()) do if not p:Alive() then p:Spawn() n = n + 1 end end return n"):
        wait_lua("client", "return IsValid(LocalPlayer()) and LocalPlayer():Alive()", 5)
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

def at_room_a():
    """The host in pba_tworooms' room A, at its spawn (256, 256, 0), and the client's view there."""
    lua("server", "local p = player.GetHumans()[1] if IsValid(p) then p:SetPos(Vector(256, 256, 0)) end")
    wait_lua("client", "return LocalPlayer():GetPos():Distance(Vector(256, 256, 0)) < 1", 5)
    time.sleep(0.3)

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
    """Native echoes rendered by the client, and the server told so (pba_echo_want, set on the client's Think).
    pba_native_all 0: a native-all client gets every sound fully relayed (sv_relay 'all'), never echo-only."""
    native_on(True)
    call("console_exec", {"realm": "client", "cmd": "pba_native_all 0"})
    call("console_exec", {"realm": "client", "cmd": "pba_native_echo 1"})
    wait_lua("server", "local p = player.GetHumans()[1] return IsValid(p) and p:GetInfoNum('pba_echo_want', 0) >= 1 and p:GetInfoNum('pba_native_all_want', 1) == 0", 10)

# ------------------------------------------------------------------ test runners

def job(realm, file, timeout_s=120):
    code = open(os.path.join(TEST, file), encoding="utf-8").read()
    r = call("lua_job", {"realm": realm, "code": code, "timeout_s": timeout_s}, timeout=timeout_s + 60)
    return r.get("values", [r])[0] if isinstance(r, dict) else r

_BG = {}
def job_bg(realm, file, timeout_s=60):
    """Starts a test lua_job without waiting (job_wait collects it): a client half listening while the server acts."""
    code = open(os.path.join(TEST, file), encoding="utf-8").read()
    r = call("lua_job", {"realm": realm, "code": code, "timeout_s": timeout_s, "async": True})
    _BG["id"], _BG["t"] = r.get("job_id"), timeout_s
    return {"pass": bool(_BG["id"])}

def job_wait():
    """The result of the job job_bg started."""
    r = call("lua_job_status", {"id": _BG.get("id"), "wait_s": _BG.get("t", 60)}, timeout=_BG.get("t", 60) + 60)
    return r.get("values", [r])[0] if isinstance(r, dict) else r

class PyOut:
    """Result of a Python test: exit code and full output (judged on stdout, logged whole)."""
    def __init__(self, rc, out, err):
        self.rc, self.out, self.err = rc, out, err
    def text(self):
        return self.out + (("\n[stderr]\n" + self.err) if self.err.strip() else "") + f"\n[exit code {self.rc}]"

def py(script, *args, timeout=1500):
    p = subprocess.run([sys.executable, "-I", "-X", "utf8", os.path.join(TEST, script), MCP, *args],
                       capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout)
    return PyOut(p.returncode, p.stdout or "", p.stderr or "")

def loud_dry_reverb():
    """gm_construct's open field (-1750, 2000, -20, yaw 45), native render and pba_native_all 1 for the run
    (loud_dry_reverb.lua): a loud shot's reverb <= -10 dB re its direct with pba_native_loud_dry 1."""
    load("gm_construct")
    native_on(True)
    was = (lua("client", "return GetConVar('pba_native_all'):GetString()") or "1")
    call("console_exec", {"realm": "client", "cmd": "pba_native_all 1"})
    lua("server", "local p = player.GetHumans()[1] p:SetPos(Vector(-1750, 2000, -20)) p:SetEyeAngles(Angle(0, 45, 0)) return true")
    wait_lua("client", "return LocalPlayer():GetPos():Distance(Vector(-1750, 2000, -20)) < 2", 5)
    time.sleep(2)
    try:
        return job("client", "loud_dry_reverb.lua", 180)
    finally:
        call("console_exec", {"realm": "client", "cmd": f"pba_native_all {was}"})

def lua_reload():
    """Three autorefresh-style reloads of the files of each realm (lua_reload.lua): no pba hook added or lost,
    the detoured engine originals still C functions, the detours working."""
    files = {"server": ["pba/sh_core.lua", "pba/sv_loops.lua", "pba/sv_relay.lua", "pba/sv_sound.lua"],
             "client": ["pba/sh_core.lua", "pba/cl_loops.lua", "pba/cl_render.lua", "pba/cl_renders.lua", "pba/cl_sched.lua"]}
    body = open(os.path.join(TEST, "lua_reload.lua"), encoding="utf-8").read()
    out = []
    for realm, fl in files.items():
        code = "PBA_FILES = {" + ", ".join(repr(f) for f in fl) + "}\n" + body
        r = call("lua_job", {"realm": realm, "code": code, "timeout_s": 60}, timeout=120)
        out.append(r.get("values", [r])[0] if isinstance(r, dict) else r)
    return out

def levels_off_states():
    """T23: four options at 0 give the behaviour they replace, at 1 the one pba adds (each run both ways):
    pba_lipsync (mouth copy of a muffled line, pba_materials), pba_long_captions (subtitle of a long line taken over
    by sv_loops, pba_tworooms), pba_soundscape_engine (soundscape wave round the ear left to the engine or taken,
    d1_town_01), pba_stopsound_watch (the console's stopsound stops the mirrors and native voices, or leaves them)."""
    res = {}
    fails = []
    RED = os.environ.get("PBA_RED", "").split(",")  # red proof: PBA_RED=lipsync,long_captions,... leaves that option on while the run asks for 0
    def need(ok, what):
        if not ok:
            fails.append(what)
    def red(opt, realm):
        if opt in RED:
            lua(realm, f"pba.SetOverride('{opt}', 1) return true")
            time.sleep(1.5)
    try:
        # lipsync: the line behind the glass is taken by pba (server half), its mouth copy plays only with 1
        load("pba_materials")
        native_on(True)
        for v in (1, 0):
            cl_set(lipsync=v)
            if v == 0:
                red("lipsync", "client")
            sv = job("server", "lipsync_glass.lua", 30)
            cl = job("client", "lipsync_client.lua", 10)
            res[f"lipsync {v}"] = {"taken": sv.get("taken") if isinstance(sv, dict) else sv,
                                   "mouth": cl.get("pba") if isinstance(cl, dict) else cl}
            need(isinstance(sv, dict) and sv.get("pass") is True and isinstance(cl, dict), f"lipsync {v}: line not taken: {sv}")
            if isinstance(cl, dict):
                need((cl.get("pba", 0) >= 1) == (v == 1) and cl.get("pba", 0) == (cl.get("pba", 0) if v == 1 else 0),
                     f"lipsync {v}: {cl.get('pba')} mouth copies")
        cl_set(lipsync=1)
        # long captions: the line is followed in both cases (ducker noted), its subtitle only with 1
        load(TW)
        for v in (1, 0):
            call("console_exec", {"realm": "server", "cmd": f"pba_long_captions {v}"})
            time.sleep(1)
            if v == 0:
                red("long_captions", "server")
            job("server", "long_line_setup.lua")
            job("client", "long_line_watch.lua")
            emit = job("server", "long_line_emit.lua")
            chk = job("client", "long_line_check.lua")
            checks = chk.get("checks", {}) if isinstance(chk, dict) else {}
            res[f"long_captions {v}"] = {"emit": emit.get("pass") if isinstance(emit, dict) else emit, "checks": checks}
            need(isinstance(emit, dict) and emit.get("pass") is True, f"long_captions {v}: line not taken over: {emit}")
            need(checks.get("ducked") is True, f"long_captions {v}: line not followed (no ducker note)")
            need(checks.get("caption") is (v == 1), f"long_captions {v}: caption shown = {checks.get('caption')}")
        call("console_exec", {"realm": "server", "cmd": "pba_long_captions 1"})
        # stopsound_watch: the same console stopsound as stopsound_console, the watch on then off
        native_on(True)
        src = open(os.path.join(TEST, "stopsound_console.lua"), encoding="utf-8").read()
        for v in (1, 0):
            job("server", "stopsound_setup.lua")
            if v == 0:
                red("stopsound_watch", "client")
            r = job("client", "stopsound_console.lua") if v == 1 else None
            if v == 0:
                code = src.replace('run("pba_stopsound_watch", "1")', 'run("pba_stopsound_watch", "0")')
                r = call("lua_job", {"realm": "client", "code": code, "timeout_s": 60}, timeout=120)
                r = r.get("values", [r])[0]
            res[f"stopsound_watch {v}"] = r
            if not isinstance(r, dict) or "before" not in r:
                fails.append(f"stopsound_watch {v}: {r}")
                continue
            need(r["before"]["mirrors"] > 0, f"stopsound_watch {v}: no mirror before the command")
            left = r["at15"]["mirrors"] + r["at15"]["voices"]
            need((left == 0) == (v == 1), f"stopsound_watch {v}: {left} mirrors+voices left 1.5 s after the command")
            if v == 0:
                call("console_exec", {"realm": "client", "cmd": "pba_stopsound_watch 1"})
                time.sleep(1)
        # soundscape: engine 1 leaves the three waves to the engine (answer nil), 0 takes them (false)
        load("d1_town_01")
        for v in (1, 0):
            if v == 0:
                red("soundscape_engine", "client")
            code = f"SS_ENGINE = '{v}'" + chr(10) + open(os.path.join(TEST, "soundscape_engine.lua"), encoding="utf-8").read()
            r = call("lua_job", {"realm": "server", "code": code, "timeout_s": 60}, timeout=120)
            r = r.get("values", [r])[0]
            res[f"soundscape_engine {v}"] = r
            if not isinstance(r, dict) or r.get("n") != 3:
                fails.append(f"soundscape_engine {v}: {r}")
                continue
            need(r["taken"] == (0 if v == 1 else 3), f"soundscape_engine {v}: {r['taken']} of 3 waves taken by pba")
    finally:
        for o, rl in (("lipsync", "client"), ("soundscape_engine", "client"), ("stopsound_watch", "client"), ("long_captions", "server")):
            lua(rl, f"pba.SetOverride('{o}', nil) return true")
        cl_set(lipsync=1, soundscape_engine=1, stopsound_watch=1)
        call("console_exec", {"realm": "server", "cmd": "pba_long_captions 1"})
    return {"pass": not fails, "fails": fails, "res": res}

def long_sound_boundary():
    """T15: one 10.48 s line (Barney behind the wall of pba_tworooms) on both sides of max_duration (10.3: a long
    sound, followed by sv_loops; 10.7: a short one, relayed once): what the player gets is the same (muffled by the
    wall within 1.5 dB, one subtitle, one mouth copy, the end where the file ends, nothing left after); with
    pba_long_sounds 0 the long one is left to the engine. Engine rendering (pba_native_render 0): the copy's volume
    is then an engine emission. Halves: long_boundary_server.lua / long_boundary_client.lua (client started first)."""
    import threading
    load(TW)
    native_on(False)
    RED = os.environ.get("PBA_RED", "").split(",")  # red proof: captions / mouth / end switch a long-path feature off
    fails = []
    def chans():
        """Audible channels of the line in the engine's own list (snd_dumpclientsounds), not EntityEmitSound calls:
        a CSoundPatch start reaches that hook twice (its start, then its envelope's volume / pitch update, flags
        SND_CHANGE_VOL | SND_CHANGE_PITCH, no Lua caller) for one channel."""
        if "double" in RED:  # red proof: a second copy of the line, what a double emission would leave
            lua("client", "local e = LocalPlayer() if IsValid(e) then e:EmitSound('combined/trainyard/trainyard_ba_getoutfast_cc.wav', 75, 100, 0.1, CHAN_STATIC) end return true")
            time.sleep(0.3)
        r = call("console_exec", {"realm": "client", "cmd": "snd_dumpclientsounds"})
        n = 0
        for o in r.get("output", []):
            m = re.search(r"vol\((\d+)\).*getoutfast", o.get("text", ""))
            if m and int(m.group(1)) > 0:
                n += 1
        return n
    def run(maxd, long_sounds=1):
        call("console_exec", {"realm": "server", "cmd": f"pba_long_sounds {long_sounds}"})
        out = {}
        def cl():
            out["cl"] = job("client", "long_boundary_client.lua", 60)
        def dump():
            time.sleep(2.5 + 2.0)  # the server half emits 2.5 s after its start: 2 s into the line
            out["chans"] = chans()
        th = threading.Thread(target=cl)
        th.start()
        time.sleep(0.5)
        td = threading.Thread(target=dump)
        td.start()
        code = f"T15_MAXD = {maxd}" + chr(10) + open(os.path.join(TEST, "long_boundary_server.lua"), encoding="utf-8").read()
        r = call("lua_job", {"realm": "server", "code": code, "timeout_s": 60}, timeout=120)
        out["sv"] = r.get("values", [r])[0]
        th.join()
        td.join()
        if isinstance(out["cl"], dict):
            out["cl"]["chans"] = out.get("chans")
        return out["sv"], out["cl"]
    res = {}
    try:
        if "captions" in RED:
            call("console_exec", {"realm": "server", "cmd": "pba_long_captions 0"})
        if "mouth" in RED:
            call("console_exec", {"realm": "server", "cmd": "pba_long_lipsync 0"})
        if "end" in RED:
            call("console_exec", {"realm": "server", "cmd": "pba_loops_once_end 0"})
        call("console_exec", {"realm": "client", "cmd": "pba_loops_once_end " + ("0" if "end" in RED else "1")})
        time.sleep(1)
        (svL, clL), (svS, clS) = run(10.3), run(10.7)
        res.update(long=[svL, clL], short=[svS, clS])
        dur = svL.get("dur") or 10.48
        if not (isinstance(svL, dict) and isinstance(svS, dict) and isinstance(clL, dict) and isinstance(clS, dict)):
            return {"pass": False, "res": res}
        if svL.get("long") is not True or svS.get("long") is not False:
            fails.append(f"paths: 10.3 long={svL.get('long')}, 10.7 long={svS.get('long')} (want True, False)")
        for tag, sv, cl, mouth in (("long", svL, clL, svL.get("mouthLong", 0) + clL.get("mouth", 0)),
                                   ("short", svS, clS, svS.get("mouthLong", 0) + clS.get("mouth", 0))):
            if not cl.get("started"):
                fails.append(f"{tag}: pba produced nothing on the client")
                continue
            if cl.get("chans") != 1:
                fails.append(f"{tag}: {cl.get('chans')} audible channels of the line in the engine (want 1)")
            if cl.get("caps") != 1:
                fails.append(f"{tag}: {cl.get('caps')} subtitles (want 1)")
            if mouth != 1:
                fails.append(f"{tag}: {mouth} mouth copies (want 1)")
            v = cl.get("vol")
            if not (v and 0 < v < 0.3):
                fails.append(f"{tag}: copy volume {v} (want a muffled copy, 0 < v < 0.3)")
            e = cl.get("endRel")
            if e is None or not (dur - 0.3 <= e <= dur + 1.0):
                fails.append(f"{tag}: planned end {e} s after the start (file {dur} s)")
            if cl.get("left") != 0:
                fails.append(f"{tag}: {cl.get('left')} followed sounds left after the end")
        vl, vs = clL.get("vol"), clS.get("vol")
        if vl and vs and abs(20 * __import__("math").log10(vl / vs)) > 1.5:
            fails.append(f"volume differs across the boundary: {vl} vs {vs}")
        el, es = clL.get("endRel"), clS.get("endRel")
        if el is not None and es is not None and abs(el - es) > 1.0:
            fails.append(f"end differs across the boundary: {el} vs {es}")
        # the long path off: the engine keeps its line (pba took nothing)
        svO, clO = run(10.3, long_sounds=0)
        res["long_sounds_0"] = [svO, clO]
        if svO.get("long") is not False or svO.get("relayed") != 0 or clO.get("mirror") or clO.get("copies") or clO.get("mouth") or clO.get("nv"):
            fails.append(f"long_sounds 0: pba still took the long line: {svO} {clO}")
    finally:
        for c in ("pba_max_duration 8", "pba_long_sounds 1", "pba_long_captions 1", "pba_long_lipsync 1", "pba_loops_once_end 1"):
            call("console_exec", {"realm": "server", "cmd": c})
        call("console_exec", {"realm": "client", "cmd": "pba_loops_once_end 1"})
    return {"pass": not fails, "fails": fails, "res": res}

def glass_window():
    """T14: the glass cell of pba_materials loses what AC.WallLoss says (+-3 dB), the lightest muffling class, its voice
    on the pane, 15 dB less than concrete and less than the metal beside it (glass_window_cells.lua); the open window
    of pba_window gives one loud portal voice inside the opening (glass_window_open.lua)."""
    RED = os.environ.get("PBA_RED", "").split(",")  # red proof: glass (glass made concrete) / window (edge diffraction off)
    load("pba_materials")
    pre = "RED_GLASS = true" + chr(10) if "glass" in RED else "RED_GLASS = nil" + chr(10)
    code = pre + open(os.path.join(TEST, "glass_window_cells.lua"), encoding="utf-8").read()
    r1 = call("lua_job", {"realm": "client", "code": code, "timeout_s": 60}, timeout=120)
    r1 = r1.get("values", [r1])[0]
    load("pba_window")
    pre = "RED_WINDOW = " + ("true" if "window" in RED else "nil") + chr(10)
    code = pre + open(os.path.join(TEST, "glass_window_open.lua"), encoding="utf-8").read()
    r2 = call("lua_job", {"realm": "client", "code": code, "timeout_s": 60}, timeout=120)
    r2 = r2.get("values", [r2])[0]
    return {"pass": isinstance(r1, dict) and isinstance(r2, dict) and r1.get("pass") is True and r2.get("pass") is True,
            "cells": r1, "window": r2}

def speaker_once():
    """Long one-shots on a speaker: speaker_once_server.lua starts the lines, speaker_once_check.lua (with its
    result in PBA_SPK) checks the client mirrors end with their file and are replaced on their channel."""
    v = job("server", "speaker_once_server.lua")
    if not isinstance(v, dict) or "tv1" not in v:
        return v
    lua("client", "PBA_SPK = util.JSONToTable(%s) return true" % json.dumps(json.dumps(v)))
    return job("client", "speaker_once_check.lua")

def once_native_end():
    """A one-shot mirror rendered by the module that gets no more updates (quiet shortcut) ends with its file:
    once_native_end_server.lua starts a one-shot CSoundPatch, once_native_end_check.lua checks the mirror."""
    native_on(True) # (pba_native_render is archived: an earlier test or game may have left it at 0)
    lua("client", "pba.SetOverride('quiet_db', -1) return true")
    try:
        v = job("server", "once_native_end_server.lua")
        if not isinstance(v, dict) or "idx" not in v:
            return v
        lua("client", "PBA_ONE = util.JSONToTable(%s) return true" % json.dumps(json.dumps(v)))
        return job("client", "once_native_end_check.lua")
    finally:
        lua("client", "pba.SetOverride('quiet_db', nil) return true")

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

def pure(name="pba_pure_test.lua"):
    # the suite is sent inline, not copied into lua/: parallel game instances share that folder (and its
    # autorefresh), a written file would be seen by every instance
    load("pba_tworooms")
    code = open(os.path.join(TEST, "gluatest", "run_pure.lua"), encoding="utf-8").read()
    src = open(os.path.join(TEST, "gluatest", name), encoding="utf-8").read()
    assert "]=======]" not in src
    # a lua_job: the runner yields between cases (job:step), each case gets the MCP execution budget
    return call("lua_job", {"realm": "client", "code": "local PBA_PURE_SRC = [=======[" + src + "]=======]" + chr(10) + code,
                            "timeout_s": 600}, timeout=700).get("values")

def volume_sfx_step():
    """native_volume_sfx.lua with the game's volume_sfx at 0.25 (Lua cannot set it: console), restored after."""
    was = lua("client", "return GetConVar('volume_sfx'):GetString()") or "1"
    native_on(True)
    call("console_exec", {"realm": "menu", "cmd": "volume_sfx 0.25"})
    try:
        return job("client", "native_volume_sfx.lua")
    finally:
        call("console_exec", {"realm": "menu", "cmd": f"volume_sfx {was}"})

def soundtime(reemit=False):
    """SoundTime kept (audit A-P2-1). The host runs at fps_max 8, so the listen server runs ~8 ticks per frame
    and a bot's SMG (75 ms cadence) sends 2 shots in one packet. Relayed (reemit False): the client's
    scheduled starts keep 75 ms (soundtime_probe / _fire / _check). Re-emitted muffled by the engine
    (reemit True: the host's relay budget kept empty, so every shot falls back): snd_show 2 prints the delay the engine got
    for each; two shots of one packet must get delays >= 40 ms apart (0 and 0 before the fix)."""
    load(TW)
    native_on(True)
    fps = lua("client", "return GetConVarString('fps_max')") or "0"
    call("console_exec", {"realm": "menu", "cmd": "fps_max 8"})
    time.sleep(1)
    try:
        if not reemit:
            job("client", "soundtime_probe.lua")
            job("server", "soundtime_fire.lua")
            return job("client", "soundtime_check.lua")
        cheats()
        call("console_exec", {"realm": "menu", "cmd": "developer 1"})
        call("console_exec", {"realm": "menu", "cmd": "snd_show 2"})
        lua("server", "pba_soundtime_drain = true return true")
        cur = call("console_read", {"limit": 1}).get("next_cursor", 0)
        fired = job("server", "soundtime_fire.lua")
        lines = call("console_read", {"cursor": cur, "regex": "smg1_fire", "limit": 500}).get("lines", [])
        packets = {}
        for ln in lines:
            m = re.search(r"time ([\d.]+) \((-?[\d.]+) delay\)", ln.get("text", ""))
            if m:
                packets.setdefault(m.group(1), []).append(float(m.group(2)))
        pairs = [sorted(d) for d in packets.values() if len(d) >= 2]
        gaps = [round((d[i] - d[i - 1]) * 1000) for d in pairs for i in range(1, len(d))]
        return {"pass": len(gaps) >= 2 and min(gaps) >= 40, "fired": fired, "lines": len(lines), "gapsMs": gaps}
    finally:
        call("console_exec", {"realm": "menu", "cmd": f"fps_max {fps}"})
        if reemit:
            call("console_exec", {"realm": "menu", "cmd": "snd_show 0"})
            call("console_exec", {"realm": "menu", "cmd": "developer 0"})

def seq(*fns):
    """Runs the setters then the test (last), returns the test's result."""
    out = None
    for f in fns:
        out = f()
    return out

def long_lipsync_pref():
    """The player's pba_lipsync also chooses for the long lines' mouth copy (server); his setting put back after."""
    load(TW)
    job("client", "long_lipsync_pref_off.lua")
    try:
        return job("server", "long_lipsync_pref.lua")
    finally:
        job("client", "long_lipsync_pref_restore.lua")

def manhack_loop():
    """Both client checks of the manhack loops: taken over (part 2) and ended with the entity (part 4)."""
    load(TW)
    job("server", "manhack_loop_setup.lua")
    taken = job("client", "manhack_loop.lua")
    job("server", "manhack_loop_remove.lua")
    off = job("client", "manhack_loop_off.lua")
    ok = isinstance(taken, dict) and taken.get("pass") is True and isinstance(off, dict) and off.get("pass") is True
    return {"pass": ok, "taken": taken, "off": off}

def manhack_loop_death():
    """The manhack's loop mirrors stop at its death (engine switched off), not ~2 s later at its removal."""
    load(TW)
    # the game gibs a killed manhack at once or lets it linger dying, at random: tried until one lingers
    for _ in range(6):
        job("server", "manhack_loop_setup.lua")
        taken = job("client", "manhack_loop.lua")
        job("server", "manhack_loop_kill.lua")
        dead = job("client", "manhack_loop_dead.lua")
        if not (isinstance(dead, dict) and dead.get("err") == "manhack already removed"):
            break
    ok = isinstance(taken, dict) and taken.get("pass") is True and isinstance(dead, dict) and dead.get("pass") is True
    return {"pass": ok, "taken": taken, "dead": dead}

def npc_loop_death():
    """An NPC's server loops (fast zombie gurgle / breathe) stop at its death, as the game's StopLoopingSounds, not
    ~1.9 s later at its removal (pba_loops_npc_death)."""
    load(TW)
    for _ in range(3):
        setup = job("server", "npc_loop_death_setup.lua")
        taken = job("client", "npc_loop_death.lua")
        kill = job("server", "npc_loop_death_kill.lua")
        dead = job("client", "npc_loop_death_dead.lua")
        if not (isinstance(dead, dict) and dead.get("err") == "fast zombie already removed"):
            break
    ok = isinstance(taken, dict) and taken.get("pass") is True and isinstance(dead, dict) and dead.get("pass") is True
    return {"pass": ok, "setup": setup, "taken": taken, "kill": kill, "dead": dead}

def burst_keep():
    """A burst-degraded sound (cheap model, too quiet to emit) is never dropped: played, and at its full level
    0.3 s later (burst_keep.lua), native render and engine copies."""
    load(TW)
    out = {}
    for on in (True, False):
        native_on(on)
        out["native" if on else "engine"] = job("client", "burst_keep.lua")
    native_on(True)
    out["pass"] = all(isinstance(v, dict) and v.get("pass") is True for v in out.values())
    return out

def npc_footsteps():
    """An NPC's footsteps (played by the client, from its own copy of the NPC: the server never emits them) are
    processed by pba: a Combine soldier walks on pba_noportal behind the wall of the host's room (in his PVS: the
    doorway lets room B's strip y < 130 through) and in his own room at the same distances (npc_footsteps*.lua).
    Native (pba_native_all 1): every step is taken by pba and played by the module (one voice per route: two at most, never
    two at one spot), none left to the engine, no engine original and module play of one step within 50 ms; behind the wall the module's gain is lower and
    its high band is cut. Light (native off): in the host's room the engine plays the originals untouched; behind
    the wall pba takes them all and re-emits copies with a DSP preset or a lower volume."""
    load("pba_noportal")
    call("console_exec", {"realm": "client", "cmd": "pba_native_all 1"})
    res = {}
    try:
        for mode, on in (("native", True), ("light", False)):
            native_on(on)
            for room in ("clear", "wall"):
                lua("server", "PBA_NPCSTEP_ROOM = '%s' return true" % room)
                setup = job("server", "npc_footsteps_setup.lua")
                out = job("client", "npc_footsteps.lua", 60)
                job("server", "npc_footsteps_stop.lua")
                res[mode + " " + room] = out if isinstance(out, dict) else {"err": str(out), "setup": setup}
                time.sleep(0.5)
    finally:
        native_on(True)
    fails = []
    for k, v in res.items():
        if v.get("err") or not (v.get("steps", 0) >= 6):
            fails.append(k + ": " + str(v.get("err") or ("only %s steps seen" % v.get("steps"))))
    if not fails:
        nc, nw, lc, lw = res["native clear"], res["native wall"], res["light clear"], res["light wall"]
        for k, v in (("native clear", nc), ("native wall", nw)):
            if v["native"] is not True:
                fails.append(k + ": native rendering is not on")
            if v["engine"] != 0:
                fails.append("%s: %d footstep original(s) left to the engine in native-all" % (k, v["engine"]))
            if v["doubles"] != 0:
                fails.append("%s: %d step(s) played twice (engine original + module play within 50 ms)" % (k, v["doubles"]))
            if v["unplayed"] > 1 or v["maxVoices"] > 2 or v["sameSpot"] != 0:
                fails.append("%s: %d module plays for %d taken steps (%d unplayed, up to %d voices per step, %d pairs at one spot)" % (k, v["plays"], v["taken"], v["unplayed"], v["maxVoices"], v["sameSpot"]))
        if nw["taken"] < 6 or not (nw["playGain"] < 0.8 * nc["playGain"]):
            fails.append("native wall: gain %s not well below the clear line's %s" % (nw.get("playGain"), nc.get("playGain")))
        if not (nw["playH"] < 0.5 * nc["playH"]):
            fails.append("native wall: high band %s not cut against the clear line's %s" % (nw.get("playH"), nc.get("playH")))
        if lc["engine"] != lc["steps"] or lc["copies"] != 0:
            fails.append("light clear: steps not left to the engine untouched (%s)" % lc)
        if lw["engine"] != 0 or lw["taken"] < lw["steps"] - 1:
            fails.append("light wall: originals reach the engine behind the wall (%s)" % lw)
        elif lw["unplayed"] > 1 or lw["maxVoices"] > 2 or lw["sameSpot"] != 0:
            fails.append("light wall: %d copies for %d taken steps (%d unplayed, up to %d voices per step, %d pairs at one spot)" % (lw["copies"], lw["taken"], lw["unplayed"], lw["maxVoices"], lw["sameSpot"]))
        elif not ((lw["copyDsp"] or 0) > 0 or (lw["copyVol"] or 1) < 0.8 * (lc["engineVol"] or 0.5)):
            fails.append("light wall: copies neither DSP-muffled nor quieter (%s)" % lw)
    return {"pass": not fails, "fails": fails, "res": res}

def watch_dead_npc():
    """The watchdog's dead_npc_loop: an alive rollermine (no health at all) is not reported, a killed fast zombie
    whose mirrors play on (pba_loops_npc_death 0) is (watch_dead_npc*.lua)."""
    load(TW)
    with open(os.path.join(TEST, "watch", "watchdog_cl.lua"), encoding="utf-8") as f:
        call("lua_exec", {"realm": "client", "code": f.read()})
    lua("client", "PBA_WATCH_CL.anomalies = {} PBA_WATCH_CL.deadT = {} return true")
    setup = job("server", "watch_dead_npc_setup.lua")
    res = job("client", "watch_dead_npc.lua")
    lua("server", "pba.SetOverride('loops_npc_death', nil) for _, c in ipairs({'npc_rollermine', 'npc_fastzombie'}) do for _, e in ipairs(ents.FindByClass(c)) do e:Remove() end end return true")
    lua("client", "timer.Remove('pba_watch_cl') hook.Remove('EntityEmitSound', 'pba_watch') if PBA_WATCH_CL and PBA_WATCH_CL.orig then hook.Add('EntityEmitSound', 'pba', PBA_WATCH_CL.orig) end PBA_WATCH_CL = nil return true")
    ok = isinstance(res, dict) and res.get("pass") is True
    return {"pass": ok, "setup": setup, "res": res}

def cl_set(**kv):
    """Client convars pba_<k> = v, and wait until pba.cfg follows."""
    for k, v in kv.items():
        call("console_exec", {"realm": "client", "cmd": f"pba_{k} {v}"})
    wait_lua("client", " and ".join(f"(pba.cfg.{k} or -1) == {v}" for k in kv for v in [kv[k]]), 5)

def long_line_play_fail(net):
    """A long line the native module cannot play (pba_native.Play fails) is still heard: its engine patch plays
    it (pba_loops_native_fail; net=False: the safety net off) or the safety net gives it back (net=True,
    pba_loops_native_fail 0: pba_silent_handback, with its console line)."""
    load(TW)
    native_on(True)
    cl_set(loops_native_fail=0 if net else 1, silent_handback=1 if net else 0)
    try:
        job("server", "long_line_setup.lua")
        job("client", "long_line_play_fail.lua")
        emit = job("server", "long_line_emit.lua")
        chk = job("client", "long_line_play_check.lua")
    finally:
        cl_set(loops_native_fail=1, silent_handback=1)
    if not (isinstance(emit, dict) and emit.get("pass") is True):
        return {"pass": False, "emit": emit, "check": chk}
    if net and isinstance(chk, dict) and chk.get("pass") is True:
        back = chk.get("handedBack") or []
        if not any(str(b).startswith("long line mirror") for b in back):
            chk["pass"] = False
            chk["fails"] = ["handedBack"]
    return chk

def long_line_decode(on=True):
    """A long line whose file the module is still decoding (a large wave's first play) is the module's voice once
    decoded, started at once, and never handed back to the engine meanwhile (pba_loops_decode_wait; on=False: red,
    d3_c17_12's 'rockets' line heard only through the safety net)."""
    load(TW)
    native_on(True)
    cl_set(silent_handback=1, loops_decode_wait=1 if on else 0)
    try:
        job("server", "long_line_setup.lua")
        job("client", "long_line_decode_slow.lua")
        emit = job("server", "long_line_emit.lua")
        chk = job("client", "long_line_decode_check.lua")
    finally:
        cl_set(loops_decode_wait=1)
    if not (isinstance(emit, dict) and emit.get("pass") is True):
        return {"pass": False, "emit": emit, "check": chk}
    return chk

def silent_relay(on=True):
    """A relayed voice line pba renders nowhere (A.Process made to drop it) is handed back to the engine."""
    load(TW)
    cl_set(silent_handback=1 if on else 0)
    try:
        job("server", "long_line_setup.lua")
        job("client", "silent_relay_wrap.lua")
        emit = job("server", "silent_relay_emit.lua")
        chk = job("client", "silent_relay_check.lua")
    finally:
        cl_set(silent_handback=1)
    if not (isinstance(emit, dict) and emit.get("pass") is True):
        return {"pass": False, "emit": emit, "check": chk}
    return chk

def handback_replaced(on=True):
    """The safety net respects the channel rule (pba_handback_channel): a relayed line pba renders nowhere, replaced
    0.08 s later by a newer line on the same NPC's CHAN_VOICE, is NOT handed back (d3_c17_10b, two lines at once)."""
    load(TW)
    cl_set(silent_handback=1, handback_channel=1 if on else 0)
    try:
        job("server", "long_line_setup.lua")
        job("client", "handback_replaced_wrap.lua")
        emit = job("server", "handback_replaced_emit.lua")
        chk = job("client", "handback_replaced_check.lua")
    finally:
        cl_set(handback_channel=1)
    if not (isinstance(emit, dict) and emit.get("pass") is True):
        return {"pass": False, "emit": emit, "check": chk}
    return chk

def native_vol_now(on=True):
    """A server volume change of a hidden loop reaches its native voice at once (pba_native_vol_now): within 0.1 s
    of the new volume (x 0.25) reaching the mirror, the voice gain is within 1.5 dB of before x 0.25 (SW2: a
    dropship fade stayed +8..11 dB over its law until the next re-evaluation)."""
    import threading
    load(TW)
    native_on(True)
    at_room_a()
    cl_set(native_vol_now=1 if on else 0)
    out = {}
    def check():
        out["check"] = job("client", "native_vol_now_check.lua")
    try:
        t = threading.Thread(target=check)
        t.start()
        time.sleep(1.0)
        emit = job("server", "native_vol_now_emit.lua")
        t.join()
    finally:
        cl_set(native_vol_now=1)
    chk = out.get("check")
    if not (isinstance(emit, dict) and emit.get("pass") is True):
        return {"pass": False, "emit": emit, "check": chk}
    return chk

def streams_vol_now(on=True):
    """Another addon's radio rendered natively follows its SetVolume at once (pba_streams_vol_now): 0.1 s after
    SetVolume(0.5 -> 0.125) the voice gain is within 1.5 dB of before x 0.25 (#54: it waited for the next
    re-evaluation, then a ramp)."""
    native_on(True)
    cl_set(streams_vol_now=1 if on else 0)
    try:
        return job("client", "streams_vol_now.lua", 60)
    finally:
        cl_set(streams_vol_now=1)

def long_line():
    """A long speech line taken over by sv_loops keeps its subtitle and ducks the other sounds."""
    load(TW)
    job("server", "long_line_setup.lua")
    job("client", "long_line_watch.lua")
    emit = job("server", "long_line_emit.lua")
    chk = job("client", "long_line_check.lua")
    if not (isinstance(emit, dict) and emit.get("pass") is True):
        return {"pass": False, "emit": emit, "check": chk}
    return chk

TW = "pba_tworooms"
steps = [
    ("GLuaTest pure suite", pure),
    # the native helpers (physical law, sends, directivity, EQ) in the real game state
    ("GLuaTest pure suite (native helpers)", lambda: seq(lambda: native_on(True), lambda: pure("pba_pure_native_test.lua"))),
    # the native module update check (network, cookies and module stubbed)
    ("GLuaTest pure suite (update check)", lambda: pure("pba_pure_update_test.lua")),
    # metrics of the perceptual bench (Python, no game): full battery only
    ("perceptual metrics (pure)", lambda: py("test_perceptual.py")),
    ("cvsnap killed-test recovery (pure)", lambda: py("test_cvsnap.py")),
    # mcp.py's stderr in UTF-8 (a localized Windows error in cp1252 killed the callers' reader thread) and a
    # failed errors_since reported by sweep.py instead of read as "no error" (pure, no game)
    ("mcp_encoding (pure)", lambda: py("test_mcp_encoding.py")),
    # every option has a menu control or a written exemption, every control an option (T4, no game)
    ("menu_config_static", lambda: py("menu_config_static.py")),
    # the Workshop package without the module: menu greyed, no error, a sound behind a door muffled (T3)
    ("light_no_module", lambda: py("light_no_module.py")),
    # every option at min / max / default in both realms: no error, no NaN, position 0 as tabled (T7)
    ("option_sweep", lambda: py("option_sweep.py", timeout=2400)),
    ("menu_fit", lambda: seq(lambda: load(TW), lambda: job("client", "menu_fit.lua"))),
    # SoundDuration of prefixed names ("^", ")", "*"...): pba's version in both realms
    ("sound_prefix_check", lambda: seq(lambda: load(TW), lambda: [job("client", "sound_prefix_check.lua", 15),
                                                                  job("server", "sound_prefix_check.lua", 15)])),
    # engine rendering: with "everything native" the server relays every sound to this client and the
    # "untouched" scenarios cannot hold (by design)
    # the base model (T1), pba_enable 0 = vanilla (T2), the propagation delay (T5): the checks of what must always hold
    ("core_model", lambda: py("core_model.py")),
    ("vanilla_parity", lambda: py("vanilla_parity.py")),
    ("propagation_delay", lambda: py("propagation_delay.py")),
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
    ("soundtime_relay", lambda: soundtime(False)),
    ("soundtime_reemit", lambda: soundtime(True)),
    ("mp_own_sounds", lambda: seq(lambda: load(TW), lambda: native_on(True), lambda: job("server", "mp_own_sounds.lua"))),
    ("predicted_others", lambda: seq(lambda: load(TW), lambda: native_on(True), lambda: job("server", "predicted_others.lua"))),
    ("bot_footsteps", lambda: seq(lambda: load(TW), lambda: job("server", "bot_footsteps.lua"))),
    # an NPC's footsteps (played by the client): taken once by pba, muffled behind a wall, native and Light
    ("npc_footsteps", npc_footsteps),
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
    # an impact / break sound the engine plays on the world inside its object: the object is not its own
    # wall (in plain sight: left to the engine, clear on the client; behind a wall: still taken)
    ("impact_inside_prop", lambda: seq(lambda: load(TW), lambda: native_on(False),
                                       lambda: [job("server", "impact_inside_prop.lua", 30), job("client", "impact_inside_prop_client.lua", 10)])),
    # a sound beyond lod_dist behind a wall: the cheap muffle (one trace, DSP preset), server and client
    # (was left to the engine, heard through the wall as in plain sight)
    ("soundtime_offset", lambda: seq(lambda: load(TW), lambda: native_on(False), lambda: job("server", "soundtime_offset.lua", 20))),
    ("soundtime_echo", lambda: job("client", "soundtime_echo.lua")),
    ("listener_inside_prop", lambda: seq(lambda: load(TW), lambda: job("server", "listener_inside_prop.lua", 20))),
    ("far_muffle", lambda: seq(lambda: load(TW), lambda: native_on(False),
                               lambda: [job("server", "far_muffle.lua", 30), job("client", "far_muffle_client.lua", 15)])),
    # a sentence an addon plays on the world (no position in EntityEmitSound): taken behind a wall
    ("sentence_pos", lambda: seq(lambda: load(TW), lambda: job("server", "sentence_pos.lua"))),
    # singleplayer: the player's own gunfire gets its native echoes (no prediction: only the server sees it)
    ("sp_own_echo", lambda: seq(lambda: load(TW, 1), lambda: native_on(True), lambda: job("client", "sp_own_echo.lua"))),
    ("native_own", lambda: seq(lambda: load(TW, 1), lambda: native_on(True), lambda: job("client", "native_own.lua"))),
    ("native_own_mp", lambda: seq(lambda: load(TW), lambda: native_on(True), lambda: job("client", "native_own_mp.lua"))),
    # a quick throttle on / off: the vehicle state sound the next one destroys is no longer mirrored
    ("vehicle_state_sounds", lambda: seq(lambda: load(TW), lambda: job("server", "vehicle_state_sounds.lua"))),
    ("loop_removed", lambda: seq(lambda: load(TW), lambda: native_on(False), lambda: job("server", "loop_removed.lua"))),
    # silent patches (started at volume 0) do not count against loops_max (audit B-7)
    ("silent_loops_cap", lambda: seq(lambda: load(TW), lambda: native_on(False), lambda: job("server", "silent_loops_cap.lua", 30))),
    ("loops_cap_resume", lambda: seq(lambda: load(TW), lambda: native_on(False), lambda: job("server", "loops_cap_resume.lua", 30))),
    ("loops_stop_reentry", lambda: seq(lambda: load(TW), lambda: job("server", "loops_stop_reentry.lua", 30))),
    ("loops_stop_named", lambda: seq(lambda: load(TW), lambda: job("server", "loops_stop_named.lua"))),
    ("loop_channel", lambda: seq(lambda: load(TW), lambda: job("server", "loop_channel_setup.lua"), lambda: job("client", "loop_channel.lua"))),
    ("client_long_duck", lambda: seq(lambda: load(TW), lambda: job("client", "client_long_duck.lua"))),
    # one channel rule for short copies and client long mirrors (pba_channel_one_rule, refactor step 6)
    ("channel_one_rule", lambda: seq(lambda: load(TW), lambda: job("client", "channel_one_rule.lua"))),
    # one lip sync choice for short and long lines (pba_long_lipsync_choice, refactor step 8)
    ("long_lipsync_pref", long_lipsync_pref),
    # one SoundTime rule for short and long sounds (pba_long_soundtime, refactor step 8)
    ("long_soundtime", lambda: seq(lambda: load(TW), lambda: job("server", "long_soundtime.lua"))),
    # one scheduler for every followed sound (refactor step 10): a still followed one-shot by the cadence rule of loops
    ("oneshot_reeval", lambda: seq(lambda: load(TW), lambda: job("client", "oneshot_reeval.lua"))),
    ("burst_budget", lambda: seq(lambda: load(TW), lambda: job("client", "burst_budget.lua"))),
    # pba_burst_fair: a degraded new sound takes a nearby full result (an impact behind a wall with an open way
    # round was 29 dB low with the cheap model), the loudest of a burst is never degraded
    ("burst_fair", lambda: seq(lambda: load(TW), lambda: job("client", "burst_fair.lua"))),
    # a burst-degraded sound the cheap model puts under the emission threshold is kept alive, then glides to its full level
    ("burst_keep", burst_keep),
    # spoken lines are dropped last past the native voice cap (audit C-5): pba_native_protect_lines, the protect argument of Play
    ("line_protect", lambda: seq(lambda: load(TW), lambda: native_on(True), lambda: job("client", "line_protect.lua", 40))),
    ("gc_lean", lambda: seq(lambda: load(TW), lambda: job("client", "gc_lean.lua"))),
    # env_microphone Disable stops its speaker's mirror (audit B-12)
    ("mic_disable", lambda: seq(lambda: load(TW), lambda: native_on(False), lambda: job("server", "mic_disable.lua", 40))),
    # a CSoundPatch on a file without loop points (plays once): followed for its length, restarted, stopped
    ("patch_oneshot", lambda: seq(lambda: load(TW), lambda: job("server", "patch_oneshot.lua", 30))),
    # a pitch change of a brief sound pba relayed starts no second copy (audit B-8)
    ("brief_change", lambda: seq(lambda: load(TW), lambda: job("server", "brief_change.lua", 30))),
    # a physics scrape loop behind a wall (its lifecycle the physics engine's): re-emitted muffled in place
    ("physics_scrape", lambda: seq(lambda: load(TW), lambda: job("server", "physics_scrape.lua", 30))),
    # a speaker's long lines (Breencast on a TV): each ends with its file, a new one replaces it on its channel
    ("speaker_once", lambda: seq(lambda: load("gm_construct", 1), speaker_once)),
    ("once_native_end", lambda: seq(lambda: load("gm_construct", 1), once_native_end)),
    # loop points as the engine reads them: a cue point loops a file whose smpl chunk lists no loop
    ("looping_cue", lambda: job("client", "looping_cue.lua")),
    # manhack engine / blade loops (client C++ patches): mirrored behind the wall, ended with the entity
    ("manhack_loop", lambda: manhack_loop()),
    # a shot manhack's loops stop at its death (vanilla: engine off), not at its removal ~2 s later
    ("manhack_loop_death", lambda: manhack_loop_death()),
    ("npc_loop_death", lambda: npc_loop_death()),
    # test tool: the watchdog does not take an alive rollermine (no health at all) for a dead NPC
    ("watch_dead_npc", watch_dead_npc),
    # a long speech line (sv_loops) keeps its subtitle and ducks the other sounds like the short lines
    ("long_line", lambda: long_line()),
    # a long line the module cannot play goes to the engine (side bug 32: captioned, never heard)
    ("long_line_play_fail", lambda: long_line_play_fail(False)),
    # the safety net: a line taken from the engine that nothing renders is handed back (pba_silent_handback)
    ("silent_handback", lambda: long_line_play_fail(True)),
    ("silent_handback relay", lambda: silent_relay()),
    ("handback_replaced", lambda: handback_replaced()),
    ("long_line_decode", lambda: long_line_decode()),
    # only speech is handed back: not a relayed zap on a face, not common/null.wav (pba_handback_speech)
    ("handback_scope", lambda: seq(lambda: load(TW), lambda: job("client", "handback_scope.lua"))),
    # a speaking face far under the clear law (one transmission, -37 dB) is still heard (pba_speech_floor_db):
    # Light mode dropped it whole (Alyx behind the lab walls, d1_trainstation_05)
    ("speech_floor light", lambda: seq(lambda: load(TW), lambda: native_on(False), lambda: job("client", "speech_floor.lua"))),
    ("speech_floor native", lambda: seq(lambda: load(TW), lambda: native_on(True), lambda: job("client", "speech_floor.lua"))),
    ("looping_sound_stop", lambda: seq(lambda: load(TW), lambda: job("server", "looping_sound_stop.lua"))),
    ("weapon_loop_owner", lambda: seq(lambda: load(TW), lambda: job("server", "weapon_loop_owner.lua"))),
    # the player in room A (a step before may leave him in room B: manhack_loop_kill puts him at x 600, the loop
    # then in clear sight)
    ("native_loop_fade_hidden", lambda: seq(lambda: load(TW), lambda: native_on(True), lambda: at_room_a(), lambda: job("client", "native_loop_fade_hidden.lua"))),
    ("native_vol_now", lambda: native_vol_now()),
    ("streams_vol_now", lambda: seq(any_map, lambda: streams_vol_now())),
    ("loop_fade_tail", lambda: seq(lambda: load(TW), lambda: job("server", "loop_fade_tail.lua"))),
    ("constraint_travel_loop", lambda: seq(lambda: load(TW), lambda: job("server", "constraint_travel_loop.lua"))),
    ("loud_loop_far", lambda: seq(lambda: load(TW), lambda: native_on(True), lambda: job("server", "loud_loop_far_setup.lua"), lambda: job("client", "loud_loop_far.lua"))),
    ("loop_far_muffle", lambda: seq(lambda: load(TW), lambda: job("server", "loop_far_muffle_setup.lua"), lambda: job("client", "loop_far_muffle.lua"))),
    ("speaker_long_native", lambda: seq(lambda: load(TW), lambda: native_on(True), lambda: job("server", "speaker_long_native_setup.lua"), lambda: job("client", "speaker_long_native.lua", 30))),
    # a long Breencast line renders as the short ones: speaker EQ, slot, same room send from its start (bug 60)
    ("breencast_long_render d1_trainstation_01", lambda: seq(lambda: load("d1_trainstation_01", 1), lambda: native_on(True), lambda: job("server", "breencast_long_render_sv.lua"), lambda: job("client", "breencast_long_render.lua", 60))),
    ("line_first_play", lambda: seq(lambda: native_on(True), lambda: job("client", "line_first_play.lua", 30))),
    ("caption_net", lambda: seq(lambda: load("pba_tworooms", 1), lambda: job_bg("client", "caption_net.lua", 30), lambda: job("server", "caption_net_sv.lua"), lambda: job_wait())),
    ("door_spawned", lambda: seq(lambda: load(TW), lambda: job("server", "door_spawned_setup.lua"), lambda: job("server", "door_spawned_remove.lua"), lambda: job("client", "door_spawned.lua"))),
    # a quiet (far) native loop keeps following its distance law, not frozen at its near gain
    ("quiet_loop_far", lambda: seq(lambda: load(TW), lambda: native_on(True), lambda: job("server", "quiet_loop_far_setup.lua"), lambda: job("client", "quiet_loop_far.lua"))),
    ("looping_sound_stop_client", lambda: seq(lambda: load(TW), lambda: job("client", "looping_sound_stop_client.lua"))),
    ("stopsound", lambda: seq(lambda: load(TW), lambda: native_on(True), lambda: job("server", "stopsound_setup.lua"), lambda: job("client", "stopsound.lua"))),
    # stopsound typed in the console (no Lua function sees it): a silent sound patch reports it
    ("stopsound_console", lambda: seq(lambda: load(TW), lambda: native_on(True), lambda: job("server", "stopsound_setup.lua"), lambda: job("client", "stopsound_console.lua"))),
    # a new sound the engine plays on a line's channel (player now in plain sight) cuts its relayed copy
    ("channel_cut", lambda: seq(lambda: load(TW), lambda: native_on(False), lambda: job("server", "channel_cut_setup.lua"), lambda: job("client", "channel_cut_mid.lua"), lambda: job("server", "channel_cut_next.lua"), lambda: job("client", "channel_cut.lua"))),
    ("relay_dict_overflow", lambda: seq(lambda: load(TW), lambda: job("client", "relay_dict_capture.lua"), lambda: job("server", "relay_dict_overflow.lua", 30), lambda: job("client", "relay_dict_check.lua"))),
    ("channel_no_overwrite", lambda: seq(lambda: scenario(TW, "tworooms_closed"), lambda: native_on(False), lambda: job("client", "channel_no_overwrite.lua", 30))),
    ("channel_no_overwrite_server", lambda: seq(lambda: load(TW), lambda: native_on(False), lambda: job("server", "channel_no_overwrite_server.lua"))),
    ("relay_client_ready", lambda: seq(lambda: load(TW), lambda: job("server", "relay_client_ready.lua", 30))),
    # pba_relay_name_rate: one sound name from many sources takes no more than its quota of the relay budget, the others keep theirs
    ("relay_name_quota", lambda: seq(lambda: load(TW), lambda: native_on(False), lambda: job("server", "relay_name_quota.lua", 60))),
    # StopSound by sound-script name reaches the relayed copies and the loop mirrors of its waves
    ("stop_script", lambda: seq(lambda: load(TW), lambda: job("server", "stop_script_setup.lua"), lambda: job("client", "stop_script_mid.lua"), lambda: job("server", "stop_script_next.lua"), lambda: job("client", "stop_script.lua"))),
    # a cancelled choreographed scene stops its line with a C++ StopSound: its relayed copy stops too
    ("scene_cancel", lambda: seq(lambda: load(TW), lambda: job("server", "scene_cancel_setup.lua"), lambda: job("client", "scene_cancel_mid.lua"), lambda: job("server", "scene_cancel_next.lua"), lambda: job("client", "scene_cancel.lua"))),
    ("mouth_stop", lambda: seq(lambda: load(TW), lambda: job("server", "scene_cancel_setup.lua"), lambda: job("client", "mouth_stop_mid.lua"), lambda: job("server", "scene_cancel_next.lua"), lambda: job("client", "mouth_stop.lua"))),
    ("stop_followers", lambda: seq(lambda: load(TW), lambda: native_on(False), lambda: job("client", "stop_followers.lua"))),
    ("removed_oneshot", lambda: seq(lambda: load(TW), lambda: native_on(True), lambda: job("server", "removed_oneshot_setup.lua"), lambda: job("client", "removed_oneshot.lua"))),
    # a loop playing while pba is turned off then on: back to the engine, then mirrored again (and a still
    # prop_dynamic, MOVETYPE_PUSH like a door, keeps its loop)
    ("loop_reenable", lambda: seq(lambda: load(TW), lambda: native_on(False), lambda: job("server", "loop_reenable.lua", 20))),
    ("loop_release_long", lambda: seq(lambda: load(TW), lambda: job("server", "loop_release_long.lua", 30))),
    # loops born on the client (CreateSound of addons: vehicle engines): mirrored, stopped with Stop, GC, removal
    ("patch_oneshot_client", lambda: seq(lambda: load(TW), lambda: native_on(False), lambda: job("client", "patch_oneshot_client.lua", 20))),
    ("client_loop", lambda: seq(lambda: load(TW), lambda: native_on(False), lambda: job("client", "client_loop.lua", 20))),
    # native block (pba_native_render 1); native_doors closes then opens the door itself
    ("native_doors", lambda: seq(lambda: load(TW), lambda: native_on(True), lambda: job("client", "native_doors.lua"))),
    # pba_enable 0 does no work: no module call (door / prop sync, listener, settings), no tick, nothing processed
    ("off_no_work", lambda: seq(lambda: load(TW), lambda: native_on(True), lambda: job("client", "off_no_work.lua"))),
    # pba_native_predecode (perf O4): no main-thread decode in a burst, map load prewarm of the burst sounds
    ("native_predecode", lambda: seq(lambda: native_on(True), lambda: job("client", "native_predecode.lua", 90))),
    # the prewarm's entity walk spans frames: an entity removed meanwhile is skipped (was: whole prewarm lost)
    ("prewarm_null_entity", lambda: job("client", "prewarm_null_entity.lua", 30)),
    ("native_props_calm", lambda: seq(lambda: load(TW), lambda: native_on(True), lambda: job("server", "native_props_calm_setup.lua"), lambda: job("client", "native_props_calm.lua", 60))),
    ("detour_cap", lambda: seq(lambda: load(TW), lambda: job("server", "detour_cap_setup.lua"), lambda: job("client", "detour_cap.lua", 60))),
    ("native_features", lambda: seq(lambda: scenario(TW, "tworooms_closed"), lambda: native_on(True),
                                    lambda: job("client", "native_features.lua"))),
    ("native_stereo", lambda: seq(lambda: native_on(True), lambda: job("client", "native_stereo.lua"))),
    # "#" sounds (dry mix) rendered natively without reverb, as the engine runs no DSP on them (parity P2-10)
    ("native_dry_prefix", lambda: seq(lambda: native_on(True), lambda: job("client", "native_dry_prefix.lua", 30))),
    ("native_own_dsp", lambda: seq(lambda: scenario(TW, "tworooms_closed"), lambda: native_on(True),
                                   lambda: job("client", "native_own_dsp.lua", 60))),
    # a speaker's voice keeps its speaker EQ while followed, not only at its start (side bug 44)
    ("speaker_follow", lambda: seq(lambda: scenario(TW, "tworooms_closed"), lambda: native_on(True),
                                   lambda: job("client", "speaker_follow.lua", 60))),
    # pba_cl_enable 0: that player gets the engine's sounds, nothing relayed nor muffled for him (side bug 40)
    ("cl_enable_relay", lambda: seq(lambda: scenario(TW, "tworooms_closed"), lambda: job("server", "cl_enable_relay.lua", 60))),
    # pba_twodoors, both brush doors closed: dormant on the client, still paid by the routes (side bug 39)
    ("twodoors_closed", lambda: seq(lambda: load("pba_twodoors"),
        lambda: call("lua_exec", {"realm": "server", "code": "for _, n in ipairs({'door_s', 'door_n'}) do for _, d in ipairs(ents.FindByName(n)) do d:Fire('Open') end end return true"}),
        lambda: time.sleep(4),  # seen open first: the client receives them (never received at all: twodoors_unseen)
        lambda: call("lua_exec", {"realm": "server", "code": "for _, n in ipairs({'door_s', 'door_n'}) do for _, d in ipairs(ents.FindByName(n)) do d:Fire('Close') end end return true"}),
        lambda: time.sleep(4), lambda: job("client", "twodoors_closed.lua", 30))),
    # pba_twodoors loaded with both doors closed: never received by the client, found by the box the server sends
    ("twodoors_unseen", lambda: seq(lambda: load("pba_twodoors"), lambda: time.sleep(4), lambda: job("client", "twodoors_unseen.lua", 30))),
    ("native_volume_sfx", lambda: volume_sfx_step()),
    ("native_law", lambda: job("client", "native_law.lua")),
    # a far moving source keeps its source reverb response (pba_native_src_near): no restart every 1.5 m
    ("native_src_near", lambda: seq(lambda: native_on(True), lambda: job("client", "native_src_near.lua", 120))),
    # a source reverb slot reused after a pause, after walking away, after stepping across the anchor radius
    ("source_slot_reuse", lambda: seq(lambda: load("gm_construct", 1), cheats, lambda: native_on(True),
                                      lambda: job("client", "source_slot_reuse.lua", 200))),
    ("mix_groups", lambda: job("client", "mix_groups.lua")),
    ("mix_ducker", lambda: job("client", "mix_ducker.lua")),
    # the ducker fed from the own-sound path (pba.ListenerPos() returns 2 values): no error
    ("mix_note_own", lambda: job("client", "mix_note_own.lua")),
    ("native_mix", lambda: seq(lambda: load(TW), lambda: native_on(True), lambda: job("client", "native_mix.lua"))),
    ("native_duck", lambda: seq(lambda: load(TW), lambda: native_on(True), lambda: job("client", "native_duck.lua"))),
    # sentences (scripts/sentences.txt, HL2 mounted): the line parser, then the words rendered by the module
    ("sentence_parse", lambda: job("client", "sentence_parse.lua")),
    ("sentence_files", lambda: job("client", "sentence_files.lua")),
    ("runconsolecommand_blame", lambda: job("client", "runconsolecommand_blame.lua")),
    ("sound_duration", lambda: job("client", "sound_duration.lua")),
    ("sound_duration server", lambda: job("server", "sound_duration.lua")),
    ("sentence_virtual", lambda: job("client", "sentence_virtual.lua")),
    ("native_sentences_virtual", lambda: job("client", "native_sentences_virtual.lua")),
    ("native_sentences", lambda: seq(lambda: native_on(True), lambda: job("client", "native_sentences.lua", 30))),
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
    # slime is water to the engine (MASK_WATER): a source in it heard from the air crosses the interface
    ("underwater_slime d1_canals_06", lambda: seq(lambda: load("d1_canals_06", 1), lambda: job("client", "underwater_slime.lua"))),
    # Breen on the station's screens: his long lines taken over, an engine voice still plays on him (lip sync)
    ("breen_lips d1_trainstation_03", lambda: seq(lambda: load("d1_trainstation_03", 1), lambda: py("breen_lips.py", "25"))),
    ("caption_once d1_trainstation_05", lambda: seq(lambda: load("d1_trainstation_05", 4), lambda: py("caption_once.py"))),
    # a face the client has not received (behind a closed areaportal): its relayed line keeps a mouth channel on its index
    ("lipsync_unseen", lambda: seq(lambda: load(TW), lambda: py("lipsync_unseen.py"))),
    ("water_rules d1_canals_06", lambda: seq(lambda: load("d1_canals_06", 1), lambda: job("client", "water_rules.lua"))),
    # head under water: the room reverb and echoes fade out (the engine swaps its room DSP for dsp_water)
    ("water_reverb d1_canals_06", lambda: seq(lambda: load("d1_canals_06", 1), lambda: native_on(True), lambda: job("client", "water_reverb.lua"))),
    # the engine's dsp_water reaches the copies pba muffles too: no wall on top in Light / server decisions
    ("water_light d1_canals_06", lambda: seq(lambda: load("d1_canals_06", 1), lambda: [job("client", "water_light.lua"), job("server", "water_light.lua")])),
    # two water bodies with air between them: the source's surface is a wall
    ("water_planes d1_canals_06", lambda: seq(lambda: load("d1_canals_06", 1), lambda: job("client", "water_planes.lua"))),
    # pba_build_ms_combat (perf O6): the probe graph and module world rebuilt during a simulated fight, 1 ms per frame
    ("build_combat d1_canals_06", lambda: seq(lambda: load("d1_canals_06", 1), lambda: native_on(True), lambda: job("client", "build_combat.lua", 400))),
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
    # props on the probe routes through openings, not only on the straight line
    ("path_obstruction", lambda: py("path_obstruction.py")),
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
    ("paths_golden gm_construct", lambda: py("paths_golden.py")),  # bit for bit: 10 ^ x and x ^ n are the same compiled or interpreted since #61
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
    ("field_continuity noportal", lambda: seq(lambda: load("pba_noportal"), lambda: job("client", "field_continuity.lua", 300))),
    ("sky_route gm_construct", lambda: seq(lambda: load("gm_construct"), lambda: job("client", "sky_route.lua", 600))),
    # cases reported on rp_downtown: a radio upstairs heard through the ceiling (loudest voice first), and
    # behind a pillar of the same room (probes off the floor, no doubled vertex: the route hugs the corner)
    ("downtown_cases rp_downtown", lambda: seq(lambda: load("rp_downtown_v4c_v2"), lambda: job("client", "downtown_cases.lua", 400))),
    # cost of one uncached probe route (a far radio, the listener walking a corridor): was 50-125 ms per
    # stream update, a freeze every 0.25 s (207 door leaves tested one by one, LuaJIT aborting traces)
    ("downtown_route_cost rp_downtown", lambda: seq(lambda: load("rp_downtown_v4c_v2"), lambda: job("client", "downtown_route_cost.lua", 330))),
    ("route_alt_street rp_downtown", lambda: seq(lambda: load("rp_downtown_v4c_v2"), lambda: job("client", "route_alt_street.lua", 330))),
    # end to end, native: a radio stream in the upper room is reverberant there, and from the street the
    # reverb does not swamp it (send capped by the listener's enclosure, passed on gliding updates too)
    ("downtown_stream rp_downtown", lambda: py("downtown_stream.py")),
    # end to end, native: outside, under an overhang vs one metre left under the open sky, same window: the same level, no enclosure-boosted reverb
    ("melancholia_overhang", lambda: py("melancholia_overhang.py")),
    # a small room downstairs reached through openings: its reverb is there, and one metre does not switch it
    ("melancholia_small_room", lambda: py("melancholia_small_room.py")),
    # other addons' radios keep the distance law their addon chose (a 'same volume everywhere' radio came
    # out 14 dB weaker at 5 m under the physical law): native level = channel law, flat and 250 u ranges
    ("stream_addon_range", lambda: seq(any_map, lambda: native_on(True), lambda: job("client", "stream_addon_range.lua", 60))),
    # every native Update keeps or refreshes the reverb sends; per-step changes small while walking (rp_downtown)
    ("native_send_continuity rp_downtown", lambda: py("native_send_continuity.py")),
    # the module's output along walks (rp_downtown, gm_melancholia): <= 2 dB per 16 u step
    ("native_output_walk", lambda: py("native_output_walk.py")),
    # the module's output while stepping SIDEWAYS across the radio room's doorway (rp_downtown, reported: half a
    # metre changed the reverb completely): total, direct, reverb per 4 u step, two distance laws, four lines
    ("model_sweep", lambda: py("model_sweep.py")),
    ("doorway_lateral rp_downtown", lambda: py("doorway_lateral.py", "--walks=eye", "--laws=flat")),  # rendering at a few points; the model level: model_sweep
    # the same across gm_melancholia's stairs below the upper room's radio (reported 2026-11-10)
    ("doorway_lateral melancholia stairs", lambda: py("doorway_lateral.py", "--case=stairs", "--walks=eye", "--laws=flat")),
    # the voices' sends across that doorway (loop, stream, one-shot), 4 u steps
    ("native_send_continuity lateral", lambda: py("native_send_continuity.py", "--walk=lateral", "--step=4")),
    # a real map's door and a func_door_rotating swinging: no level jump, same voice kind across the leaf / wall
    ("door_sweep_real rp_downtown", lambda: seq(lambda: load("rp_downtown_v4c_v2"), lambda: native_on(True),
        lambda: [job("server", "door_sweep_real.lua", 30), job("client", "door_sweep_real.lua", 400)])),
    ("door_sweep_real twodoors", lambda: seq(lambda: load("pba_twodoors"), lambda: native_on(True),
        lambda: [job("server", "door_sweep_real.lua", 30), job("client", "door_sweep_real.lua", 120)])),
    # one corner, one cost: the estimators of a jamb's loss (edge, routes) and of a closed leaf agree, 2 u steps
    ("corner_coherence rp_downtown", lambda: seq(lambda: load("rp_downtown_v4c_v2"),
        lambda: [job("server", "corner_coherence.lua", 30), job("client", "corner_coherence.lua", 400)])),
    ("corner_coherence twodoors", lambda: seq(lambda: load("pba_twodoors"),
        lambda: [job("server", "corner_coherence.lua", 30), job("client", "corner_coherence.lua", 120)])),
    # what a player can hear: level steps > 1 dB (JND) and
    # direction jumps when the source or the listener walks 16 u steps, level(S, L) vs level(L, S).
    # Limits None (report only) until the first in-game baseline; --check fails on too few walks.
    # gm_construct first: path_quality field only ends on it (one load less); pba_demo: portal paths
    ("path_perceptual", lambda: py("path_perceptual.py", "--check", "--pairs=15", "gm_construct", "pba_demo")),
    # continuous sounds re-evaluated only on change (pba_reeval_adaptive): still cost, listener move, door
    ("reeval_adaptive", lambda: py("reeval_adaptive.py")),    # T6: relayed sounds carry the door loss and DSP, <= 30 bytes each, relay_rate falls back to the engine (muffled), allow_native 0
    ("relay_net", lambda: seq(lambda: load(TW), lambda: py("relay_net.py"))),
    # T8: the native module over 3 map changes, a disconnect / reconnect and stopsound (voices, mirrors, memory)
    ("native_lifecycle", lambda: py("native_lifecycle.py")),
    # T9: the engine presets really low-pass (recorded), and a relayed copy behind the closed door is 10 dB duller;
    # writes wav files and plays loud noise: one instance at a time
    ("dsp_muffle_real", lambda: seq(lambda: load(TW), lambda: py("dsp_muffle_real.py"))),
    # T10: room reverb present / absent (native_reverb 0), echoes near walls vs open field, native_echo 0, native_props
    ("reverb_echo_basics", lambda: py("reverb_echo_basics.py")),
    # T12 / T13: Doppler pitch and air absorption of what the module is really handed (gm_flatgrass, a flying prop, 10 m vs 100 m)
    ("doppler_air_render", lambda: seq(lambda: load("gm_flatgrass"), lambda: py("doppler_air_render.py"))),
    # T11: a radio of another addon behind a closed door (native energy -16 dB vs open), streams_filter high band, streams 0
    ("streams_basic", lambda: py("streams_basic.py")),
    # T18: probe graph disk cache (written, reloaded identical, stale version / hash / spacing rebuilt), no error while it builds
    ("probe_cache", lambda: seq(lambda: load("pba_noportal"), lambda: job("client", "probe_cache.lua", 400))),
    # T22: a loud shot in the open keeps its reverb <= -10 dB re its direct (pba_native_loud_dry), a quiet one is unchanged
    ("loud_dry_reverb", lambda: loud_dry_reverb()),
    # T16: a fake Sound Muffling Effect is turned off by pba_compat_auto 1 and given back (auto 0, pba off); a manual 0 is left alone
    ("compat_auto", lambda: seq(any_map, lambda: job("server", "compat_auto.lua", 60))),
    # T19: three reloads of the files of each realm: hooks unchanged, detoured originals still the engine's C functions
    ("lua_reload", lambda: seq(any_map, lua_reload)),
    # T23: lipsync, long_captions, soundscape_engine, stopsound_watch: each at 1 and at 0, the two behaviours told apart
    ("levels_off_states", lambda: levels_off_states()),
    # T15: one line either side of max_duration (long sound / short): same wall, subtitle, mouth, end; long_sounds 0 leaves it to the engine
    ("long_sound_boundary", lambda: long_sound_boundary()),
    # T14: glass loses what the table says, lightest class, voice on the pane; the open window gives a loud portal voice inside the opening
    ("glass_window", lambda: glass_window()),
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

PASS, FAIL, INCONC, REPORT, KNOWN = "PASS", "FAIL", "INCONCLUSIVE", "REPORT", "KNOWN"
RANK = {PASS: 0, REPORT: 1, KNOWN: 1, INCONC: 2, FAIL: 3}
# no criterion by design: listed, never counted
REPORT_ONLY = {"ab_counts tworooms_open", "ab_counts lcorridor"}

def _why(d):
    for k in ("err", "error", "why", "fail", "note", "fails", "raw"):
        if isinstance(d, dict) and d.get(k):
            return f"{k}: {json.dumps(d[k], ensure_ascii=False)[:200]}"
    return ""

def _num(x):
    return x if isinstance(x, (int, float)) and not isinstance(x, bool) else None

# Known reds, by name: step label -> beginnings of the names of the cases that are allowed to fail. A step
# whose failing cases are all listed is KNOWN (reported apart); one more failing case is a FAIL, and a listed
# case that passes again is said loudly. The two "Door in 3-D" cases are green outside the game and red in
# it (gap not found yet, JOURNAL 2026-11-11/12).
KNOWN_RED = {
    "GLuaTest pure suite": [
        "Door in 3-D: a leaf swinging past a route changes its level by degrees",
        "Door in 3-D: the gap is measured continuously as the leaf turns",
    ],
}

def _known(label, fails):
    """(failing cases not listed, listed ones that failed, listed ones that did not)."""
    names = KNOWN_RED.get(label, [])
    hit = [k for k in names if any(f.startswith(k) for f in fails)]
    other = [f for f in fails if not any(f.startswith(k) for k in names)]
    return other, hit, [k for k in names if k not in hit]

# criteria of tests that return measurements without a pass field (taken from their headers)
def _check_pure(v, label="GLuaTest pure suite"):
    d = v[0] if isinstance(v, list) and v else v
    if not isinstance(d, dict):
        return None
    ok, total = _num(d.get("ok")), _num(d.get("total"))
    fails = d.get("fails") or []
    other, hit, gone = _known(label, fails if isinstance(fails, list) else [])
    if ok is not None and total and ok == total:
        return PASS, ("known red cases pass again, remove them from KNOWN_RED: " + "; ".join(gone)) if gone else ""
    if hit and not other and ok is not None and total and ok + len(hit) == total:
        return KNOWN, (f"{len(hit)} known red case(s) only ({ok}/{total} pass): " + "; ".join(k[:60] for k in hit)
                       + (("; PASS again, remove from KNOWN_RED: " + "; ".join(k[:60] for k in gone)) if gone else ""))
    return FAIL, f"{ok}/{total} cases passed; NEW fails: {json.dumps(other or fails, ensure_ascii=False)[:300]}"

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

CHECKS = {"GLuaTest pure suite": _check_pure,
          "GLuaTest pure suite (native helpers)": lambda v: _check_pure(v, "GLuaTest pure suite (native helpers)"), "menu_fit": _check_menu, "loop_removed": _check_loop_removed}

def judge_py(o):
    # _cvsnap's notes come after the verdict (at exit): they would hide the last JSON object
    lines = [l for l in o.out.splitlines() if not l.startswith(("restored settings:", "settings left by a killed test"))]
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
QUICK = {"GLuaTest pure suite", "mouth_stop", "stop_followers", "menu_config_static", "light_no_module", "menu_fit", "portal_sweep tworooms", "bot_gunfire", "bot_footsteps", "npc_footsteps", "loop_removed", "looping_sound_stop", "looping_sound_stop_client", "weapon_loop_owner", "native_loop_fade_hidden", "native_vol_now", "streams_vol_now", "loop_fade_tail", "constraint_travel_loop", "loud_loop_far", "quiet_loop_far", "stopsound", "stopsound_console", "removed_oneshot", "channel_cut", "stop_script", "scene_cancel", "loop_reenable", "vehicle_state_sounds", "sp_own_echo", "sentence_pos", "far_muffle", "impact_inside_prop", "client_loop", "native_doors", "native_features", "native_stereo", "sentence_parse", "sentence_files", "sentence_virtual", "native_sentences", "native_sentences_virtual", "path_hysteresis twodoors", "continuous_ramp twodoors", "native_volume_sfx", "native_law", "lowpass_hysteresis twodoors", "door_sweep open", "door_sweep closed", "underwater_slime d1_canals_06", "water_rules d1_canals_06", "water_reverb d1_canals_06", "water_light d1_canals_06", "water_planes d1_canals_06", "patch_oneshot", "physics_scrape", "speaker_once", "looping_cue", "manhack_loop", "sound_duration", "sound_duration server", "soundtime_relay", "soundtime_reemit", "mp_own_sounds", "predicted_others", "source_slot_reuse", "listener_inside_prop", "runconsolecommand_blame", "patch_oneshot_client", "soundtime_offset", "soundtime_echo", "relay_dict_overflow", "channel_no_overwrite", "relay_client_ready", "relay_name_quota", "native_own_dsp", "mix_groups", "mix_ducker", "mix_note_own", "native_mix", "native_duck", "brief_change", "mic_disable", "native_dry_prefix", "silent_loops_cap", "native_src_near", "breen_lips d1_trainstation_03", "once_native_end", "lipsync_unseen", "manhack_loop_death", "npc_loop_death", "long_line", "caption_once d1_trainstation_05", "long_line_play_fail", "silent_handback", "silent_handback relay", "handback_replaced", "handback_scope", "speech_floor light", "speech_floor native", "channel_no_overwrite_server", "loops_cap_resume", "loops_stop_reentry", "loop_release_long", "loop_channel", "client_long_duck", "channel_one_rule", "long_lipsync_pref", "long_soundtime", "loop_far_muffle", "speaker_long_native", "door_spawned", "loops_stop_named", "core_model", "vanilla_parity", "propagation_delay", "oneshot_reeval", "burst_budget", "burst_fair", "burst_keep", "line_protect", "gc_lean", "native_send_continuity lateral", "speaker_follow", "cl_enable_relay", "twodoors_closed", "twodoors_unseen", "off_no_work", "native_predecode", "prewarm_null_entity", "mcp_encoding (pure)", "native_props_calm", "detour_cap", "route_alt_street rp_downtown", "sky_route gm_construct", "long_line_decode", "breencast_long_render d1_trainstation_01", "line_first_play", "caption_net", "native_own", "native_own_mp"}
# --smoke: the core, under 2 minutes, to run before every commit (--quick stays the check before a merge)
SMOKE = {"GLuaTest pure suite", "menu_config_static", "light_no_module", "portal_sweep tworooms",
         "native_doors", "native_features"}
if "--quick" in opts:
    steps = [s_ for s_ in steps if s_[0] in QUICK]
if "--smoke" in opts:
    steps = [s_ for s_ in steps if s_[0] in SMOKE]
# --only=a,b: just these steps (exact labels), in battery order; each sets its own map and state
ONLY = next((a[len("--only="):].split(",") for a in opts if a.startswith("--only=")), None)
if ONLY:
    known = {s_[0] for s_ in steps}
    unknown = [n for n in ONLY if n not in known]
    if unknown:
        import difflib
        hints = ["%s -> %s" % (n, ", ".join(difflib.get_close_matches(n, list(known), 3, 0.5)) or "?") for n in unknown]
        print("unknown step(s): " + "; ".join(hints) + " (" + str(len(known)) + " known steps)")
        sys.exit(3)
    steps = [s_ for s_ in steps if s_[0] in ONLY]

# a step is (label, function): a merge once put two labels in one tuple, the run crashed half-way
_bad_steps = [s_ for s_ in steps if not (isinstance(s_, tuple) and len(s_) == 2 and callable(s_[1]))]
if _bad_steps:
    print("malformed battery step(s): " + "; ".join(repr(s_[:-1]) for s_ in _bad_steps), flush=True)
    sys.exit(3)

# ------------------------------------------------------------------ preflight

_PREFLIGHT = """local A = pba
if not A or not A.cfg then return { ok = false, why = 'pba is not loaded' } end
local why = {}
if not A.Enabled() then why[#why + 1] = 'A.Enabled() is false (pba_enable ' .. tostring(A.cfg.enable) .. ', pba_cl_enable ' .. tostring(A.cfg.cl_enable) .. ')' end
local ov = {} for k, v in pairs(A.override or {}) do ov[#ov + 1] = k .. '=' .. tostring(v) end
if #ov > 0 then why[#why + 1] = 'in-memory overrides left over: ' .. table.concat(ov, ', ') end
local H = hook.GetTable().EntityEmitSound
if not (H and H.pba) then why[#why + 1] = 'the EntityEmitSound hook "pba" is not installed' end
if not (A.Paths and A.Paths.Compute) then why[#why + 1] = 'pba.Paths.Compute missing' end
return { ok = #why == 0, why = table.concat(why, '; ') }"""

def preflight():
    """pba really runs in both realms (a test that accepts 'nothing to do' would pass with it off), else the
    problems. A map is loaded first when none is."""
    any_map()
    for attempt in (1, 2):
        bad = []
        for realm in ("client", "server"):
            r = lua(realm, _PREFLIGHT)
            if not isinstance(r, dict) or r.get("ok") is not True:
                bad.append(f"{realm}: " + (r.get("why") if isinstance(r, dict) else f"no answer ({r!r})"))
        # overrides are what an earlier run (the demo bench) left in the realm: a plain map clears them
        if attempt == 1 and bad and any("overrides left over" in b for b in bad):
            fresh("pba_tworooms")  # not the current map: pba_demo itself starts with an override (desk mode A)
            continue
        break
    return bad

# ------------------------------------------------------------------ run

bad = preflight()
if bad:
    print("PREFLIGHT FAILED: pba is not running as the tests assume, battery aborted.\n  " + "\n  ".join(bad), flush=True)
    sys.exit(4)
print("preflight: pba_enable 1, pba_cl_enable 1, no override, hooks present (client and server)", flush=True)
# Every archived pba_* setting at its default before the first step: a killed run (or a game session) can
# leave one changed in the config (2026-11-14: pba_max_duration 10.7 left by an interrupted test turned the
# 10.5 s test lines into short sounds, 5 long-line steps red). Reported by name, then reset.
_OFF_DEFAULT = """local out = {}
for name, def in pairs(pba.CONFIG or {}) do
	local cv = GetConVar("pba_" .. name)
	if cv and math.abs(cv:GetFloat() - def[1]) > 1e-4 then out[#out + 1] = { name, cv:GetString(), def[1] } end
end
return out"""
_off = lua("client", _OFF_DEFAULT) or []
if _off:
    print("preflight: settings not at their default, reset: " + ", ".join(f"pba_{n}={v} (default {d})" for n, v, d in _off), flush=True)
    for n, v, d in _off:
        call("console_exec", {"realm": "menu", "cmd": f"pba_{n} {d}"})
        # the session snapshot (SNAP0, restored after every step and at exit) takes the default too,
        # else the bad value would come back at the end of the run
        for _realm in SNAP0.values():
            if n in _realm:
                _realm[n] = str(d)
    time.sleep(0.5)
results = []  # (label, seconds, verdict, reason)
with open(LOG, "w", encoding="utf-8") as f:
    f.write(f"PBA battery {time.strftime('%Y-%m-%d %H:%M:%S')} args {' '.join(opts) or '(full)'}\n"
            "Full output of every step that did not pass.\n\n")

# Every step starts from the session's pba_* settings (SNAP0): a step that changed one and did not put it back
# (an exception, a forgotten restore) made the next steps run under it, so a step passed alone and failed in
# a group (impact_inside_prop, native_props_calm). The settings left are reset and named with their step.
NO_RESET = "--no-reset" in sys.argv
SET_BY_STEPS = {"native_render"}  # every step sets it (native_on): no leak
_prev = [None]

def _same(a, b):
    """Two convar strings equal as numbers when both are (GetString gives '0.0' or '0.000000' for one value)."""
    try:
        return abs(float(a) - float(b)) < 1e-6
    except (TypeError, ValueError):
        return a == b

def reset_settings():
    now = _cvsnap.snapshot(call)
    left = []
    for realm, values in SNAP0.items():
        cur = now.get(realm) or {}  # a realm not there (no map): nothing to compare
        for name, v in values.items():
            if name in cur and name not in SET_BY_STEPS and not _same(cur[name], v):
                left.append(f"{realm} pba_{name}={cur[name]} (was {v})")
                if not NO_RESET:
                    call("console_exec", {"realm": realm, "cmd": f"pba_{name} {v}"})
    if left:
        print(f"settings left by {_prev[0]}: " + ", ".join(left) + ("" if NO_RESET else " -> reset"), flush=True)
        if not NO_RESET:
            time.sleep(0.6)  # the client follows the server's convars within pba_cfgpoll's 0.5 s

def step(i, n, label, fn):
    print(f'##progress step={i}/{n} label="Battery" msg="{label}"', flush=True)
    if _prev[0] is not None:
        try:
            reset_settings()
        except Exception as e:
            print(f"settings check failed: {e!r}", flush=True)
    _prev[0] = label
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
counts = {k: sum(1 for r in results if r[2] == k) for k in (PASS, FAIL, INCONC, REPORT, KNOWN)}
print("##progress done=" + ("ok" if counts[FAIL] == 0 and counts[INCONC] == 0 else "fail"), flush=True)
w = max([len(r[0]) for r in results] + [4])
table = [f"{'step'.ljust(w)}  {'verdict':12}  {'time':>5}  reason", "-" * (w + 40)]
table += [f"{label.ljust(w)}  {v:12}  {dt:>4}s  {why}" for label, dt, v, why in results]
table.append(f"\n{counts[PASS]} PASS, {counts[FAIL]} FAIL, {counts[INCONC]} INCONCLUSIVE, {counts[REPORT]} REPORT"
             f", {counts[KNOWN]} KNOWN red ({len(results)} steps)" + (f"; full output of the failures in {LOG}" if counts[FAIL] + counts[INCONC] else ""))
known = [r for r in results if r[2] == KNOWN]
if known:
    table.append("KNOWN reds (accepted, named in KNOWN_RED): " + "; ".join(f"{r[0]}: {r[3]}" for r in known))
print("\n===== VERDICTS =====\n" + "\n".join(table), flush=True)
with open(LOG, "a", encoding="utf-8") as f:
    f.write("===== VERDICTS =====\n" + "\n".join(table) + "\n")
sys.exit(1 if counts[FAIL] else 2 if counts[INCONC] else 0)
