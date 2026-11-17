"""Gunfire and explosions in OPEN terrain, engine against native module ("sound muddled, even in open areas", Workshop).

A measurement first. The listener stands still on gm_flatgrass (nothing around: no wall, no ceiling) and the same
sounds are played from 300 / 1000 / 2500 u away: NPC AR2 / SMG1 / pistol / shotgun shots and an explosion. Each
condition records the whole sequence:
  engine          pba_enable 0 / pba_cl_enable 0: the engine plays them, `startmovie <name> wav` records its mix
  module          the module's FINAL output (pba_native.CaptureStart / CaptureStop)
  module_noreverb the same with pba_native_reverb 0 (what the room send / echoes add)
  module_<k>=<v>  --cond=<name>:<cl|sv>:<cvar>=<value>[,...]   any other module condition
Per event it reports the peak, the attack (rise time 10-90 % of the 1 ms envelope), the energy after the direct
window (tail / direct, dB), the decay (time for the energy envelope to fall 20 and 30 dB below its peak, backward
integral T20 -> RT60), the spectral shape (bands, centroid, 95 % roll-off) and, for the module, the reverb state
read 0.7 s after the emission (RoomReverb, slot reverb times, the Play arguments).

Usage (ONE test instance, MCP_INSTANCE=<id> if several run; nothing here launches or closes the game):
  python -I -X utf8 test/open_area_capture.py <mcp.py> [--out=<dir>] [--map=gm_flatgrass] [--only=engine,module]
         [--sounds=ar2,smg1,pistol,shotgun,explosion] [--dists=300,1000,2500] [--yaws=0,90,180] [--pos=x,y,z] [--spacing=5] [--cond=...]
  python -I -X utf8 test/open_area_capture.py --analyze <out dir> [--check [--which=module] [--expect-red=treble]]
         (offline, from the recordings of a run; --check judges the module against the engine: reverb parity, treble parity)
  python -I -X utf8 test/open_area_capture.py --selftest
"""
import glob
import json
import math
import os
import shutil
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from own_shot_capture import read_wav  # noqa: E402

GMOD_DEFAULT = r"D:\SteamLibrary\steamapps\common\GarrysMod\garrysmod"
# (file as the sound script names it, level dB, volume, pitch): the scripts' own values with ONE wave and a fixed
# pitch (a random wave / pitch would make the two conditions play different sounds)
SOUNDS = {
    "ar2": ("^weapons/ar1/ar1_dist1.wav", 105, 0.7),
    "smg1": ("^weapons/smg1/npc_smg1_fire1.wav", 105, 0.7),
    "pistol": ("^weapons/pistol/pistol_fire3.wav", 105, 0.7),
    "shotgun": (")weapons/shotgun/shotgun_fire6.wav", 105, 0.95),
    "ar2pl": (")weapons/ar2/fire1.wav", 105, 0.8),
    "explosion": ("^weapons/explode3.wav", 140, 1.0),
}
BANDS = [(0, 500), (500, 2000), (2000, 6000), (6000, 16000)]
BAND_NAMES = ["0-0.5k", "0.5-2k", "2-6k", "6-16k"]
DIRECT = 0.15      # s after the onset counted as "direct" (the shot itself)
TAILEND = 3.5      # s after the onset analysed
BASELINE = [("sv", "pba_enable", "1"), ("cl", "pba_cl_enable", "1"), ("cl", "pba_native_render", "1"), ("cl", "pba_native_all", "1")]
DEFAULT_CONDS = [
    ("engine", "engine", [("sv", "pba_enable", "0"), ("cl", "pba_cl_enable", "0")]),
    ("module", "module", []),
    ("module_noreverb", "module", [("cl", "pba_native_reverb", "0")]),
]


# ------------------------------------------------------------------ analysis
def _db(x):
    return 10 * math.log10(max(x, 1e-30))


def smooth(x, n):
    n = max(1, int(n))
    if n == 1:
        return x
    c = np.cumsum(np.concatenate(([0.0], x)))
    return (c[n:] - c[:-n]) / n


