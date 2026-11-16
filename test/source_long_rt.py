"""Source reverb slots ring with the reverb time of THEIR OWN room (pba_native_source_long_rt, module feat/source-long-rt).

The module rendered an echo or source reverb slot's tail with the reverb times of its main simulation (window 0.5 s, saturating
near 1.2 s whatever the room); only the listener's room bus had the long-window estimate (pba_native_reverb_window, 2.5 s). With
the option each slot gets its own long-window estimate, simulated at its own position.

Three scenes, each measured with the option off then on (test/source_long_rt.lua, one client lua_job per scene):
  hall   pba_pipe (68 x 34 x 17 m steel hangar), a sound at the drop pad 8 m from the listener, the same room: the slot's tail,
         read from the module's FINAL output (pba_native.CaptureStart/Stop) and from the reverb times the slot used
         (pba_native.SlotReverbTimes), must ring like the room (mid band within +-35 % of the room's long estimate) with the
         option on, and under 2 s with it off (the main simulation's cap: this is the red line of the unfixed module).
  floor  the same hall, sounds lying ON the floor (a pipe on the pad): an estimate taken at the floor is meaningless (0.1 s high band,
         0.1 to 20 s mid), so the Lua side (N.ProbeLift, SourceReflect's argument 4) takes it ~1 m above the floor: the slot's reverb
         time must be the room's (+-35 %) and have no degenerate band.
  small  pba_tworooms, listener and sound in room A (512 x 512 x 192 u): option off keeps the main simulation's times; on, the slot
         rings like the room (+-20 % by the getter, +-35 % by the capture). (On and off differ there: the 0.5 s window estimate is
         0.49 s in this concrete room, 1.9 s for the room bus.)
  other  pba_demo, listener in the hangar, sound in the closet next door: the slot gets the CLOSET's reverb time (as measured
         with the listener standing in the closet, +-35 %), clearly not the hangar's (the listener's room, at least 1.5 x apart).
The RT of a capture: the burst's tail split in the module's three bands (0-800 Hz, 0.8-8 kHz, 8 kHz up, as Steam Audio's reverb
times), Schroeder backward integration from 0.7 s after the burst (past the 0.5 s convolved part, whose own decay is steeper than the parametric tail the option
changes), slope fitted between -5 and -25 dB, times 3 (T20 -> RT60).

Usage: python -I -X utf8 test/source_long_rt.py <mcp.py> [--only=hall,floor,small,other] [--gmod=<garrysmod dir>]
       python -I -X utf8 test/source_long_rt.py --selftest              (offline: the RT estimator on a synthetic decay)
MCP_INSTANCE=<id> targets one game. Native rendering is switched on for the run and the option restored.
"""
import json
import os
import struct
import subprocess
import sys
import time

import numpy as np
from scipy.signal import butter, sosfilt

HERE = os.path.dirname(os.path.abspath(__file__))
GMOD_DEFAULT = r"D:\SteamLibrary\steamapps\common\GarrysMod\garrysmod"
BANDS = [(0, 800), (800, 8000), (8000, 1e9)]
BAND_NAMES = ["low", "mid", "high"]


# ------------------------------------------------------------------ offline: RT of a recording

def read_wav(path):
    """(mono float array, rate) of a 16 / 24 / 32 bit PCM or 32 bit float WAV (the module's capture is float)."""
    b = open(path, "rb").read()
    assert b[:4] == b"RIFF" and b[8:12] == b"WAVE"
    pos, fmt, data = 12, None, None
    while pos + 8 <= len(b):
        tag, size = b[pos:pos + 4], struct.unpack("<I", b[pos + 4:pos + 8])[0]
        body = b[pos + 8:pos + 8 + size]
        if tag == b"fmt ":
            fmt = struct.unpack("<HHIIHH", body[:16])
        elif tag == b"data":
            data = body
        pos += 8 + size + (size & 1)
    code, ch, rate, _, _, bits = fmt
    if code == 3 and bits == 32:
        x = np.frombuffer(data, "<f4").astype(np.float64)
    elif code == 1 and bits == 16:
        x = np.frombuffer(data, "<i2").astype(np.float64) / 32768
    elif code == 1 and bits == 32:
        x = np.frombuffer(data, "<i4").astype(np.float64) / 2147483648
    else:
        raise ValueError(f"unsupported WAV format {code}/{bits}")
    n = len(x) // ch
    return x[:n * ch].reshape(n, ch).mean(axis=1), rate


