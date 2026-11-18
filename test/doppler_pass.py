"""Doppler pass through the module: continuity of the pitch the player hears (helicopter / gunship fly-by, "the sound
jumps, bugs" at a fast pass).

A source flies past the listener on a straight line and the module is given the pitch of N.Doppler at the rate the
followers update it (a frame, or hz updates a second); the module's FINAL output (a pure tone, pba_native.CaptureStart)
is analysed: instantaneous frequency of the tone over time (analytic signal), compared with the pitch curve it was
given. What the module is asked for is a staircase (one value per update); the question is whether what is heard is a
staircase too.
  step_cents   largest change of the tone's frequency between two instants STEP_MS apart (cents)
  ideal_cents  the same on the continuous Doppler curve (what a perfect rendering of the true motion would do)
  click        largest sample-to-sample jump of the tone relative to what a sine of its own frequency and level allows
Pass: step_cents <= STEP_RATIO x ideal_cents (+ a floor of STEP_FLOOR cents) and click <= CLICK_MAX. In game the update
instants are not regular (frame times), so the bound is looser than the offline one (native/test/pitch_glide_test.cpp,
which feeds the renderer on a fixed clock: 1.6 x + 2 cents).
Measured 2026-11-18 on the module before pba_native_pitch_glide (gm_construct, 1000 u/s, 150 u, one test client):
  144 updates/s 14.7 cents, 60/s 16.8, 30/s 34.2, 20/s 47.1 (ideal 6.4): the staircase of the updates is heard.
  --glide=<ms> sets pba_native_pitch_glide for the run (restored afterwards); the module of 2026-11-18+ is needed.
Usage (ONE test instance, MCP_INSTANCE=<id> if several run; the map is the one loaded, the listener stays put):
  python -I -X utf8 test/doppler_pass.py <mcp.py> [--speed=1000] [--dist=150] [--secs=5] [--hz=60,30,20] [--glide=30] [--check]
  python -I -X utf8 test/doppler_pass.py --analyze <capture.wav> <sent.json> ...
"""
import json
import math
import os
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from own_shot_capture import read_wav  # noqa: E402

GMOD = r"D:\SteamLibrary\steamapps\common\GarrysMod\garrysmod"
TONE_HZ, RATE = 1050.0, 48000
STEP_MS, STEP_RATIO, STEP_FLOOR, CLICK_MAX = 10.0, 2.5, 2.0, 1.6
C_UNITS = 343 / 0.01905


def write_tone(path, secs=12.0):
    n = int(secs * RATE)
    x = 0.5 * np.sin(2 * math.pi * TONE_HZ * np.arange(n) / RATE)
    pcm = np.round(x * 32767).astype("<i2").tobytes()
    hdr = b"RIFF" + (36 + len(pcm)).to_bytes(4, "little") + b"WAVEfmt " + (16).to_bytes(4, "little")
    hdr += (1).to_bytes(2, "little") + (1).to_bytes(2, "little") + RATE.to_bytes(4, "little") + (RATE * 2).to_bytes(4, "little")
    hdr += (2).to_bytes(2, "little") + (16).to_bytes(2, "little") + b"data" + len(pcm).to_bytes(4, "little")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(hdr + pcm)