def event_metrics(l, r, sr, t0, t1):
    """Metrics of the event whose recording lies in samples [t0, t1) (the onset is searched inside)."""
    l, r = l[t0:t1], r[t0:t1]
    e = l * l + r * r
    env = smooth(e, sr * 0.001)           # 1 ms mean-square envelope
    pk = float(env.max()) if len(env) else 0.0
    if pk <= 1e-12:
        return None
    on = int(np.argmax(env >= pk * 10 ** (-3.5)))   # -35 dB below the peak (power)
    on = max(0, on - int(sr * 0.003))
    # attack: 10 -> 90 % of the amplitude (sqrt of the 1 ms envelope) peak within the first 120 ms
    amp = np.sqrt(env[on:on + int(sr * 0.12)])
    amax = float(amp.max())
    i10 = int(np.argmax(amp >= 0.1 * amax))
    i90 = int(np.argmax(amp >= 0.9 * amax))
    seg = e[on:on + int(sr * TAILEND)]
    nd = int(sr * DIRECT)
    ed, et = float(seg[:nd].sum()), float(seg[nd:].sum())
    # backward integral (Schroeder) of the energy, dB below its start
    sch = np.cumsum(seg[::-1])[::-1]
    sdb = 10 * np.log10(np.maximum(sch / max(sch[0], 1e-30), 1e-30))
    def tcross(db):
        k = np.argmax(sdb <= db)
        return float(k / sr) if sdb[k] <= db else float("nan")
    # envelope (10 ms) decay from its peak
    env10 = smooth(seg, sr * 0.01)
    pk10 = int(np.argmax(env10))
    e10 = 10 * np.log10(np.maximum(env10 / max(env10[pk10], 1e-30), 1e-30))
    def dcross(db):
        k = np.argmax(e10[pk10:] <= db)
        return float((k + pk10) / sr) if e10[pk10 + k] <= db else float("nan")
    # spectrum: direct window (onset-3 ms .. +0.3 s), summed power of both channels
    a = max(0, on - int(sr * 0.003))
    w = int(sr * 0.3)
    nfft = 1 << int(math.ceil(math.log2(w)))
    win = np.hanning(min(w, len(l) - a))
    def spec(x):
        y = x[a:a + len(win)] * win
        return np.abs(np.fft.rfft(y, nfft)) ** 2
    p = spec(l) + spec(r)
    f = np.fft.rfftfreq(nfft, 1 / sr)
    tot = float(p.sum())
    bands = [_db(float(p[(f >= lo) & (f < hi)].sum())) for lo, hi in BANDS]
    shape = [b - _db(tot) for b in bands]
    cent = float((f * p).sum() / max(tot, 1e-30))
    cs = np.cumsum(p) / max(tot, 1e-30)
    f95 = float(f[min(len(f) - 1, int(np.argmax(cs >= 0.95)))])
    n20 = int(sr * 0.02)
    pkamp = float(np.max(np.abs(np.concatenate((l[on:on + nd], r[on:on + nd])))))
    rms = math.sqrt(ed / max(nd, 1) / 2)
    return {
        "early20_db": _db(float(seg[:n20].sum())) - _db(ed),      # energy of the first 20 ms in the direct window
        "crest_db": 20 * math.log10(max(pkamp, 1e-12) / max(rms, 1e-12)),   # peak sample over rms of the direct window
        "onset_s": (t0 + on) / sr,
        "peak_db": _db(pk / 2),   # dBFS (power of the 1 ms envelope, mean of the two channels)
        "rise_ms": (i90 - i10) / sr * 1000,
        "tail_direct_db": _db(et) - _db(ed),
        "direct_db": _db(ed),
        "t20_s": tcross(-20), "t30_s": tcross(-30),
        "rt60_from_t20": 3 * tcross(-20) if not math.isnan(tcross(-20)) else float("nan"),
        "env_dec20_s": dcross(-20) - pk10 / sr, "env_dec30_s": dcross(-30) - pk10 / sr,
        "band_db": bands, "shape_db": shape, "centroid_hz": cent, "f95_hz": f95,
    }


def analyze_recording(path, n_events, spacing, times=None):
    """times: the game time (CurTime) each event was emitted at (the driver's log); the windows follow them, anchored on
    the onset of the first event (the first sound of the file 30 dB under its peak, after a 0.5 s guard: a capture can
    start with a click)."""
    w = read_wav(path)
    l, r, sr = np.asarray(w["l"]), np.asarray(w["r"]), w["rate"]
    env = smooth(l * l + r * r, sr * 0.001)
    mx = float(env.max()) if len(env) else 0
    if mx <= 1e-12:
        return {"rate": sr, "events": [None] * n_events, "silent": True}
    g = int(sr * 0.5)
    first = g + int(np.argmax(env[g:] >= mx * 1e-3))
    ev = []
    for k in range(n_events):
        off = (times[k] - times[0]) if times else k * spacing
        t0 = max(0, first + int((off - 0.4) * sr))
        t1 = min(len(l), first + int((off + spacing - 0.4) * sr))
        ev.append(event_metrics(l, r, sr, t0, t1) if t1 - t0 > sr * 0.5 else None)
    return {"rate": sr, "ch": w["ch"], "bits": w["bits"], "events": ev}


