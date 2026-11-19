"""A followed loop entering a player's range starts at once at its full level (user, 2026-11-19, gm_converted_apartment:
"the audio jumps", standing still). The map's five cars (func_tracktrain, machinery/diesel_engine_medium_loop.wav at
75 dB) drive round the block 1100-3000 u from the flat; the server subscribes a player to a followed loop within its
audible radius (sv_loops, A.AudibleRadius: 2500 u at 75 dB, left beyond 110 %), so every car entering it was a new
module voice at its whole level: the output stepped +12..+25 dB within 10-30 ms at each join (most of it the car's
source reverb slot), every few seconds. With the module's 1/r law the radius is no edge of audibility (-33.6 dB clear
at 2500 u, -19.6 at 500 u). pba_loops_edge_fade: a loop that a player joins midway fades in over that many seconds
instead.

Rendering level, one client: on gm_converted_apartment (the cars removed), an emitter playing the cars' loop drives
down their street (x 1056, 850 u/s like them) from out of range into it, the listener standing in the street ahead
(in clear sight: at the user's place, inside, the level 1-2 s after the join depends on how the moving source's
reverb slot is simulated, from -48 to -78 dB between two runs, which says nothing of the join). The module's output is
captured, the voice's Play / StopVoice timed and its slot feed (SourceReflect's srcSend) logged.
  join_frac   the output's largest 10 ms RMS in the 50 ms after the join's Play over its RMS 1-2 s after it
              (an instant start: >= 0.5; a fade over 1 s: <= 0.1)
  slot_feed_frac  the voice's first source reverb slot feed over its largest (instant start: 1; faded: ~0.001)
Two drives: without updates (the join is the server's 0.5 s timer's) and with a pitch update every 0.2 s (as the
cars' SoundUpdate, every second: an update finds the player in range first, sv_loops LP.Handle).
Pass: join_frac <= MAX_JOIN_FRAC and slot_feed_frac <= MAX_FEED_FRAC in both. (A leave is not checked: at the
user's place the car's reverb tail hid the cut, 5.6-6.2 dB over 20-60 ms on main.) --control: pba_loops_edge_fade 0 for the run,
pass = the join jumps (both metrics over their bounds in both drives).
Usage: python -I -u test/range_edge_fade.py <mcp.py> [--control]"""
import json, os, struct, subprocess, sys, time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from _cvsnap import guard  # noqa: E402

MCP = [a for a in sys.argv[1:] if not a.startswith("--")][0]
CONTROL = "--control" in sys.argv
MAP = "gm_converted_apartment"
SND = "machinery/diesel_engine_medium_loop.wav"
EAR = [1056, 2000, -208]  # in the street, the emitter coming down it in clear sight (a steady 1/r level to compare with)
Y0, Y1, X, Z, SPEED = -2400, 1000, 1056, -128, 850
MAX_JOIN_FRAC = 0.25
MAX_FEED_FRAC = 0.1
UPDATES = [0, 0.2]
GMOD = r"D:\SteamLibrary\steamapps\common\GarrysMod\garrysmod"


def call(tool, a, timeout=900):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(a), "4000000"],
                         capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout).stdout
    try:
        return json.loads(out)
    except ValueError:
        return {"raw": out[:500]}


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


def read_wav(path):
    b = open(path, "rb").read()
    i, fmt = 12, None
    while i < len(b):
        cid, sz = b[i:i + 4], struct.unpack("<I", b[i + 4:i + 8])[0]
        if cid == b"fmt ":
            fmt = struct.unpack("<HHIIHH", b[i + 8:i + 24])
        if cid == b"data":
            raw = b[i + 8:i + 8 + sz]
            x = np.frombuffer(raw, dtype="<f4") if fmt[5] == 32 else np.frombuffer(raw, dtype="<i2") / 32768.0
            return x.reshape(-1, fmt[1]), fmt[2]
        i += 8 + sz + (sz & 1)
    raise ValueError("no data chunk")


def rms_windows(x, sr, win=0.01):
    n = int(sr * win)
    m = len(x) // n * n
    return np.sqrt((x[:m] ** 2).mean(1).reshape(-1, n).mean(1))


def window_rms(r, a, b, win=0.01):
    i, j = max(int(a / win), 0), max(int(b / win), int(a / win) + 1)
    return float(np.sqrt(np.mean(r[i:j] ** 2))) if j <= len(r) else None


def analyze(path, rows):
    x, sr = read_wav(path)
    r = rms_windows(x, sr)
    plays = [w["t"] for w in rows if w["f"] == "play"]
    stops = [w["t"] for w in rows if w["f"] == "stop"]
    out = {"plays": [round(t, 3) for t in plays], "stops": [round(t, 3) for t in stops]}
    if plays:
        t = plays[0]
        ref = window_rms(r, t + 1.0, t + 2.0)
        i0 = int(t / 0.01)
        first = float(r[i0:i0 + 6].max())
        out["join_frac"] = round(first / max(ref or 0, 1e-12), 3)
        out["join_ref_db"] = round(20 * np.log10(max(ref or 0, 1e-12)), 1)
    feeds = [w for w in rows if w["f"] == "slot" and w.get("send") is not None]
    if feeds:
        top = max(w["send"] for w in feeds)
        out["slot_feed_frac"] = round(feeds[0]["send"] / max(top, 1e-12), 4)
        out["slot_feed_ms_to_half"] = next((round((w["t"] - feeds[0]["t"]) * 1000) for w in feeds if w["send"] >= top / 2), None)
    return out


