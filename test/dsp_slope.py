"""Frequency response of the engine DSP presets PBA uses for its lowpass levels (dsp_lp1..4: 30 and 31
by default). scripts/dsp_presets.txt only says "FLT LP 3000 Hz, quality MED" (30) and "FLT LP 1000 Hz,
quality MED" + an 80 ms linear delay (31): the filter order, hence the slope, is not written anywhere
we may read. This measures it: a white-noise one-shot is played at the listener with DSP 0 (reference),
then with each preset, while the engine records its own mix (startmovie <name> wav); the response is
the ratio of the noise spectra (Welch), per band, with the -3 dB frequency and the slope per octave
above it.
PBA is switched off on this client for the measurement (pba_cl_enable 0, restored at exit).
WARNING: plays loud white noise, 5 s per preset: tell the user before running it.
Usage: python -I dsp_slope.py <mcp.py> [--presets=30,31] [--gmod=<garrysmod dir>] [--out=<dir>]
       python -I dsp_slope.py --analyze <reference.wav> <preset.wav> [...]   (offline)
"""
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

import numpy as np
from scipy.io import wavfile
from scipy.signal import welch

BANDS = [125, 250, 500, 1000, 1500, 2000, 3000, 4000, 6000, 8000, 12000, 16000]
NOISE = "pba_test/pba_noise.wav"
SECONDS = 5.0


def mono(path):
    rate, x = wavfile.read(path)
    x = x.astype(np.float64)
    if x.ndim > 1:
        x = x.mean(axis=1)
    return rate, x


def active(x, rate):
    """The part of a recording where the noise plays (RMS over 50 ms windows above 30 % of the
    loudest), without its first and last 0.5 s (start, fades)."""
    w = int(rate * 0.05)
    n = len(x) // w
    if n < 10:
        return None
    rms = np.sqrt((x[: n * w].reshape(n, w) ** 2).mean(axis=1))
    on = np.where(rms > 0.3 * rms.max())[0]
    if len(on) == 0:
        return None
    a, b = (on[0] + 10) * w, (on[-1] - 10) * w
    return x[a:b] if b - a > rate * 2 else None


def spectrum(path):
    rate, x = mono(path)
    seg = active(x, rate)
    if seg is None:
        return None
    f, p = welch(seg, fs=rate, nperseg=4096)
    return rate, f, p


def response(ref, other):
    """dB per band (third octave around each), -3 dB frequency and slope per octave above it,
    relative to the reference (DSP 0) recording."""
    rate, f, p0 = ref
    _, _, p1 = other
    ratio = 10 * np.log10(np.maximum(p1, 1e-30) / np.maximum(p0, 1e-30))
    out = {}
    for b in BANDS:
        if b * 2 ** (1 / 6) >= rate / 2:
            continue
        m = (f >= b * 2 ** (-1 / 6)) & (f < b * 2 ** (1 / 6))
        if m.any():
            out[b] = round(float(ratio[m].mean()), 2)
    base = out.get(250, 0.0)  # broadband gain of the preset (gain 1.0 expected)
    fc = None
    for i in range(1, len(f)):
        if f[i] > 300 and ratio[i] < base - 3:
            fc = float(f[i])
            break
    slopes = {}
    if fc:
        for k in (1, 2):  # octaves [fc, 2 fc] and [2 fc, 4 fc]
            lo, hi = fc * 2 ** (k - 1), fc * 2 ** k
            if hi * 2 ** (1 / 6) < rate / 2:
                def at(fr):
                    m = (f >= fr * 2 ** (-1 / 6)) & (f < fr * 2 ** (1 / 6))
                    return float(ratio[m].mean())
                slopes[f"{int(lo)}-{int(hi)} Hz"] = round(at(hi) - at(lo), 2)
    return {"bands_db": out, "gain_250_db": base, "minus3db_hz": fc and round(fc), "slope_db_per_octave": slopes}