def fmt(v, p=1):
    return "  nan" if v is None or (isinstance(v, float) and math.isnan(v)) else f"{v:{5 + p}.{p}f}"


def report(results, events):
    """results: {condition: analysis}; events: [(label, snd, dist)]. First condition = reference."""
    names = list(results)
    lines = []
    ap = lines.append
    for nm in names:
        ap(f"[{nm}] rate {results[nm].get('rate')} Hz")
    keys = [("peak_db", "peak dB", 1), ("rise_ms", "rise ms", 1), ("early20_db", "first 20 ms / direct dB", 1), ("crest_db", "crest dB", 1), ("tail_direct_db", "tail/direct dB", 1),
            ("t20_s", "T20 s", 2), ("env_dec30_s", "env-30dB s", 2), ("centroid_hz", "centroid Hz", 0), ("f95_hz", "f95 Hz", 0)]
    for key, title, p in keys:
        ap(f"== {title}")
        ap("  " + f"{'event':<22}" + "".join(f"{n[:16]:>17}" for n in names))
        for i, (lab, _, _) in enumerate(events):
            row = []
            for nm in names:
                e = results[nm]["events"][i]
                row.append(fmt(e[key], p) if e else "  n/a")
            ap("  " + f"{lab:<22}" + "".join(f"{x:>17}" for x in row))
    ap("== spectral shape (band minus total, dB): " + " | ".join(BAND_NAMES))
    for i, (lab, _, _) in enumerate(events):
        for nm in names:
            e = results[nm]["events"][i]
            if e:
                ap(f"  {lab:<22}{nm[:16]:<17}" + " | ".join(f"{v:6.1f}" for v in e["shape_db"]))
    txt = "\n".join(lines)
    print(txt, flush=True)
    return txt


# ------------------------------------------------------------------ selftest
def _synth(sr, shots, rt=0.0, lp=None, secs=4.0):
    rng = np.random.default_rng(5)
    n = int(sr * secs)
    x = np.zeros(n)
    t = np.arange(n) / sr
    x += rng.standard_normal(n) * np.exp(-t / 0.02) * 0.5   # a 20 ms noise burst
    if rt > 0:
        x += rng.standard_normal(n) * np.exp(-t * 6.9 / rt) * 0.1 * (t > 0.03)
    if lp:
        X = np.fft.rfft(x)
        X[np.fft.rfftfreq(n, 1 / sr) > lp] = 0
        x = np.fft.irfft(X, n)
    return x


def selftest():
    sr = 44100
    fails = []
    def check(c, m):
        print(("ok   " if c else "FAIL ") + m)
        if not c:
            fails.append(m)
    sec = 4.0
    dry = _synth(sr, 1)
    wet = _synth(sr, 1, rt=1.5)
    dull = _synth(sr, 1, lp=1500)
    d = event_metrics(dry, dry, sr, 0, int(sr * sec))
    w = event_metrics(wet, wet, sr, 0, int(sr * sec))
    u = event_metrics(dull, dull, sr, 0, int(sr * sec))
    check(w["tail_direct_db"] > d["tail_direct_db"] + 10, f"reverb tail raises tail/direct ({d['tail_direct_db']:.1f} -> {w['tail_direct_db']:.1f})")
    check(w["t20_s"] > d["t20_s"] * 3, f"reverb lengthens T20 ({d['t20_s']:.3f} -> {w['t20_s']:.3f})")
    check(u["f95_hz"] < d["f95_hz"] * 0.5, f"low-pass lowers f95 ({d['f95_hz']:.0f} -> {u['f95_hz']:.0f})")
    check(u["shape_db"][3] < d["shape_db"][3] - 10, "low-pass lowers the 6-16k shape")
    print("SELFTEST " + ("FAILED" if fails else "PASS"))
    return 1 if fails else 0


