"""Own gunshots, engine against native module, measured end to end (phase 2 of the "own shots sound muffled" hunt).

The player hears his OWN AR2 shots (weapons/ar2/fire1.wav) duller with the native rendering than with the engine,
although the module's direct output equals the decoded file offline. This records what each path really sends to
the speakers and compares the recordings:
  engine_own0     pba_native_own 0: the engine plays the shots; its mix is recorded by `startmovie <name> wav`
  module_own1     pba_native_own 1: the module plays them; its FINAL output (after the limiter and the master
                  volume) is recorded by pba_native.CaptureStart / CaptureStop (feat/capture), the engine plays
                  nothing for them
  vanilla_enable0 pba_enable 0 (and pba_cl_enable 0): the addon is off, the engine plays them; startmovie
Each condition fires 5 single shots 0.5 s apart (one IN_ATTACK usercmd each, spaced in game time) from the same
spot, weapon_ar2 in hand, looking at the sky, on gm_construct in singleplayer.

Run on ONE light test instance (the coordinator launches it; MCP_INSTANCE=<id> if several run), with the module
built from feat/capture installed in garrysmod/lua/bin. Nothing here launches or closes the game.
The recordings: startmovie writes <name>.WAV next to the game's garrysmod folder files (moved to --out),
the module capture writes garrysmod/data/pba/<name>.wav (copied to --out).

Usage:
  python -I -X utf8 test/own_shot_capture.py <mcp.py> [--out=<dir>] [--gmod=<garrysmod dir>] [--map=gm_construct]
         [--shots=5] [--spacing=0.5] [--only=engine_own0,module_own1] [--cond=<name>:<engine|module>:<realm:cvar=value,...>]...
         (--pos=x,y,z and --ang=pitch,yaw,0 place the player (default: the spawn, looking at the sky);
         a --cond adds a condition: e.g. --cond=module_noreverb:module:cl:pba_native_reverb=0
          or --cond=module_nodirect:module:cl:pba_native_own_direct=0,cl:pba_native_limiter=2)
  python -I -X utf8 test/own_shot_capture.py --analyze [--shots=5] <label>=<file.wav> [<label>=<file.wav> ...]
         (offline: the first file is the reference the others are compared with)
  python -I -X utf8 test/own_shot_capture.py --selftest        (offline, synthetic recordings)
Uses numpy when it is installed (PBA_NO_NUMPY=1 forces the pure-Python path: slower, same numbers).

What is compared, per shot then averaged over the shots (aligned by onset, so the files may start at any time and
have any sample rate): peak (dBFS), the energy of the shot in 0-0.5 / 0.5-2 / 2-6 / 6-16 kHz and in third-octave
bands (dB, mean square of the two channels over the shot window), the same as a SHAPE (each band minus the total:
independent of the level, what "muffled" means), the energy of the first 20 ms (the attack), the spectral
centroid and the frequency under which 95 % of the energy lies, the L/R correlation, the sample rate, channels
and format of each file. The deltas are file minus reference.
"""
import glob
import json
import math
import os
import shutil
import struct
import sys
import time

try:
    if os.environ.get("PBA_NO_NUMPY"):
        raise ImportError
    import numpy as np
except ImportError:  # pure-Python fallback (an iterative FFT below)
    np = None

HERE = os.path.dirname(os.path.abspath(__file__))
GMOD_DEFAULT = r"D:\SteamLibrary\steamapps\common\GarrysMod\garrysmod"
BANDS = [(0, 500), (500, 2000), (2000, 6000), (6000, 16000)]
BAND_NAMES = ["0-0.5k", "0.5-2k", "2-6k", "6-16k"]
THIRDS = [100 * 2 ** (i / 3) for i in range(0, 22)]  # third-octave edges 100 Hz .. ~16 kHz
THIRD_BANDS = [(THIRDS[i], THIRDS[i + 1]) for i in range(len(THIRDS) - 1)]
WINDOW = 0.45   # s analysed from each onset (the shots are 0.5 s apart)
PRE = 0.003     # s kept before the onset
ATTACK = 0.020  # s
SPACING = 0.5   # s between the shots (--spacing)