def band_split(x, rate, lo, hi):
    """The band lo..hi (Hz) of x: 4th-order Butterworth (a brick-wall FFT mask rings: the burst's direct sound would leak into its tail)."""
    if lo <= 0:
        sos = butter(4, hi, "lowpass", fs=rate, output="sos")
    elif hi >= rate / 2 - 1:
        sos = butter(4, lo, "highpass", fs=rate, output="sos")
    else:
        sos = butter(4, [lo, hi], "bandpass", fs=rate, output="sos")
    return sosfilt(sos, x)


def rt60(e, rate, start, lo_db=-5.0, hi_db=-25.0):
    """RT60 (s) of an energy curve e (squared band signal): Schroeder backward integral from `start` (s), slope fitted between
    lo_db and hi_db of the integral (T20), times 3. None when the curve does not reach hi_db."""
    seg = e[int(start * rate):]
    edc = np.cumsum(seg[::-1])[::-1]
    if len(edc) < 10 or edc[0] <= 0:
        return None
    db = 10 * np.log10(np.maximum(edc / edc[0], 1e-30))
    t = np.arange(len(db)) / rate
    i0 = np.argmax(db <= lo_db) if np.any(db <= lo_db) else None
    i1 = np.argmax(db <= hi_db) if np.any(db <= hi_db) else None
    if i0 is None or i1 is None or i1 - i0 < 10:
        return None
    k = np.polyfit(t[i0:i1], db[i0:i1], 1)[0]  # dB per second (< 0)
    return -60.0 / k if k < 0 else None


def rt_bands(path, onset_pad=0.7):
    """RT60 per band of a capture holding one burst followed by its tail: {low, mid, high} (s or None)."""
    x, rate = read_wav(path)
    pk = np.max(np.abs(x))
    if pk <= 0:
        return {n: None for n in BAND_NAMES}
    onset = int(np.argmax(np.abs(x) > 0.05 * pk))
    x = x[onset:]
    out = {}
    for name, (lo, hi) in zip(BAND_NAMES, BANDS):
        out[name] = rt60(band_split(x, rate, lo, hi) ** 2, rate, onset_pad)
    return out


def selftest():
    rate = 48000
    rng = np.random.default_rng(1)
    ok = True
    for want in (0.5, 1.5, 5.0):
        n = int(rate * 10)
        t = np.arange(n) / rate
        x = rng.standard_normal(n) * 10 ** (-3.0 * t / want)  # -60 dB at t = want
        x[: int(0.02 * rate)] += 20 * rng.standard_normal(int(0.02 * rate))  # the burst
        import tempfile
        p = os.path.join(tempfile.gettempdir(), "pba_slotrt_selftest.wav")
        d = (x / np.max(np.abs(x))).astype("<f4")
        st = np.repeat(d, 2)
        hdr = b"RIFF" + struct.pack("<I", 36 + st.nbytes) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 3, 2, rate, rate * 8, 8, 32) + b"data" + struct.pack("<I", st.nbytes)
        open(p, "wb").write(hdr + st.tobytes())
        got = rt_bands(p)["mid"]
        good = got is not None and abs(got - want) / want < 0.15
        print(("PASS" if good else "FAIL"), f"RT of a synthetic decay: want {want}, got {got}")
        ok = ok and good
        os.remove(p)
    return ok


# ------------------------------------------------------------------ game driving

MCP = None
GMOD = GMOD_DEFAULT
RESULTS = {}
FAILS = []