# ------------------------------------------------------------------ in game
def run_game(mcp, opts):
    from _coretest import Core
    T = Core(mcp)
    gmod = opts.get("gmod", GMOD_DEFAULT)
    out = opts.get("out") or os.path.join(os.environ.get("TEMP", "."), "pba_open_area_" + time.strftime("%Y%m%d_%H%M%S"))
    os.makedirs(out, exist_ok=True)
    spacing = float(opts.get("spacing", 5))
    sounds = opts.get("sounds", "ar2,smg1,pistol,shotgun,explosion").split(",")
    dists = [int(x) for x in opts.get("dists", "300,1000,2500").split(",")]
    yaws = [int(x) for x in opts.get("yaws", "0").split(",")]
    events = [{"snd": SOUNDS[s][0], "lvl": SOUNDS[s][1], "vol": SOUNDS[s][2], "dist": d, "yaw": y} for s in sounds for d in dists for y in yaws]
    labels = [(f"{s} {d}u" + (f" yaw{y}" if len(yaws) > 1 else ""), SOUNDS[s][0], d) for s in sounds for d in dists for y in yaws]
    conds = list(DEFAULT_CONDS)
    for c in opts.get("cond", []):
        name, _, rest = c.partition(":")
        cv = []
        for part in rest.split(","):
            realm, _, nv = part.partition(":")
            n, _, v = nv.partition("=")
            cv.append((realm, n, v))
        conds.append((name, "module", cv))
    if "only" in opts:
        conds = [c for c in conds if c[0] in opts["only"].split(",")]
    T.load(opts.get("map", "gm_flatgrass"), mp=1)
    T.lua("server", """MUD = MUD or {}
function MUD.Emit(snd, dist, ang, lvl, vol)
  local ply = player.GetHumans()[1]
  local pos = ply:GetPos() + Angle(0, ang or 0, 0):Forward() * dist + Vector(0, 0, 54)
  if IsValid(MUD.ent) then MUD.ent:Remove() end
  local e = ents.Create("prop_physics")
  e:SetModel("models/props_junk/PopCan01a.mdl") e:SetPos(pos) e:Spawn() e:SetNoDraw(true)
  e:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)
  local ph = e:GetPhysicsObject() if IsValid(ph) then ph:EnableMotion(false) end
  MUD.ent = e
  e:EmitSound(snd, lvl or 105, 100, vol or 1, CHAN_WEAPON)
end
concommand.Add("mud_emit", function(_, _, a) MUD.Emit(a[1], tonumber(a[2]) or 300, tonumber(a[3]) or 0, tonumber(a[4]), tonumber(a[5])) end)
local p = player.GetHumans()[1] p:GodEnable() p:StripWeapons() p:SetVelocity(-p:GetVelocity()) p:SetEyeAngles(Angle(0, 0, 0)) %s return true""" % (
        ("p:SetPos(Vector(%s))" % opts["pos"]) if opts.get("pos") else ""))
    time.sleep(2.0)
    lua_src = open(os.path.join(HERE, "open_area_capture.lua"), encoding="utf-8").read()
    results, log = {}, {}
    def lit(v):
        if isinstance(v, dict):
            return "{" + ",".join(f"[{json.dumps(k)}]={lit(x)}" for k, x in v.items()) + "}"
        if isinstance(v, list):
            return "{" + ",".join(lit(x) for x in v) + "}"
        return json.dumps(v)

    for name, rec, cvars in conds:
        print(f"-- {name} ({rec})", flush=True)
        for realm, n, v in BASELINE + cvars:
            T.con({"cl": "client", "sv": "server"}[realm], f"{n} {v}")
        T.lua("client", "RunConsoleCommand('stopsound') return true")
        time.sleep(2.5)
        expect = {n: v for realm, n, v in BASELINE + cvars}
        fname = f"oac_{name}"
        tmp_prefix = os.path.join(gmod, fname)
        warm = "OAC = " + lit({"warmOnly": True, "mode": rec, "events": events}) + "\n"
        T.job("client", warm + lua_src, timeout_s=120)
        if rec == "engine":
            for old in glob.glob(tmp_prefix + "*.wav"):
                os.remove(old)
            T.con("client", f"startmovie {fname} wav")
            time.sleep(0.5)
        prelude = "OAC = " + lit({"name": fname, "mode": rec, "spacing": spacing, "events": events, "expect": expect}) + "\n"
        raw = None
        try:
            raw = T.job("client", prelude + lua_src, timeout_s=int(len(events) * spacing * 12 + 120))
        finally:
            if rec == "engine":
                T.con("client", "endmovie")
        time.sleep(1.0)
        try:
            info = json.loads(raw) if isinstance(raw, str) else {"ok": False, "err": f"no result: {raw}"}
        except ValueError:
            info = {"ok": False, "err": f"bad result: {str(raw)[:300]}"}
        log[name] = info
        if not info.get("ok"):
            print(f"   FAIL {info.get('err')}", flush=True)
            continue
        dst = os.path.join(out, name + ".wav")
        if rec == "engine":
            found = sorted(glob.glob(tmp_prefix + "*.wav"), key=os.path.getmtime)
            if not found:
                print("   FAIL no startmovie file", flush=True)
                continue
            shutil.move(found[-1], dst)
        else:
            shutil.copyfile(info["capture"]["path"], dst)
        print(f"   recorded {dst}", flush=True)
    with open(os.path.join(out, "game_log.json"), "w", encoding="utf-8") as f:
        json.dump({"log": log, "labels": labels, "spacing": spacing}, f, indent=1)
    return analyze_dir(out, bool(opts.get("check")), "module", tuple(x for x in opts.get("expect-red", "").split(",") if x))