# ------------------------------------------------------------------ wav reading / writing
def read_wav(path):
    """{rate, ch, bits, fmt, frames, l, r} (l / r float lists or arrays in [-1, 1]; a mono file gives r = l; with
    more than two channels the first two are kept). PCM 8 / 16 / 24 / 32 bit, float 32 / 64, WAVE_FORMAT_EXTENSIBLE."""
    with open(path, "rb") as f:
        b = f.read()
    if len(b) < 44 or b[:4] != b"RIFF" or b[8:12] != b"WAVE":
        raise ValueError(f"{path}: not a RIFF/WAVE file")
    pos, fmt, data = 12, None, None
    while pos + 8 <= len(b):
        tag, ln = b[pos:pos + 4], struct.unpack("<I", b[pos + 4:pos + 8])[0]
        body = pos + 8
        if tag == b"fmt ":
            tf, ch, rate, _, _, bits = struct.unpack("<HHIIHH", b[body:body + 16])
            if tf == 0xFFFE and ln >= 26:
                tf = struct.unpack("<H", b[body + 24:body + 26])[0]
            fmt = (tf, ch, rate, bits)
        elif tag == b"data":
            # (a movie writer may leave 0 / 0xFFFFFFFF in the header of a file it did not finish: take the rest)
            end = body + ln if 0 < ln <= len(b) - body else len(b)
            data = (body, end)
            break
        pos = body + ln + (ln & 1)
    if not fmt or not data:
        raise ValueError(f"{path}: no fmt/data chunk")
    tf, ch, rate, bits = fmt
    if tf not in (1, 3) or ch < 1:
        raise ValueError(f"{path}: unsupported format tag {tf} / {ch} channels")
    width = bits // 8
    n = (data[1] - data[0]) // (width * ch)
    raw = b[data[0]:data[0] + n * width * ch]
    if np is not None:
        if tf == 3:
            a = np.frombuffer(raw, dtype="<f4" if bits == 32 else "<f8").astype(np.float64)
        elif bits == 16:
            a = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768.0
        elif bits == 8:
            a = (np.frombuffer(raw, dtype="u1").astype(np.float64) - 128.0) / 128.0
        elif bits == 24:
            u = np.frombuffer(raw, dtype="u1").reshape(-1, 3).astype(np.int64)
            v = u[:, 0] | (u[:, 1] << 8) | (u[:, 2] << 16)
            a = np.where(v >= 1 << 23, v - (1 << 24), v).astype(np.float64) / (1 << 23)
        elif bits == 32:
            a = np.frombuffer(raw, dtype="<i4").astype(np.float64) / 2147483648.0
        else:
            raise ValueError(f"{path}: unsupported {bits}-bit PCM")
        a = a.reshape(-1, ch)
        l, r = a[:, 0], a[:, 1 if ch > 1 else 0]
    else:
        if tf == 3:
            vals = struct.unpack("<%d%s" % (n * ch, "f" if bits == 32 else "d"), raw)
        elif bits == 16:
            vals = [v / 32768.0 for v in struct.unpack("<%dh" % (n * ch), raw)]
        elif bits == 8:
            vals = [(v - 128) / 128.0 for v in raw]
        elif bits == 24:
            vals = []
            for i in range(0, len(raw), 3):
                v = raw[i] | (raw[i + 1] << 8) | (raw[i + 2] << 16)
                vals.append((v - (1 << 24) if v >= 1 << 23 else v) / float(1 << 23))
        elif bits == 32:
            vals = [v / 2147483648.0 for v in struct.unpack("<%di" % (n * ch), raw)]
        else:
            raise ValueError(f"{path}: unsupported {bits}-bit PCM")
        l = list(vals[0::ch])
        r = list(vals[1::ch]) if ch > 1 else l
    return {"path": path, "rate": rate, "ch": ch, "bits": bits, "fmt": "float" if tf == 3 else "pcm", "frames": n, "l": l, "r": r}


def write_wav(path, rate, l, r, bits=16, float_fmt=False):
    n = len(l)
    d = bytearray()
    for i in range(n):
        for v in (l[i], r[i]):
            if float_fmt:
                d += struct.pack("<f", v)
            elif bits == 16:
                d += struct.pack("<h", int(max(-1.0, min(1.0, v)) * 32767))
            elif bits == 24:
                q = int(max(-1.0, min(1.0, v)) * 8388607) & 0xFFFFFF
                d += struct.pack("<I", q)[:3]
    w = bits // 8
    hdr = b"RIFF" + struct.pack("<I", 36 + len(d)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 3 if float_fmt else 1, 2, rate, rate * 2 * w, 2 * w, bits)
    with open(path, "wb") as f:
        f.write(hdr + b"data" + struct.pack("<I", len(d)) + bytes(d))


# ------------------------------------------------------------------ small numeric helpers (numpy or pure)
def _seg(x, a, b):
    a, b = max(0, a), min(len(x), b)
    return x[a:b]