def call(tool, args, mx=400000, timeout=600):
    a = json.dumps(args)
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, a, str(mx)], capture_output=True, text=True,
                         encoding="utf-8", errors="replace", timeout=timeout).stdout
    try:
        return json.loads(out)
    except ValueError:
        return {"raw": out}


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


def wait_lua(realm, code, timeout=15.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if lua(realm, code) is True:
            return True
        time.sleep(0.5)
    return False


def check(ok, what, detail=""):
    print(("PASS " if ok else "FAIL ") + what + (f" [{detail}]" if detail else ""))
    if not ok:
        FAILS.append(what)
    return ok


def load(m):
    st = call("status", {})
    if st.get("map") != m:
        call("map_load", {"map": m, "maxplayers": 1}, timeout=300)
        time.sleep(4)
    for _ in range(60):
        r = call("lua_exec", {"realm": "client", "code": "local N = pba.Native return N == nil or pba_native == nil or (not N.building and (N.ready == true or N.pba_demoHeld == true))"})
        if r.get("values") == [True]:
            break
        time.sleep(2)
    wait_lua("client", "return IsValid(LocalPlayer()) and LocalPlayer():Alive()", 10)


def native_on():
    call("console_exec", {"realm": "client", "cmd": "pba_native_render 1"})
    wait_lua("client", "local N = pba.Native return N ~= nil and N.ready == true and N.render == true", 20)
    time.sleep(1)


def teleport(x, y, z, yaw=0):
    lua("server", f"local p = player.GetHumans()[1] if IsValid(p) then p:SetPos(Vector({x}, {y}, {z})) p:SetEyeAngles(Angle(0, {yaw}, 0)) end return true")
    wait_lua("client", f"return LocalPlayer():GetPos():Distance(Vector({x}, {y}, {z})) < 2", 5)
    time.sleep(0.5)


def measure(src, name, capture, seconds=10, settle=3, opts=(0, 1)):
    pre = "SLR = {src = Vector(%g, %g, %g), name = %s, capture = %s, seconds = %g, settle = %g, opts = {%s}}\n" % (
        src[0], src[1], src[2], json.dumps(name), "true" if capture else "false", seconds, settle, ", ".join(str(o) for o in opts))
    code = pre + open(os.path.join(HERE, "source_long_rt.lua"), encoding="utf-8").read()
    t = 120 + seconds * len(opts)
    r = call("lua_job", {"realm": "client", "code": code, "timeout_s": t}, timeout=t + 60)
    v = r.get("values", [r])[0] if isinstance(r, dict) else r
    if isinstance(v, dict):
        for o in v.get("opts", []):
            cap = o.get("capture") or {}
            if cap.get("path"):
                p = cap["path"]
                if not os.path.exists(p):
                    p = os.path.join(GMOD, "data", "pba", os.path.basename(p))
                o["capRt"] = rt_bands(p)
    return v


def mid(rt):
    if isinstance(rt, list) and len(rt) >= 2:
        return rt[1]
    return rt.get("mid") if isinstance(rt, dict) else None


def within(a, b, tol):
    return a is not None and b is not None and b > 0 and abs(a - b) <= tol * b


def fmt(rt):
    if isinstance(rt, dict):
        return "/".join("-" if rt.get(n) is None else f"{rt[n]:.2f}" for n in BAND_NAMES)
    if isinstance(rt, list):
        return "/".join(f"{x:.2f}" for x in rt)
    return "-"


def report(tag, m):
    for o in m.get("opts", []):
        print(f"  {tag} option {o['opt']}: slot rt {fmt(o.get('rt'))} (main sim {fmt(o.get('mainRt'))}, long {o.get('long')}, n {o.get('n')}) "
              f"room {fmt(o.get('room'))} capture rt {fmt(o.get('capRt'))} stats {o.get('stats')}")


def scene_hall():
    load("pba_pipe")
    native_on()
    pm = lua("client", "return pba.PipeMap and {pba.PipeMap.listener.x, pba.PipeMap.listener.y, pba.PipeMap.listener.z, pba.PipeMap.pad.x, pba.PipeMap.pad.y, pba.PipeMap.pad.z}")
    lx, ly, lz, px, py_, pz = pm
    teleport(lx, ly, lz)
    m = measure((px, py_, pz + 80), "slotrt_hall", True, seconds=10, settle=4)
    RESULTS["hall"] = m
    report("hall", m)
    if not check(not m.get("err") and len(m.get("opts", [])) == 2, "hall: both options measured", str(m.get("err"))):
        return
    off, on = m["opts"]
    for o in (off, on):
        check(not (o.get("capture") or {}).get("err") and o.get("capRt") is not None, f"hall option {o['opt']}: capture written", str(o.get("capture")))
    roomMid = mid(on.get("room"))
    capOff, capOn = (off.get("capRt") or {}).get("mid"), (on.get("capRt") or {}).get("mid")
    check(capOff is not None and capOff < 2.0, "hall, option off: the slot's tail rings under 2 s (the 0.5 s window estimate's cap)", f"capture mid {capOff}")
    check(within(capOn, roomMid, 0.35), "hall, option on: the slot's tail rings like the room (mid, +-35 % of the room's long estimate)", f"capture mid {capOn}, room {roomMid}")
    if m.get("getter"):
        check(not off.get("long") and mid(off.get("rt")) is not None and mid(off.get("rt")) < 2.0, "hall, option off: the slot uses the main simulation's reverb times (< 2 s)", fmt(off.get("rt")))
        check(bool(on.get("long")) and within(mid(on.get("rt")), roomMid, 0.35), "hall, option on: the slot uses a long-window estimate (mid within +-35 % of the room's)", f"{fmt(on.get('rt'))} vs room {fmt(on.get('room'))}")


def scene_floor():
    load("pba_pipe")
    native_on()
    pm = lua("client", "return {pba.PipeMap.listener.x, pba.PipeMap.listener.y, pba.PipeMap.listener.z, pba.PipeMap.pad.x, pba.PipeMap.pad.y, pba.PipeMap.pad.z}")
    lx, ly, lz, px, py_, pz = pm
    teleport(lx, ly, lz)
    # sounds ON the floor (a pipe lying on the pad, a footstep): the estimate taken at the floor itself is meaningless (0.1 s in the
    # high band, 0.1 to 20 s in the mid one in this hall); the Lua side lifts it (N.ProbeLift)
    rows = []
    for i, (dx, dy) in enumerate(((0, 0), (300, 150), (600, -200), (-100, 300))):
        m = measure((px + dx, py_ + dy, pz + 6), "slotrt_floor", False, settle=3.5, opts=(1,))
        rows.append(m)
        report(f"floor{i}", m)
    RESULTS["floor"] = rows
    for i, m in enumerate(rows):
        o = (m.get("opts") or [{}])[0]
        roomMid = mid(o.get("room"))
        check(bool(o.get("long")) and (o.get("lift") or 0) > 0.3 and within(mid(o.get("rt")), roomMid, 0.35),
              f"floor sound {i}: lifted, and its reverb time mid is the room's (+-35 %)", f"lift {o.get('lift')}, {fmt(o.get('rt'))} vs room {fmt(o.get('room'))}")
        rt = o.get("rt") or [0, 0, 0]
        check(all(x > 0.3 for x in rt), f"floor sound {i}: no degenerate band (all three > 0.3 s)", fmt(rt))


def scene_small():
    load("pba_tworooms")
    native_on()
    teleport(256, 256, 0)
    m = measure((356, 256, 40), "slotrt_small", True, seconds=4, settle=3)
    RESULTS["small"] = m
    report("small", m)
    if not check(not m.get("err") and len(m.get("opts", [])) == 2, "small: both options measured", str(m.get("err"))):
        return
    off, on = m["opts"]
    cOff, cOn = (off.get("capRt") or {}).get("mid"), (on.get("capRt") or {}).get("mid")
    roomMid = mid(on.get("room"))
    # on and off cannot agree here: the 0.5 s window estimate is 0.49 s in this 9.7 x 9.7 x 3.6 m concrete room, which the room bus
    # (long window) rings at 1.9 s. What the option must give is the ROOM's reverb time: one model for the listener's room and a
    # sound's own, in the same room.
    check(within(cOn, roomMid, 0.35), "small room, option on: the slot's tail rings like the room (capture mid, +-35 %)", f"{cOn} vs room {roomMid}")
    if m.get("getter"):
        check(not off.get("long") and within(mid(off.get("rt")), mid(off.get("mainRt")), 0.001), "small room, option off: the slot keeps the main simulation's reverb times", f"{fmt(off.get('rt'))} vs {fmt(off.get('mainRt'))}")
        check(bool(on.get("long")) and within(mid(on.get("rt")), roomMid, 0.20), "small room, option on: the slot's reverb time is the room's (mid, +-20 %)", f"{fmt(on.get('rt'))} vs room {fmt(on.get('room'))}")


def scene_other():
    load("pba_demo")
    lua("server", "pba.DemoMap.SetMode(3) return true")
    time.sleep(1)
    native_on()
    # the hangar (listener 2128, 300) and the closet next to it (listener 1556, 1110): the demo's own listening points
    teleport(1556, 1110, 0)
    closet = measure((1556, 1110, 40), "slotrt_closet", False, settle=3.5, opts=(1,))
    teleport(2128, 300, 0)
    other = measure((1556, 1110, 40), "slotrt_other", False, settle=3.5, opts=(0, 1))
    hangar = measure((2128, 300, 40), "slotrt_hangar", False, settle=3.5, opts=(1,))
    RESULTS["other"] = {"closet": closet, "other": other, "hangar": hangar}
    report("closet(listener in it)", closet)
    report("source in closet, listener in hangar", other)
    if not (check(other.get("getter"), "other room: module has SlotReverbTimes") and not closet.get("err") and not other.get("err")):
        return
    cl = closet["opts"][0]
    off, on = other["opts"]
    own = mid(cl.get("room"))   # the closet's long estimate, the listener standing in it
    hang = mid(hangar["opts"][0].get("room"))
    got = mid(on.get("rt"))
    check(bool(on.get("long")) and within(got, own, 0.35), "other room: the slot in the closet rings with the closet's reverb time (+-35 %)", f"slot {fmt(on.get('rt'))}, closet {fmt(cl.get('room'))}")
    check(own is not None and hang is not None and (hang >= 1.5 * own or own >= 1.5 * hang), "other room: the two rooms differ by 1.5 x (the check discriminates)", f"closet {own}, hangar {hang}")
    check(got is not None and hang is not None and abs(got - hang) > abs(got - own), "other room: the slot's time is the closet's, not the listener's hangar", f"slot {got}, closet {own}, hangar {hang}")
    check(not off.get("long"), "other room, option off: no long-window estimate on the slot")


def main():
    global MCP, GMOD
    args = [a for a in sys.argv[1:]]
    if "--selftest" in args:
        sys.exit(0 if selftest() else 1)
    MCP = args[0]
    only = None
    for a in args[1:]:
        if a.startswith("--only="):
            only = a[7:].split(",")
        if a.startswith("--gmod="):
            GMOD = a[7:]
    scenes = [("hall", scene_hall), ("floor", scene_floor), ("small", scene_small), ("other", scene_other)]
    saved = lua("client", "return GetConVar('pba_native_source_long_rt') and GetConVar('pba_native_source_long_rt'):GetString()")
    try:
        for name, fn in scenes:
            if only and name not in only:
                continue
            fn()
    finally:
        if saved is not None:
            call("console_exec", {"realm": "client", "cmd": f"pba_native_source_long_rt {saved}"})
    out = os.environ.get("SLR_OUT")
    if out:
        json.dump(RESULTS, open(out, "w"), indent=1, default=str)
    print("source_long_rt:", "PASS" if not FAILS else "FAIL " + "; ".join(FAILS))
    sys.exit(0 if not FAILS else 1)


if __name__ == "__main__":
    main()