# --check: the module against the engine in open terrain, event by event (engine = reference, module = default settings).
# Limits: tail/direct within 3 dB and T20 within a factor 1.6 (reverb parity: nothing is muddied by the reverb in the open);
# spectral shape of the DIRECT window: the 2-6 kHz and 6-16 kHz bands within 3 dB of the engine's (about the smallest
# tilt heard as a change of timbre). Distances up to 1000 u: beyond, the air absorption is meant to take the treble.
CHECKS = {
    "reverb": lambda m, e: abs(m["tail_direct_db"] - e["tail_direct_db"]) <= 3 and 1 / 1.6 <= m["t20_s"] / e["t20_s"] <= 1.6,
    "treble": lambda m, e: abs(m["shape_db"][3] - e["shape_db"][3]) <= 3 and abs(m["shape_db"][2] - e["shape_db"][2]) <= 3,
}


def check(results, labels, cond="module", expect_red=()):
    ref, cur = results["engine"], results[cond]
    bad, rows = {k: [] for k in CHECKS}, 0
    for i, (lab, _, d) in enumerate(labels):
        m, e = cur["events"][i], ref["events"][i]
        if not m or not e or d > 1000:
            continue
        rows += 1
        for k, f in CHECKS.items():
            if not f(m, e):
                bad[k].append(lab)
    ok = True
    for k, lst in bad.items():
        red = bool(lst)
        tag = "RED" if red else "ok "
        print(f"{tag} {k}: {len(lst)}/{rows} events outside the limits" + (f" ({', '.join(lst[:6])}{' ...' if len(lst) > 6 else ''})" if lst else ""))
        if red and k not in expect_red:
            ok = False
        if not red and k in expect_red:
            ok = False
            print(f"FAIL {k} was expected red")
    return ok


def analyze_dir(out, do_check=False, cond="module", expect_red=()):
    meta = json.load(open(os.path.join(out, "game_log.json"), encoding="utf-8"))
    labels, spacing = [tuple(x) for x in meta["labels"]], meta["spacing"]
    results = {}
    for p in sorted(glob.glob(os.path.join(out, "*.wav"))):
        nm = os.path.splitext(os.path.basename(p))[0]
        evs = (meta["log"].get(nm) or {}).get("events")
        results[nm] = analyze_recording(p, len(labels), spacing, [e["t"] for e in evs] if evs and len(evs) == len(labels) else None)
    # engine first (the reference), then the module, then the rest
    order = sorted(results, key=lambda n: (n != "engine", n != "module", n))
    results = {n: results[n] for n in order}
    txt = report(results, labels)
    with open(os.path.join(out, "analysis.json"), "w", encoding="utf-8") as f:
        json.dump(results, f, indent=1)
    if do_check:
        return 0 if check(results, labels, cond, expect_red) else 1
    return 0


def main(argv):
    if "--selftest" in argv:
        return selftest()
    opts, pos = {}, []
    for a in argv:
        if a.startswith("--") and "=" in a:
            k, v = a[2:].split("=", 1)
            if k == "cond":
                opts.setdefault("cond", []).append(v)
            else:
                opts[k] = v
        elif a.startswith("--"):
            opts[a[2:]] = True
        else:
            pos.append(a)
    if opts.get("analyze"):
        return analyze_dir(pos[0], bool(opts.get("check")), opts.get("which", "module"), tuple(x for x in opts.get("expect-red", "").split(",") if x))
    if not pos:
        print(__doc__)
        return 2
    return run_game(pos[0], opts)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
