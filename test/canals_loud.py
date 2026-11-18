"""d1_canals_01: the loudest sounds of the map piled on the listener (Workshop report "audio punching the microphone").

The pile (test/canals_loud.lua): the razor train's horn (level 130), the train brake (100), an explosion (140) and two weapon
reports (105), each 100 u from the listener in its own direction, played at once by the module. Same pile at volume x 0.25
(the linear reference: far under any limiter) and x 1 (the real thing), per output stage (pba_native_limiter: 1 lookahead
limiter = default, 0 legacy soft clip, 2 hard clip; stage 3 = the 1.2 order, the soft clip acting after the master volume). What is judged is the module's FINAL output (CaptureStart,
before the master volume is taken off again):
  peak          largest |sample| of either channel (pre-master, i.e. divided by the master volume convar)
  flat          flat tops: runs of 3 or more consecutive samples at 0.99 or over, either channel (what a hard clip, or a soft
                clip that ends in a clamp, leaves: the "punching the mic" crackle; a limiter's ceiling is touched by single
                samples only)
  ref_peak      peak of the x 0.25 reference times 4: what the pile WOULD peak at without any output stage. The run must
                be hot (>= REF_HOT) or it proves nothing: a pile that never reaches the stage passes every stage
Verdict (default stage): ref_peak >= REF_HOT, peak <= CEILING, flat <= FLAT_MAX.
Usage (ONE test instance; MCP_INSTANCE=<id> if several run; the driver loads d1_canals_01 and restores the pba_* convars):
  python -I -X utf8 test/canals_loud.py <mcp.py> [--map=d1_canals_01] [--dist=100] [--expect-red=0,2,3] [--out=<dir>]
  python -I -X utf8 test/canals_loud.py --selftest
"""
import json
import os
import sys
import tempfile
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from own_shot_capture import read_wav  # noqa: E402

REF_HOT = 1.5     # the pile must exceed full scale by this factor in the linear reference (measured 3.8 on d1_canals_01)
CEILING = 0.985   # the limiter's ceiling is 0.98
FLAT_MAX = 20     # flat tops over the 3 s window (measured: limiter 0, soft clip 3510, hard clip 5661)
STAGES = {1: "limiter (default)", 0: "soft clip", 2: "hard clip", 3: "1.2: soft clip, after volume"}


def onset(x, thr=0.02):
    pk = float(np.max(np.abs(x))) if len(x) else 0
    return int(np.argmax(np.abs(x) >= pk * thr)) if pk > 0 else 0


def flat_tops(x, thr=0.99, run=3):
    n = 0
    for c in x:
        hot = (np.abs(c) >= thr).astype(np.int32)
        n += int((np.convolve(hot, np.ones(run, np.int32), "valid") == run).sum())
    return n


def analyse(real, ref, volume, sr):
    """real / ref: (2, n) arrays (L, R) of the pile at x 1 and x 0.25, after the master volume."""
    a, b = real / volume, 4.0 * ref / volume
    ia, ib = onset(a[0] + a[1]), onset(b[0] + b[1])
    n = min(a.shape[1] - ia, b.shape[1] - ib, int(sr * 3.0))
    a, b = a[:, ia:ia + n], b[:, ib:ib + n]
    rms_a, rms_b = float(np.sqrt(np.mean(a * a))), float(np.sqrt(np.mean(b * b)))
    return {
        "peak": float(np.max(np.abs(a))),
        "ref_peak": float(np.max(np.abs(b))),
        "flat": flat_tops(a),
        "gain_db": 20 * np.log10(max(rms_a, 1e-12) / max(rms_b, 1e-12)),
    }


def judge(m):
    bad = []
    if m["ref_peak"] < REF_HOT:
        bad.append("pile not hot enough (reference x4 peak %.2f < %.2f): proves nothing" % (m["ref_peak"], REF_HOT))
    if m["peak"] > CEILING:
        bad.append("peak %.3f > %.3f" % (m["peak"], CEILING))
    if m["flat"] > FLAT_MAX:
        bad.append("%d flat tops > %d" % (m["flat"], FLAT_MAX))
    return bad