def analytic(y):
    n = len(y)
    Y = np.fft.fft(y)
    h = np.zeros(n)
    h[0] = 1
    if n % 2 == 0:
        h[n // 2] = 1
        h[1:n // 2] = 2
    else:
        h[1:(n + 1) // 2] = 2
    return np.fft.ifft(Y * h)


def ideal_curve(speed, dist, secs, t):
    """Doppler factor of the continuous flight at times t (s, 0 = start of the flight), listener at the origin."""
    x = speed * (t - secs / 2)
    d = np.sqrt(x * x + dist * dist)
    # source velocity along +x, unit vector source -> listener (-x, -dist)/d: v.u = -speed * x / d
    vu = -speed * x / d
    return C_UNITS / np.maximum(C_UNITS - vu, 1.0)


def crossings(y, fs):
    """(time, Hz) at the middle of each period of the tone, from its positive-going zero crossings (a clean tone: every
    crossing gives the period to 1e-5)."""
    idx = np.nonzero((y[:-1] < 0) & (y[1:] >= 0))[0]
    z = idx + (-y[idx]) / (y[idx + 1] - y[idx])
    return 0.5 * (z[1:] + z[:-1]) / fs, fs / np.diff(z)


def analyze(wav, sent, speed, dist, secs, lead=0.3):
    w = read_wav(wav)
    y = np.asarray(w["l"], dtype=np.float64) + np.asarray(w["r"], dtype=np.float64)  # (sum of the ears: one clean tone)
    fs = w["rate"]
    amp = np.abs(analytic(y))
    # onset of the tone: first time the envelope passes half its median level
    lvl = np.median(amp[amp > 0.02 * amp.max()])
    on = int(np.argmax(amp > 0.5 * lvl)) / fs
    tc, fc = crossings(y, fs)
    tc = tc - on
    t = np.arange(0.2, secs - 0.2, 0.001)
    f = np.interp(t, tc, fc)
    f10 = np.interp(t + STEP_MS / 1000, tc, fc)
    step_c = float(np.max(np.abs(1200 * np.log2(f10 / f))))
    tt = np.arange(0, secs, 0.0005)
    k = ideal_curve(speed, dist, secs, tt)
    n = int(STEP_MS / 1000 / 0.0005)
    ideal_c = float(np.max(np.abs(1200 * np.log2(k[n:] / k[:-n]))))
    # sample jumps relative to a sine of the local frequency and level: max |y[n]-y[n-1]| / (2 pi f A / fs)
    i0, i1 = int((on + 0.2) * fs), int((on + secs - 0.2) * fs)
    fl = np.interp(np.arange(i0, i1) / fs - on, tc, fc)
    allow = 2 * math.pi * fl * amp[i0:i1] / fs
    click = float(np.max(np.abs(np.diff(y))[i0 - 1:i1 - 1] / np.maximum(allow, 1e-9)))
    # how well does the heard frequency follow what was sent (clock aligned by the onset, best delay)?
    ts = np.array([q[0] for q in sent]); ps = np.array([q[1] for q in sent]) / 100
    want = TONE_HZ * np.interp(t, ts, ps)
    best = min((float(np.mean(np.abs(np.interp(t - d, t, f) - want))), d) for d in np.arange(-0.05, 0.15, 0.001))
    return {"step_cents": step_c, "ideal_cents": ideal_c, "click": click, "follow_err_hz": best[0], "latency_ms": best[1] * 1000,
            "fmin": float(f.min()), "fmax": float(f.max()), "updates": len(sent), "onset_s": on}


def judge(r):
    ok = r["step_cents"] <= STEP_RATIO * r["ideal_cents"] + STEP_FLOOR and r["click"] <= CLICK_MAX
    return ok


def call(mcp, tool, args, timeout=400):
    out = subprocess.run([sys.executable, "-I", mcp, "call", tool, json.dumps(args), "4000000"], capture_output=True, text=True,
                         encoding="utf-8", errors="replace", timeout=timeout).stdout
    try:
        return json.loads(out)
    except ValueError:
        return {"raw": out[:500]}


def main(argv):
    if "--analyze" in argv:
        i = argv.index("--analyze")
        r = analyze(argv[i + 1], json.load(open(argv[i + 2])), 1000, 150, 5)
        print(json.dumps(r, indent=1))
        return 0
    mcp = argv[0]
    sys.path.insert(0, HERE)
    import _cvsnap  # restores every pba_* setting at exit, even on failure
    _cvsnap.guard(lambda tool, args: call(mcp, tool, args))
    opt = dict(a[2:].split("=", 1) for a in argv[1:] if a.startswith("--") and "=" in a)
    speed, dist, secs = float(opt.get("speed", 1000)), float(opt.get("dist", 150)), float(opt.get("secs", 5))
    hzs = [float(h) for h in opt.get("hz", "60,30,20").split(",")]
    tone = os.path.join(GMOD, "sound", "pba_test", "doppler_tone.wav")
    write_tone(tone)
    if "glide" in opt:
        call(mcp, "console_exec", {"realm": "client", "cmd": "pba_native_pitch_glide " + opt["glide"]})
        call(mcp, "lua_job", {"realm": "client", "timeout_s": 20, "code": "job:sleep(1.5) return true"})  # (the settings timer pushes it to the module)
    code = open(os.path.join(HERE, "doppler_pass.lua"), encoding="utf-8").read()
    fails = 0
    try:
        for hz in hzs:
            name = "doppler_pass_%d" % int(hz)
            res = call(mcp, "lua_job", {"realm": "client", "code": code, "timeout_s": 120,
                                        "args": {"speed": speed, "dist": dist, "secs": secs, "hz": hz, "name": name,
                                                 "pitchStep": float(opt.get("pitchstep", 0))}}, timeout=200)
            v = (res.get("values") or [None])[0]
            if not v or not v.get("ok"):
                print("hz", hz, "FAILED", str(res)[:400])
                fails += 1
                continue
            sent = v["sent"]
            json.dump(sent, open(os.path.join(GMOD, "data", "pba", name + "_sent.json"), "w"))
            r = analyze(v["path"], sent, speed, dist, secs)
            r["hz"] = hz
            r["fps"] = v.get("fps")
            ok = judge(r)
            fails += 0 if ok else 1
            print("PASS" if ok else "FAIL", "hz=%g (%d updates, %.0f/s) speed=%g dist=%g: step %.1f cents (ideal %.1f), click %.2f, follow %.2f Hz, latency %.0f ms, f %.0f..%.0f Hz"
                  % (hz, r["updates"], r["fps"] or 0, speed, dist, r["step_cents"], r["ideal_cents"], r["click"], r["follow_err_hz"], r["latency_ms"], r["fmin"], r["fmax"]), flush=True)
    finally:
        try:
            os.remove(tone)
        except OSError:
            pass
    return 1 if (fails and "--check" in argv) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
