"""T9 dsp_muffle_real: the Light version muffles for real (the engine's own DSP, heard, not just asked for).
WARNING: plays loud white noise (about 20 s in all) and writes wav files into garrysmod/ (startmovie): run
it on ONE game instance at a time, and tell the user. Usage: python -I -X utf8 dsp_muffle_real.py <mcp.py>
1. the frequency response of the two low-pass presets PBA uses (dsp_slope.py, measured 2026-11-13):
     preset 30: -3 dB at 1992 Hz, -9.1 dB at 4 kHz, slope -5.9 then -10.7 dB/octave
     preset 31: -3 dB at 754 Hz, -25 dB at 4 kHz, slope -6.5 then -10.0 dB/octave
   asserted: -3 dB point <= 4000 Hz (30) and <= 1500 Hz (31), 4 kHz at least 6 dB down (30), slope per
   octave >= 4 dB (first; -5.2 to -5.9 measured over runs) and >= 6 dB (second), preset 31 duller than 30
2. a PBA copy recorded behind the closed door (relayed, engine rendering, DSP 31) against the same noise
   from the listener's room: the energy ratio above 2 kHz / below 500 Hz is at least 10 dB lower
   (measured: see the printed value)
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

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dsp_slope as ds  # noqa: E402

MCP = sys.argv[1]
GAME = os.environ.get("PBA_GAME_DIR", r"D:\SteamLibrary\steamapps\common\GarrysMod\garrysmod")
MIN_DULLER_DB = 10


def call(tool, args, mx=2_000_000, timeout=300):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), str(mx)],
                         capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout).stdout
    try:
        return json.loads(out)
    except ValueError:
        return {"raw": out}


import _cvsnap  # noqa: E402  restores every pba_* setting at exit, even on failure
_cvsnap.guard(call)


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


results = []


def check(name, cond, detail):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name + " :: " + detail, flush=True)


# ------------------------------------------------------------------ 1. the presets
p = subprocess.run([sys.executable, "-I", "-X", "utf8", os.path.join(HERE, "dsp_slope.py"), MCP],
                   capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=300)
txt = p.stdout
resp = None
if "{" in txt:
    try:
        resp = json.JSONDecoder().raw_decode(txt[txt.index("{"):])[0].get("response")
    except ValueError:
        resp = None
if not resp or any("error" in v for v in resp.values()):
    check("T9-presets-recorded", False, f"dsp_slope.py gave no response: {txt[-400:]} {p.stderr[-300:]}")
else:
    r30, r31 = resp["pba_dsp_30.WAV"], resp["pba_dsp_31.WAV"]

    def slopes(r):
        return [v for v in r["slope_db_per_octave"].values()]
    s30, s31 = slopes(r30), slopes(r31)
    check("T9-preset30", r30["minus3db_hz"] and r30["minus3db_hz"] <= 4000 and r30["bands_db"]["4000"] <= -6
          and len(s30) >= 2 and s30[0] <= -4 and s30[1] <= -6,
          f"-3 dB at {r30['minus3db_hz']} Hz, 4 kHz {r30['bands_db']['4000']} dB, slopes {s30}")
    check("T9-preset31", r31["minus3db_hz"] and r31["minus3db_hz"] <= 1500 and len(s31) >= 2 and s31[0] <= -4 and s31[1] <= -6,
          f"-3 dB at {r31['minus3db_hz']} Hz, slopes {s31}")
    check("T9-31-duller-than-30", r31["bands_db"]["2000"] <= r30["bands_db"]["2000"] - 6,
          f"2 kHz: preset 31 {r31['bands_db']['2000']} dB, preset 30 {r30['bands_db']['2000']} dB")

# ------------------------------------------------------------------ 2. a recorded copy behind the closed door
SOUND = ds.NOISE
noise = os.path.join(GAME, "sound", *SOUND.split("/"))
outdir = tempfile.mkdtemp(prefix="pba_muffle_")
st = call("status", {})
if st.get("map") != "pba_tworooms" or st.get("maxplayers") != 4:
    call("map_load", {"map": "pba_tworooms", "maxplayers": 4}, timeout=300)
    time.sleep(4)
PLACE = """local p = player.GetHumans()[1] p:SetPos(Vector(256, 256, 0))
for _, d in ipairs(ents.FindByName('door1')) do d:Fire('Close') end
if IsValid(PBA_T9_PROP) then PBA_T9_PROP:Remove() end
local e = ents.Create('prop_physics') e:SetModel('models/props_junk/popcan01a.mdl') e:SetPos(Vector(%d, 256, 40)) e:Spawn()
local ph = e:GetPhysicsObject() if IsValid(ph) then ph:EnableMotion(false) end
PBA_T9_PROP = e
return true"""


def record(name, x):
    """Noise from the prop at x (room A: 400, room B behind the closed door: 784), recorded by the engine."""
    lua("server", PLACE % x)
    time.sleep(3.5)  # the door swings shut
    for old in glob.glob(os.path.join(GAME, name + "*.wav")):
        os.remove(old)
    call("console_exec", {"realm": "client", "cmd": f"startmovie {name} wav"})
    time.sleep(0.5)
    lua("server", f"PBA_T9_PROP:EmitSound('{SOUND}', 90, 100, 1, CHAN_STATIC) return true")
    time.sleep(ds.SECONDS)
    call("console_exec", {"realm": "client", "cmd": "endmovie"})
    lua("server", f"PBA_T9_PROP:StopSound('{SOUND}') return true")
    time.sleep(1.5)
    found = sorted(glob.glob(os.path.join(GAME, name + "*.wav")), key=os.path.getmtime)
    if not found:
        return None
    dst = os.path.join(outdir, os.path.basename(found[-1]))
    shutil.move(found[-1], dst)
    return dst


def hi_lo_db(path):
    sp = ds.spectrum(path)
    if sp is None:
        return None
    _, f, pw = sp
    hi = pw[(f >= 2000) & (f <= 10000)].sum()
    lo = pw[(f >= 60) & (f <= 500)].sum()
    return float(10 * np.log10(hi / lo))


try:
    ds.write_noise(noise)
    call("console_exec", {"realm": "client", "cmd": "pba_native_render 0"})
    call("console_exec", {"realm": "client", "cmd": "pba_cl_enable 1"})
    time.sleep(1)
    near = record("pba_t9_view", 400)
    behind = record("pba_t9_door", 784)
    if not near or not behind:
        check("T9-recorded", False, f"no wav written (startmovie): view={near} door={behind}")
    else:
        a, b = hi_lo_db(near), hi_lo_db(behind)
        check("T9-copy-duller", a is not None and b is not None and b <= a - MIN_DULLER_DB,
              f"energy 2-10 kHz / 60-500 Hz: in view {a} dB, behind the closed door {b} dB (needs >= {MIN_DULLER_DB} dB lower)")
finally:
    call("console_exec", {"realm": "client", "cmd": "endmovie"})
    lua("server", "if IsValid(PBA_T9_PROP) then PBA_T9_PROP:Remove() end for _, d in ipairs(ents.FindByName('door1')) do d:Fire('Open') end return true")
    if os.path.exists(noise):
        os.remove(noise)
    shutil.rmtree(outdir, ignore_errors=True)

print(f"{sum(results)}/{len(results)} passed")
sys.exit(0 if results and all(results) else 1)
