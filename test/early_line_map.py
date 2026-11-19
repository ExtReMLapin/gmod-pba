"""The real case of pba_early_line_takeover: a fresh load of d1_trainstation_05 (singleplayer). Alyx's first line
(vo/trainyard/al_thisday.wav, 2.67 s, CHAN_VOICE, from a scene) is emitted about 1.25 s after the player spawns,
before his pba client runs (measured: its Lua loaded 0.04 s after the line, native rendering 0.5 s later still).
Before the fix nothing of pba ever saw it: the engine played it whole (no pba rendering of its file at all).
Pass: once the client is settled, the module plays the rest of the line (A.earlyLast names its file, offset
> 0.3 s: from the middle, not its top), pba rendered it (A.renderedT has its file), the engine's copy is muted
(snd_dumpclientsounds: vol 0 where it still plays), with no Lua error. A client whose module renders so late that it
asks inside the line's last 0.75 s passes only as "refused_late" (kept and sent by the server, refused by the
hand-over margin, with the elapsed time to show it); the take itself is measured by early_line.py.
Needs native rendering (the module) and pba_native_render 1. Leaves the game on d1_trainstation_05, maxplayers 1.
Usage: python -I test/early_line_map.py <mcp.py> [--off | --control]   (--control: pba_early_line_takeover 0, pass = the bug shows)"""
import json, os, re, subprocess, sys, time
MCP = [a for a in sys.argv[1:] if not a.startswith("--")][0]
FILE = "vo/trainyard/al_thisday.wav"


def call(tool, a, timeout=400):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(a), "200000"],
                         capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout).stdout
    try:
        return json.loads(out)
    except ValueError:
        return {}


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _cvsnap
_cvsnap.guard(call)

if lua("client", "return pba_native ~= nil and (pba.cfg.native_render or 0) >= 0.5") is False:
    print(json.dumps({"pass": False, "err": "needs the native module and pba_native_render 1"}))
    sys.exit(1)
CONTROL = "--control" in sys.argv  # the battery's control: --off, and pass = the bug shows
if "--off" in sys.argv or CONTROL:  # the control: pba_early_line_takeover 0 must fail (the engine keeps the whole line)
    call("console_exec", {"realm": "server", "cmd": "pba_early_line_takeover 0"})
# the module starts a second after the map's InitPostEntity and gathers the world at 4 ms a frame: on a light test
# client (20 fps) its rendering came 1.8 s after the line, a hair before the line's last 0.75 s. The frame cap is
# raised for the load (the user's game at 60+ fps: rendering 0.5 s after the line), and put back after.
fps0 = lua("client", "return GetConVar('fps_max'):GetString()")
call("console_exec", {"realm": "client", "cmd": "fps_max 60"})
r = call("map_load", {"map": "d1_trainstation_05", "maxplayers": 1, "timeout_s": 300})
if r.get("map") != "d1_trainstation_05":
    print(json.dumps({"pass": False, "err": "map load failed", "r": r}))
    sys.exit(1)
res = {}
t0 = time.time()
while time.time() - t0 < 12:
    res = lua("client", """local A = pba local k = "%s"
return { last = A.earlyLast, try = A.earlyTry, rendered = A.renderedT and A.renderedT[k] ~= nil, taken = A.stats.earlyTaken,
  render = A.Native and A.Native.render, stats = { noTake = A.stats.early_clear, ended = A.stats.early_ended,
  dropStart = A.stats.earlyDrop_ended } }""" % FILE) or {}
    if res.get("rendered") and res.get("last"):
        # the engine's copy right after the hand-over: muted (vol 0) where it still plays, never at its volume
        d = call("console_exec", {"realm": "client", "cmd": "snd_dumpclientsounds", "regex": "al_thisday", "wait_frames": 1})
        res["engineVols"] = [int(m.group(1)) for m in (re.search(r"vol\((\d+)\)", ln.get("text", "")) for ln in d.get("output", [])) if m]
        break
    if (res.get("try") or {}).get("why") not in (None, "taken"):
        break
    time.sleep(0.2)
if fps0:
    call("console_exec", {"realm": "client", "cmd": "fps_max " + fps0})
res["server"] = lua("server", "return { noted = pba.stats.earlyNoted, sent = pba.stats.earlySent }")
errs = [e.get("message") for e in call("errors_since", {"since_map_load": True}).get("errors", [])
        if "pba" in json.dumps(e)]
last = res.get("last") or {}
taken = bool(res.get("rendered")) and last.get("name", "").lower().replace("\\", "/").lstrip("*#@<>^)}$!?&~`+%") == FILE \
    and (last.get("offset") or 0) > 0.3 and all(v == 0 for v in res.get("engineVols", []))
# a slow client (a 20 fps test client while others load: its module renders 1.8-2 s after the line) asks for it
# inside the line's last 0.75 s: refused by the hand-over rule, which is right. Accepted only with its numbers: the
# server kept and sent it, and the client's verdict was "ended" at an elapsed time past that margin.
try_ = res.get("try") or {}
late = try_.get("why") == "ended" and (try_.get("elapsed") or 0) > 2.67 - 0.75 - 0.02 \
    and (res.get("server") or {}).get("sent") == 1
res["outcome"] = "taken" if taken else ("refused_late" if late else "missed")
ok = (taken or late) and not errs
if CONTROL:  # the old behaviour: nothing of pba rendered the line, nothing taken
    ok = not res.get("rendered") and not res.get("taken") and not errs
res.update({"pass": ok, "control": CONTROL, "pbaErrors": errs})
print(json.dumps(res))
sys.exit(0 if ok else 1)