def selftest():
    sr = 48000
    t = np.arange(sr * 4) / sr
    rng = np.random.default_rng(1)
    base = 0.3 * np.sin(2 * np.pi * 220 * t) + 0.08 * rng.standard_normal(len(t)) * (np.sin(2 * np.pi * 3 * t) > 0)
    stereo = lambda x: np.vstack([x, 0.7 * x])
    vol = 0.16
    ref = stereo(base * vol)  # the x 0.25 run: a quarter of the x 4 pile
    big = stereo(base * 4.0)
    # a smooth, slowly moving gain (what a limiter does): under 1, same waveform
    gain = 0.35 + 0.05 * np.sin(2 * np.pi * 0.5 * t)
    limited = big * gain
    soft = np.clip(np.tanh(big * 1.2) * 1.05, -1, 1)
    hard = np.clip(big, -1, 1)
    fails = 0
    for name, sig, expect_red in (("gain-only", limited, False), ("soft clip + clamp", soft, True), ("hard clip", hard, True)):
        m = analyse(sig * vol, ref, vol, sr)
        bad = judge(m)
        ok = bool(bad) == expect_red
        print(("ok  " if ok else "FAIL"), "selftest", name, {k: round(v, 2) for k, v in m.items()}, bad)
        fails += 0 if ok else 1
    print("FAIL selftest" if fails else "PASS selftest")
    return 1 if fails else 0


def run_game(mcp, opts):
    from _coretest import Core
    import _cvsnap
    T = Core(mcp)
    _cvsnap.guard(T.call)
    out = opts.get("out") or tempfile.mkdtemp(prefix="pba_canals_loud_")
    os.makedirs(out, exist_ok=True)
    T.load(opts.get("map", "d1_canals_01"), mp=1)
    T.lua("server", "local p = player.GetHumans()[1] p:GodEnable() p:StripWeapons() return true")
    time.sleep(3.0)
    runs = [{"name": "cl_ref_l1", "limiter": 1, "scale": 0.25}]
    for st in (1, 0, 2, 3):
        # stage 3 = what 1.2 had: the legacy soft clip acting AFTER the master volume (never reached at volume 0.16)
        runs.append({"name": "cl_pile_l%d" % st, "limiter": 0 if st == 3 else st, "pre": 0 if st == 3 else 1, "scale": 1.0})
    lua_runs = ",".join('{name="%s",limiter=%d,pre=%d,scale=%s}' % (r["name"], r["limiter"], r["pre"] if "pre" in r else 1, r["scale"]) for r in runs)
    raw = T.job("client", "CL = {runs={%s},dist=%d}\n" % (lua_runs, int(opts.get("dist", 100)))
                + open(os.path.join(HERE, "canals_loud.lua"), encoding="utf-8").read(), timeout_s=240)
    info = json.loads(raw) if isinstance(raw, str) else {"ok": False, "err": str(raw)}
    if not info.get("ok"):
        print("FAIL capture:", info.get("err"))
        return 1
    gmod = opts.get("gmod", r"D:\SteamLibrary\steamapps\common\GarrysMod\garrysmod")
    vol = float(info["volume"])
    paths = {r["name"]: r["path"] for r in info["runs"]}
    ref = read_wav(paths["cl_ref_l1"])
    sr = ref["rate"]
    ref_s = np.vstack([np.asarray(ref["l"]), np.asarray(ref["r"])])
    results, bad_default = {}, []
    for st in (1, 0, 2, 3):
        w = read_wav(paths["cl_pile_l%d" % st])
        m = analyse(np.vstack([np.asarray(w["l"]), np.asarray(w["r"])]), ref_s, vol, sr)
        results[st] = m
        bad = judge(m)
        print("limiter %d %-18s peak %.3f  flat tops %5d  (linear pile peak %.2f)  gain %+.1f dB  %s" % (
            st, STAGES[st], m["peak"], m["flat"], m["ref_peak"], m["gain_db"], "RED " + "; ".join(bad) if bad else "ok"), flush=True)
        if st == 1:
            bad_default = bad
    expect_red = [int(x) for x in opts.get("expect-red", "").split(",") if x != ""]
    ok = not bad_default
    for st in expect_red:
        if not judge(results[st]):
            ok = False
            print("FAIL stage %d was expected red" % st)
    json.dump({"volume": vol, "results": {str(k): v for k, v in results.items()}}, open(os.path.join(out, "canals_loud.json"), "w"), indent=1)
    print(json.dumps({"pass": ok, "default_bad": bad_default, "results": {str(k): {a: round(b, 3) for a, b in v.items()} for k, v in results.items()}}))
    return 0 if ok else 1


def main(argv):
    if "--selftest" in argv:
        return selftest()
    args = [a for a in argv if not a.startswith("--")]
    opts = {}
    for a in argv:
        if a.startswith("--") and "=" in a:
            k, _, v = a[2:].partition("=")
            opts[k] = v
    if not args:
        print(__doc__)
        return 2
    return run_game(args[0], opts)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