def _peak(x):
    return float(np.max(np.abs(x))) if np is not None else max((abs(v) for v in x), default=0.0)


def _sumsq(x):
    return float(np.dot(x, x)) if np is not None else sum(v * v for v in x)


def _corr(a, b):
    if len(a) < 2:
        return float("nan")
    if np is not None:
        if np.std(a) < 1e-12 or np.std(b) < 1e-12:
            return float("nan")
        return float(np.corrcoef(a, b)[0, 1])
    ma, mb = sum(a) / len(a), sum(b) / len(b)
    sa = sum((v - ma) ** 2 for v in a)
    sb = sum((v - mb) ** 2 for v in b)
    if sa < 1e-24 or sb < 1e-24:
        return float("nan")
    return sum((x - ma) * (y - mb) for x, y in zip(a, b)) / math.sqrt(sa * sb)


def _fft_power(x, nfft):
    """|X_k|^2 for k = 0..nfft/2 of x zero-padded to nfft (a power of two)."""
    if np is not None:
        return (np.abs(np.fft.rfft(np.asarray(x, dtype=np.float64), nfft)) ** 2).tolist()
    n = nfft
    re = [0.0] * n
    im = [0.0] * n
    # bit-reversed load
    bits = n.bit_length() - 1
    for i, v in enumerate(x):
        j = int(format(i, "0%db" % bits)[::-1], 2)
        re[j] = v
    size = 2
    while size <= n:
        half = size // 2
        ang = -2.0 * math.pi / size
        wr = [math.cos(ang * k) for k in range(half)]
        wi = [math.sin(ang * k) for k in range(half)]
        for start in range(0, n, size):
            for k in range(half):
                a, b = start + k, start + k + half
                tr = re[b] * wr[k] - im[b] * wi[k]
                ti = re[b] * wi[k] + im[b] * wr[k]
                re[b], im[b] = re[a] - tr, im[a] - ti
                re[a], im[a] = re[a] + tr, im[a] + ti
        size *= 2
    return [re[k] * re[k] + im[k] * im[k] for k in range(n // 2 + 1)]


def _db(p):
    return 10.0 * math.log10(max(p, 1e-30))


# ------------------------------------------------------------------ onsets
def find_onsets(w, shots, refractory=0.35):
    """Sample indices of the shots' onsets: the loudest 1 ms envelope window above 15 % of the global peak starts a
    shot (then 0.35 s of refractory time), refined back to the first sample above 4 % of that shot's own peak."""
    rate, l, r = w["rate"], w["l"], w["r"]
    hop = max(1, rate // 1000)
    n = len(l) // hop
    if n < 10:
        return []
    if np is not None:
        m = np.maximum(np.abs(l), np.abs(r))[: n * hop].reshape(n, hop).max(axis=1)
        env = m.tolist()
        mx = float(m.max())
    else:
        env = [max(max(abs(v) for v in l[i * hop:(i + 1) * hop]), max(abs(v) for v in r[i * hop:(i + 1) * hop])) for i in range(n)]
        mx = max(env)
    if mx <= 0:
        return []
    thr = 0.15 * mx
    cands, i, skip = [], 0, int(refractory * 1000)
    while i < n:
        # a shot RISES out of what came before it (the tail of the previous shot, which a louder or limited rendering keeps
        # above 15 % of the peak, is not a shot): the 8 ms before must stay under 35 % of this window
        if env[i] > thr and (i < 8 or max(env[i - 8:i]) < 0.35 * env[i]):
            a = max(0, i * hop - int(0.01 * rate))
            b = min(len(l), i * hop + int(0.05 * rate))
            pk = max(_peak(_seg(l, a, b)), _peak(_seg(r, a, b)))
            lim = 0.04 * pk
            j = a
            while j < b and abs(l[j]) < lim and abs(r[j]) < lim:
                j += 1
            cands.append(j)
            i += skip
        else:
            i += 1
    # the shots are SPACING apart: from the first onset, each next one is the candidate nearest to the previous + SPACING
    # (within 0.15 s); a stray event (an impact, an echo) in between is not counted as a shot
    out = []
    if cands:
        out.append(cands[0])
        for _ in range(shots - 1):
            want = out[-1] + SPACING * rate
            near = [c for c in cands if c > out[-1] + 0.2 * rate and abs(c - want) < 0.15 * rate]
            if not near:
                break
            out.append(min(near, key=lambda c: abs(c - want)))
        # (more candidates than shots after the last one: reported as found, the caller compares with the expected count)
        out += [c for c in cands if c > out[-1] + 0.2 * rate]
    return out


# ------------------------------------------------------------------ per-shot metrics
def shot_metrics(w, onset, window):
    rate = w["rate"]
    a = max(0, onset - int(PRE * rate))
    b = min(len(w["l"]), onset + int(window * rate))
    l, r = _seg(w["l"], a, b), _seg(w["r"], a, b)
    n = len(l)
    nfft = 1
    while nfft < n:
        nfft *= 2
    m = {"peak_db": _db(max(_peak(l), _peak(r)) ** 2), "rms_db": _db((_sumsq(l) + _sumsq(r)) / (2.0 * n)), "n": n}
    p = [x + y for x, y in zip(_fft_power(l, nfft), _fft_power(r, nfft))]  # both channels
    # Parseval: mean(x^2) over the n samples = sum_k |X_k|^2 / (nfft * n) over the full spectrum; the one-sided
    # spectrum counts twice (x 2) and the two channels are averaged (/ 2): scale = 1 / (nfft * n)
    scale = 1.0 / (nfft * n)
    df = rate / nfft

    def band(lo, hi):
        k0, k1 = int(math.ceil(lo / df)), int(math.ceil(hi / df))
        k1 = min(k1, len(p))
        return sum(p[k] for k in range(k0, k1)) * scale
    total = sum(p) * scale
    nyq = rate / 2.0
    bands = [band(lo, min(hi, nyq)) for lo, hi in BANDS]
    thirds = [band(lo, min(hi, nyq)) if lo < nyq else 1e-30 for lo, hi in THIRD_BANDS]
    m["total_db"] = _db(total)
    m["band_db"] = [_db(v) for v in bands]
    m["shape_db"] = [_db(v) - _db(total) for v in bands]
    m["third_db"] = [_db(v) for v in thirds]
    m["third_shape_db"] = [_db(v) - _db(total) for v in thirds]
    # centroid and the 95 % roll-off over 20 Hz - 20 kHz
    num = den = 0.0
    acc = []
    for k in range(1, len(p)):
        f = k * df
        if f > 20000:
            break
        num += f * p[k]
        den += p[k]
        acc.append((f, den))
    m["centroid_hz"] = num / den if den > 0 else 0.0
    m["rolloff95_hz"] = next((f for f, c in acc if c >= 0.95 * den), 0.0) if den > 0 else 0.0
    # attack: energy of the first 20 ms from the onset, both channels, in energy-per-second units (sum x^2 / rate)
    s = max(0, onset - a)
    e = int(ATTACK * rate)
    m["attack_db"] = _db((_sumsq(_seg(l, s, s + e)) + _sumsq(_seg(r, s, s + e))) / rate)
    m["corr"] = _corr(l, r)
    return m


def analyze_file(path, shots, label=None):
    w = read_wav(path)
    on = find_onsets(w, shots)
    res = {"label": label or os.path.basename(path), "path": path, "rate": w["rate"], "channels": w["ch"], "bits": w["bits"],
           "format": w["fmt"], "seconds": round(w["frames"] / w["rate"], 3), "peak_dbfs": round(_db(max(_peak(w["l"]), _peak(w["r"])) ** 2), 2),
           "onsets_found": len(on), "onsets_s": [round(o / w["rate"], 4) for o in on], "shots": []}
    if len(on) >= 2:
        gap = min(b - a for a, b in zip(on, on[1:])) / w["rate"]
    else:
        gap = WINDOW + 0.05
    window = min(WINDOW, gap - 0.03)
    res["window_s"] = round(window, 3)
    for o in on[:shots]:
        res["shots"].append(shot_metrics(w, o, window))
    res["mean"] = mean_metrics(res["shots"])
    return res


def _mean(vals):
    vals = [v for v in vals if v == v]
    return sum(vals) / len(vals) if vals else float("nan")


def _std(vals):
    vals = [v for v in vals if v == v]
    if len(vals) < 2:
        return 0.0
    m = sum(vals) / len(vals)
    return math.sqrt(sum((v - m) ** 2 for v in vals) / (len(vals) - 1))


def mean_metrics(shots):
    if not shots:
        return {}
    out = {}
    for k in ("peak_db", "rms_db", "total_db", "attack_db", "centroid_hz", "rolloff95_hz", "corr"):
        out[k] = _mean([s[k] for s in shots])
    for k in ("band_db", "shape_db", "third_db", "third_shape_db"):
        out[k] = [_mean([s[k][i] for s in shots]) for i in range(len(shots[0][k]))]
    out["peak_std_db"] = _std([s["peak_db"] for s in shots])
    out["total_std_db"] = _std([s["total_db"] for s in shots])
    return out


# ------------------------------------------------------------------ comparison / report
def compare(ref, other):
    a, b = ref["mean"], other["mean"]
    if not a or not b:
        return {"error": "no shot found in " + (ref["label"] if not a else other["label"])}
    d = {k: round(b[k] - a[k], 2) for k in ("peak_db", "rms_db", "total_db", "attack_db")}
    d["centroid_ratio"] = round(b["centroid_hz"] / a["centroid_hz"], 3) if a["centroid_hz"] else None
    d["rolloff95_hz"] = [round(a["rolloff95_hz"]), round(b["rolloff95_hz"])]
    d["corr"] = [round(a["corr"], 3), round(b["corr"], 3)]
    d["band_db"] = {n: round(b["band_db"][i] - a["band_db"][i], 2) for i, n in enumerate(BAND_NAMES)}
    d["shape_db"] = {n: round(b["shape_db"][i] - a["shape_db"][i], 2) for i, n in enumerate(BAND_NAMES)}
    d["third_db"] = {"%d" % round(math.sqrt(lo * hi)): round(b["third_db"][i] - a["third_db"][i], 1) for i, (lo, hi) in enumerate(THIRD_BANDS)}
    d["onsets_found"] = [ref["onsets_found"], other["onsets_found"]]
    d["rates_hz"] = [ref["rate"], other["rate"]]
    return d


def report(results, shots):
    """Prints the tables; returns (text-free) a verdict dict."""
    ref = results[0]
    lines = []
    ap = lines.append
    ap("== files")
    for r in results:
        ap(f"  {r['label']:<18} {r['rate']} Hz, {r['channels']} ch, {r['bits']}-bit {r['format']}, {r['seconds']} s, peak {r['peak_dbfs']} dBFS, "
           f"{r['onsets_found']} onsets (expected {shots}) at {r['onsets_s']}")
    ap("== per shot, mean over the shots (peak dBFS | total dB | attack 20 ms dB | centroid Hz | rolloff95 Hz | L/R corr | peak spread dB)")
    for r in results:
        m = r["mean"]
        if not m:
            ap(f"  {r['label']:<18} NO SHOT FOUND")
            continue
        ap(f"  {r['label']:<18} {m['peak_db']:7.2f} | {m['total_db']:7.2f} | {m['attack_db']:7.2f} | {m['centroid_hz']:7.0f} | {m['rolloff95_hz']:6.0f} | {m['corr']:6.3f} | {m['peak_std_db']:.2f}")
    ap("== band energy, dB (mean square of the shot window): " + " | ".join(BAND_NAMES))
    for r in results:
        if r["mean"]:
            ap(f"  {r['label']:<18} " + " | ".join(f"{v:7.2f}" for v in r["mean"]["band_db"]))
    ap("== band SHAPE, dB below the shot's total (level independent): " + " | ".join(BAND_NAMES))
    for r in results:
        if r["mean"]:
            ap(f"  {r['label']:<18} " + " | ".join(f"{v:7.2f}" for v in r["mean"]["shape_db"]))
    verdict = {}
    for r in results[1:]:
        c = compare(ref, r)
        verdict[r["label"]] = c
        if "error" in c:
            ap(f"== {r['label']} vs {ref['label']}: {c['error']}")
            continue
        ap(f"== {r['label']} minus {ref['label']}")
        ap(f"  level: peak {c['peak_db']:+.2f} dB, total {c['total_db']:+.2f} dB, attack(20 ms) {c['attack_db']:+.2f} dB; centroid x{c['centroid_ratio']}; "
           f"rolloff95 {c['rolloff95_hz'][0]} -> {c['rolloff95_hz'][1]} Hz; L/R corr {c['corr'][0]} -> {c['corr'][1]}")
        ap("  bands (absolute): " + ", ".join(f"{k} {v:+.2f}" for k, v in c["band_db"].items()))
        ap("  bands (shape, level removed): " + ", ".join(f"{k} {v:+.2f}" for k, v in c["shape_db"].items()))
        ap("  third octaves (Hz: dB): " + ", ".join(f"{k}: {v:+.1f}" for k, v in c["third_db"].items()))
        dull = c["shape_db"]["6-16k"] < -1.5 or c["shape_db"]["2-6k"] < -1.5
        ap("  => " + ("DULLER than the reference in the treble (shape 2-6k / 6-16k more than 1.5 dB lower)" if dull else
                      "no treble loss in the shape (within 1.5 dB)") + (f"; but {c['total_db']:+.1f} dB overall" if abs(c["total_db"]) > 1.5 else ""))
    print("\n".join(lines), flush=True)
    return verdict


def analyze_paths(items, shots):
    results = []
    for it in items:
        label, _, path = it.partition("=")
        if not path:
            label, path = os.path.splitext(os.path.basename(it))[0], it
        results.append(analyze_file(path, shots, label))
    verdict = report(results, shots)
    return results, verdict


# ------------------------------------------------------------------ offline self test
def _synth_shots(rate, shots, lowpass_hz=None, gain=1.0, seed=3, start=0.6, spacing=0.5, stereo_decorr=True, secs=4.0):
    import random
    rng = random.Random(seed)
    n = int(secs * rate)
    l, r = [0.0] * n, [0.0] * n
    # the same noise for every shot (one sample file), decorrelated between the channels
    ln = int(0.4 * rate)
    nl = [rng.uniform(-1, 1) for _ in range(ln)]
    nr = [rng.uniform(-1, 1) for _ in range(ln)] if stereo_decorr else nl
    for k in range(shots):
        s = int((start + k * spacing) * rate)
        for i in range(ln):
            env = math.exp(-i / (0.06 * rate)) * (1.0 if i > 4 else i / 5.0)
            if s + i < n:
                l[s + i] += 0.6 * env * nl[i] * gain
                r[s + i] += 0.6 * env * nr[i] * gain
    if lowpass_hz:
        a = 1 - math.exp(-2 * math.pi * lowpass_hz / rate)
        for ch in (l, r):
            y = 0.0
            for i in range(n):
                y += a * (ch[i] - y)
                ch[i] = y
    return l, r


def selftest():
    import tempfile
    fails = []

    def check(ok, what):
        print(("ok   " if ok else "FAIL ") + what, flush=True)
        if not ok:
            fails.append(what)
    d = tempfile.mkdtemp(prefix="osc_selftest_")
    print(f"selftest ({'numpy' if np is not None else 'pure python'}), files in {d}")
    # engine: 44.1 kHz int16, shots at 0.6 + k * 0.5; "module": 48 kHz float, dull (1 kHz one-pole), half the level,
    # started 0.17 s later; "same": 48 kHz float, identical content but another start time and level
    l1, r1 = _synth_shots(44100, 5, None, 1.0)
    write_wav(os.path.join(d, "engine.wav"), 44100, l1, r1, 16)
    l2, r2 = _synth_shots(48000, 5, 1000.0, 0.5, start=0.77)
    write_wav(os.path.join(d, "dull.wav"), 48000, l2, r2, 32, float_fmt=True)
    l3, r3 = _synth_shots(48000, 5, None, 0.5, start=0.33)
    write_wav(os.path.join(d, "same24.wav"), 48000, l3, r3, 24)
    res, verdict = analyze_paths([f"engine={d}/engine.wav", f"dull={d}/dull.wav", f"same={d}/same24.wav"], 5)
    e, du, sm = res
    check(e["rate"] == 44100 and e["bits"] == 16 and e["format"] == "pcm", "reads 44.1 kHz int16")
    check(du["rate"] == 48000 and du["bits"] == 32 and du["format"] == "float", "reads 48 kHz float32")
    check(sm["bits"] == 24, "reads 24-bit PCM")
    for r_, st in ((e, 0.6), (du, 0.77), (sm, 0.33)):
        ok = r_["onsets_found"] == 5 and all(abs(o - (st + 0.5 * k)) < 0.004 for k, o in enumerate(r_["onsets_s"]))
        check(ok, f"{r_['label']}: 5 onsets within 4 ms of the truth ({r_['onsets_s']})")
    vd, vs = verdict["dull"], verdict["same"]
    check(vd["shape_db"]["6-16k"] < -5 and vd["band_db"]["6-16k"] < -20, f"dull: 6-16 kHz at least 20 dB lower, 5 dB lower in shape ({vd['band_db']['6-16k']}, {vd['shape_db']['6-16k']})")
    check(vd["centroid_ratio"] < 0.5, f"dull: centroid ratio < 0.5 ({vd['centroid_ratio']})")
    check(abs(vs["peak_db"] + 6.02) < 0.6 and abs(vs["total_db"] + 6.02) < 0.3, f"same content at half level: -6 dB (peak {vs['peak_db']}, total {vs['total_db']})")
    # (another sample rate = another noise realisation: the 0-0.5 kHz band holds few bins, 1.5 dB of scatter)
    check(all(abs(v) < 1.5 for v in vs["shape_db"].values()), f"same content: shape unchanged within 1.5 dB ({vs['shape_db']})")
    check(abs(vs["attack_db"] + 6.02) < 0.8, f"same content: attack energy -6 dB ({vs['attack_db']})")
    check(abs(e["mean"]["corr"]) < 0.1, f"decorrelated channels: corr ~ 0 ({e['mean']['corr']:.3f})")
    # a mono-in-both-channels file has corr 1
    l4, r4 = _synth_shots(48000, 5, None, 1.0, stereo_decorr=False)
    write_wav(os.path.join(d, "mono.wav"), 48000, l4, r4, 16)
    mo = analyze_file(os.path.join(d, "mono.wav"), 5)
    check(mo["mean"]["corr"] > 0.999, f"identical channels: corr 1 ({mo['mean']['corr']:.4f})")
    # fewer shots than expected is reported, not hidden
    l5, r5 = _synth_shots(48000, 3, None, 1.0)
    write_wav(os.path.join(d, "three.wav"), 48000, l5, r5, 16)
    th = analyze_file(os.path.join(d, "three.wav"), 5)
    check(th["onsets_found"] == 3, "3 shots in the file: 3 onsets found, no invented shot")
    shutil.rmtree(d, ignore_errors=True)
    print("SELFTEST " + ("FAILED: " + "; ".join(fails) if fails else "PASS"))
    return 1 if fails else 0


# ------------------------------------------------------------------ in game (phase 2)
DEFAULT_CONDS = [
    ("engine_own0", "engine", [("cl", "pba_native_own", "0")]),
    ("module_own1", "module", [("cl", "pba_native_own", "1")]),
    ("vanilla_enable0", "engine", [("sv", "pba_enable", "0"), ("cl", "pba_cl_enable", "0")]),
]
BASELINE = [("sv", "pba_enable", "1"), ("cl", "pba_cl_enable", "1"), ("cl", "pba_native_render", "1"), ("cl", "pba_native_all", "1")]


def parse_cond(spec):
    name, rec, rest = spec.split(":", 2)
    if rec not in ("engine", "module", "both"):
        raise SystemExit(f"--cond {name}: recording must be engine, module or both (both: the module capture AND startmovie, to hear whether the engine still plays a copy)")
    cv = []
    for part in rest.split(","):
        realm, _, nv = part.partition(":")
        n, _, v = nv.partition("=")
        if realm not in ("cl", "sv") or not n or v == "":
            raise SystemExit(f"--cond {name}: '{part}' is not <cl|sv>:<cvar>=<value>")
        cv.append((realm, n, v))
    return name, rec, cv


def run_game(mcp, opts):
    sys.path.insert(0, HERE)
    from _coretest import Core
    T = Core(mcp)
    gmod = opts.get("gmod", GMOD_DEFAULT)
    out = opts.get("out") or os.path.join(os.environ.get("TEMP", "."), "pba_own_shots_" + time.strftime("%Y%m%d_%H%M%S"))
    os.makedirs(out, exist_ok=True)
    shots, spacing = int(opts.get("shots", 5)), float(opts.get("spacing", 0.5))
    globals()["SPACING"] = spacing
    conds = list(DEFAULT_CONDS)
    for c in opts.get("cond", []):
        conds.append(parse_cond(c))
    if "only" in opts:
        keep = opts["only"].split(",")
        conds = [c for c in conds if c[0] in keep]
    T.load(opts.get("map", "gm_construct"), mp=1)
    # the module must be the one with the capture, or phase 2 is pointless
    has = T.lua("client", "return pba_native ~= nil and pba_native.CaptureStart ~= nil")
    if has is not True and any(c[1] in ("module", "both") for c in conds):
        print("FAIL pba_native.CaptureStart missing: install the module built from feat/capture in garrysmod/lua/bin and restart the game "
              "(see the build commands); not touching the game from here")
        return 1
    print(f"module {T.lua('client', 'return tostring(pba_native and pba_native.ModuleVersion and pba_native.ModuleVersion())')}, "
          f"conditions: {[c[0] for c in conds]}, recordings in {out}", flush=True)
    # the player: weapon_ar2, ammo, godmode, still, looking at the sky (no impact sound)
    T.lua("server", "local p = player.GetHumans()[1] p:GodEnable() p:StripWeapons() p:Give('weapon_ar2') p:SetAmmo(900, 'AR2') p:SelectWeapon('weapon_ar2') "
                    "%s p:SetEyeAngles(Angle(%s)) p:SetVelocity(-p:GetVelocity()) return true" % (
                        ("p:SetPos(Vector(%s))" % opts["pos"]) if opts.get("pos") else "", opts.get("ang", "-80, 0, 0")))
    time.sleep(2.5)
    lua_src = open(os.path.join(HERE, "own_shot_capture.lua"), encoding="utf-8").read()
    files, report_rows, failures = [], {}, []
    for name, rec, cvars in conds:
        print(f"-- {name} ({rec})", flush=True)
        for realm, n, v in BASELINE + cvars:
            T.con({"cl": "client", "sv": "server"}[realm], f"{n} {v}")
        T.lua("client", "RunConsoleCommand('stopsound') return true")
        T.lua("server", "local w = player.GetHumans()[1]:GetWeapon('weapon_ar2') if IsValid(w) then w:SetClip1(30) end return true")
        time.sleep(2.5)  # settings applied (the userinfo of pba_native_own follows on a 0.5 s timer), tails of the previous run gone
        expect = {n: v for realm, n, v in BASELINE + cvars if n.startswith("pba_native_own") or n in ("pba_enable", "pba_cl_enable")}
        fname = f"osc_{name}"
        tmp_prefix = os.path.join(gmod, fname)
        if rec in ("engine", "both"):
            for old in glob.glob(tmp_prefix + "*.wav"):
                os.remove(old)
            T.con("client", f"startmovie {fname} wav")
            time.sleep(0.5)
        prelude = "OSC = %s\n" % ("{ name = %r, mode = %r, shots = %d, spacing = %g, expect = { %s } }" % (
            fname, "module" if rec == "both" else rec, shots, spacing, ", ".join(f"{k} = {v}" for k, v in expect.items())))
        raw = None
        try:
            raw = T.job("client", prelude + lua_src, timeout_s=int(shots * spacing * 40 + 90))
        finally:
            if rec in ("engine", "both"):
                T.con("client", "endmovie")
        time.sleep(1.0)
        try:
            info = json.loads(raw) if isinstance(raw, str) else {"ok": False, "err": f"no result: {raw}"}
        except ValueError:
            info = {"ok": False, "err": f"bad result: {str(raw)[:300]}"}
        report_rows[name] = info
        if not info.get("ok"):
            failures.append(f"{name}: {info.get('err')}")
            print(f"   FAIL {info.get('err')}", flush=True)
            continue
        if rec in ("engine", "both"):
            found = sorted(glob.glob(tmp_prefix + "*.wav"), key=os.path.getmtime)
            if not found:
                failures.append(f"{name}: no {fname}*.wav written in {gmod} (startmovie ... wav refused? check the console)")
                print("   FAIL " + failures[-1], flush=True)
                continue
            dst = os.path.join(out, name + (".wav" if rec == "engine" else "_engine.wav"))
            shutil.move(found[-1], dst)
            if rec == "both":
                files.append(f"{name}_engine={dst}")
        if rec != "engine":
            src = info["capture"]["path"]
            dst = os.path.join(out, name + ".wav")
            shutil.copyfile(src, dst)
            if info["ownPlays"] != shots:
                failures.append(f"{name}: the module played {info['ownPlays']} own AR2 voices, expected {shots} (the measure is not of the module's own shots)")
        files.append(f"{name}={dst}")
        print(f"   recorded {dst}; module plays {len(info['plays'])} (own {info.get('ownPlays')}), engine emits {len(info['emits'])}, cvars {info['cvars']}", flush=True)
    with open(os.path.join(out, "game_log.json"), "w", encoding="utf-8") as f:
        json.dump(report_rows, f, indent=1)
    if files:
        results, verdict = analyze_paths(files, shots)
        with open(os.path.join(out, "analysis.json"), "w", encoding="utf-8") as f:
            json.dump({"results": results, "verdict": verdict}, f, indent=1)
        for r in results:
            if r["onsets_found"] != shots:
                failures.append(f"{r['label']}: {r['onsets_found']} shots found in the recording, expected {shots}")
    for f_ in failures:
        print("FAIL " + f_)
    print(json.dumps({"out": out, "pass": not failures, "failures": failures}))
    return 1 if failures else 0


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
        if len(pos) < 2:
            print("usage: --analyze <reference.wav> <other.wav> [...]   (label=file.wav accepted)")
            return 2
        analyze_paths(pos, int(opts.get("shots", 5)))
        return 0
    if not pos:
        print(__doc__)
        return 2
    return run_game(pos[0], opts)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