def main():
    if lua("client", "return game.GetMap()") != MAP:
        r = call("map_load", {"map": MAP, "maxplayers": 1, "timeout_s": 300})
        if r.get("map") != MAP:
            print(json.dumps({"pass": False, "err": "map load failed", "r": r}))
            return 1
        time.sleep(4)
    if not lua("client", "return pba ~= nil and pba.Native ~= nil and pba.Native.ready == true"):
        print(json.dumps({"pass": False, "err": "needs the native module"}))
        return 1
    if CONTROL:
        lua("client", "RunConsoleCommand('pba_loops_edge_fade', '0') return true")
    # the map's cars out of the way, the player at the reported place, an emitter out of range
    # the map's cars out of the way, the player at the reported place
    lua("server", """for _, e in ipairs(ents.FindByClass('func_tracktrain')) do e:Remove() end
local p = player.GetHumans()[1] p:SetPos(Vector(%d, %d, %d)) p:SetEyeAngles(Angle(0, 161, 0)) p:SetVelocity(-p:GetVelocity())
return true""" % tuple(EAR))
    cases = []
    for upd in UPDATES:
        m = run_case(upd)
        if m is None:
            return 1
        cases.append(m)
    fr = [c.get("join_frac") for c in cases]
    sf = [c.get("slot_feed_frac") for c in cases]
    jumped = all(f is not None and f > MAX_JOIN_FRAC for f in fr) and all(f is not None and f > MAX_FEED_FRAC for f in sf)
    ok = all(f is not None and f <= MAX_JOIN_FRAC for f in fr) and all(f is not None and f <= MAX_FEED_FRAC for f in sf)
    passed = jumped if CONTROL else ok
    print(json.dumps({"pass": passed, "control": CONTROL, "max_join_frac": MAX_JOIN_FRAC, "cases": cases}))
    return 0 if passed else 1


def run_case(upd):
    """One drive of the emitter (upd: seconds between its SND_CHANGE_PITCH updates, as a func_tracktrain's every
    second; 0 = none, so the join comes from the server's 0.5 s timer; with 0.2 s an update finds the player in range
    first). Returns the metrics, or None after printing the failure."""
    lua("server", """if IsValid(PBA_EDGE_EMITTER) then PBA_EDGE_EMITTER:Remove() end
local e = ents.Create('prop_dynamic') e:SetModel('models/props_c17/oildrum001.mdl') e:SetPos(Vector(%d, %d, %d))
e:Spawn() e:SetNotSolid(true) PBA_EDGE_EMITTER = e return true""" % (X, Y0, Z))
    time.sleep(2)
    secs = (Y1 - Y0) / SPEED
    dur = secs + 3
    code = open(os.path.join(HERE, "range_edge_fade.lua"), encoding="utf-8").read()
    job = call("lua_job", {"realm": "client", "code": code, "async": True,
                           "args": {"dur": dur, "name": SND, "cap": "range_edge_fade"}})
    jid = job.get("job_id")
    if not jid:
        print(json.dumps({"pass": False, "err": "client job did not start", "r": job}, default=str)[:1500])
        return None
    time.sleep(0.3)
    mv = call("lua_job", {"realm": "server", "timeout_s": 60, "code": """
local e = PBA_EDGE_EMITTER
e:EmitSound('%s', 75, 179, 0.7, CHAN_STATIC)
local t0, secs, upd, nextU = CurTime(), %f, %f, CurTime()
while CurTime() - t0 < secs do
	local f = (CurTime() - t0) / secs
	e:SetPos(Vector(%d, %d + f * %d, %d))
	if upd > 0 and CurTime() >= nextU + upd then nextU = CurTime() e:EmitSound('%s', 75, 179, 0.7, CHAN_STATIC, SND_CHANGE_PITCH) end
	job:frames(1)
end
job:sleep(1.5)
e:StopSound('%s')
job:sleep(0.3)
e:Remove()
return true""" % (SND, secs, upd, X, Y0, Y1 - Y0, Z, SND, SND)})
    res = call("lua_job_status", {"id": jid, "wait_s": dur + 30})
    vals = res.get("values")
    if not vals or not mv.get("values"):
        print(json.dumps({"pass": False, "err": "job failed", "client": res, "server": mv}, default=str)[:2000])
        return None
    data = json.loads(vals[0])
    m = analyze(os.path.join(GMOD, "data", "pba", "range_edge_fade.wav"), data["rows"])
    m["updates_s"] = upd
    return m


guard(call)
sys.exit(main())