def analyze(paths):
    ref = spectrum(paths[0])
    if ref is None:
        return {"error": f"no noise found in {paths[0]}"}
    res = {}
    for p in paths[1:]:
        s = spectrum(p)
        res[os.path.basename(p)] = response(ref, s) if s else {"error": "no noise found"}
    return res


def write_noise(path, rate=44100, seconds=8.0):
    rng = np.random.default_rng(1)
    x = rng.standard_normal(int(rate * seconds)) * 0.25 * 32767 / 4  # ~-24 dBFS RMS, no clipping
    os.makedirs(os.path.dirname(path), exist_ok=True)
    wavfile.write(path, rate, np.clip(x, -32767, 32767).astype(np.int16))


def main():
    if sys.argv[1] == "--analyze":
        print(json.dumps(analyze(sys.argv[2:]), indent=1))
        return 0
    mcp = sys.argv[1]
    opts = dict(a[2:].split("=", 1) for a in sys.argv[2:] if a.startswith("--") and "=" in a)
    presets = [int(v) for v in opts.get("presets", "30,31").split(",")]
    gmod = opts.get("gmod", r"D:\SteamLibrary\steamapps\common\GarrysMod\garrysmod")
    outdir = opts.get("out") or tempfile.mkdtemp(prefix="pba_dsp_")
    here = os.path.dirname(os.path.abspath(__file__))

    def call(tool, args, mx=2_000_000, timeout=300):
        out = subprocess.run([sys.executable, "-I", mcp, "call", tool, json.dumps(args), str(mx)],
                             capture_output=True, text=True, encoding="utf-8", timeout=timeout).stdout
        try:
            return json.loads(out)
        except ValueError:
            return {"raw": out}

    sys.path.insert(0, here)
    import _cvsnap  # restores every pba_* setting at exit, even on failure
    _cvsnap.guard(call)

    def lua(realm, code):
        v = call("lua_exec", {"realm": realm, "code": code}).get("values")
        return v[0] if v else None

    noise = os.path.join(gmod, "sound", *NOISE.split("/"))
    write_noise(noise)
    st = call("status", {})
    if not st.get("map"):
        call("map_load", {"map": "pba_tworooms", "maxplayers": 4})
        time.sleep(4)
    call("console_exec", {"realm": "client", "cmd": "pba_cl_enable 0"})
    time.sleep(1)
    files = {}
    try:
        for dsp in [0] + presets:
            name = f"pba_dsp_{dsp}"
            for old in glob.glob(os.path.join(gmod, name + "*.wav")):
                os.remove(old)
            call("console_exec", {"realm": "client", "cmd": f"startmovie {name} wav"})
            time.sleep(0.5)
            # Entity:EmitSound(name, level, pitch, volume, channel, flags, dsp): on the listener itself
            lua("client", f"LocalPlayer():EmitSound('{NOISE}', 75, 100, 1, CHAN_STATIC, 0, {dsp}) return true")
            time.sleep(SECONDS)
            call("console_exec", {"realm": "client", "cmd": "endmovie"})
            time.sleep(1)
            found = sorted(glob.glob(os.path.join(gmod, name + "*.wav")), key=os.path.getmtime)
            if not found:
                print(f"FAIL no {name}*.wav written in {gmod}: startmovie ... wav refused or written elsewhere "
                      f"(check the console; it can be typed by hand there)")
                return 1
            dst = os.path.join(outdir, os.path.basename(found[-1]))
            shutil.move(found[-1], dst)
            files[dsp] = dst
    finally:
        call("console_exec", {"realm": "client", "cmd": "endmovie"})
        if os.path.exists(noise):
            os.remove(noise)
    res = analyze([files[0]] + [files[d] for d in presets])
    print(json.dumps({"recordings": outdir, "response": res}, indent=1))
    return 0 if "error" not in res and all("error" not in v for v in res.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
