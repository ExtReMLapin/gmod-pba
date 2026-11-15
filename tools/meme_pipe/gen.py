"""Synthesizes the metal pipe sounds (sound/pba/pipe/<tier>_<n>.wav) from params.json.

A struck steel tube, by modal synthesis: a sum of exponentially decaying sinusoids (frequency, decay time,
amplitude, phase per mode) plus a short filtered-noise strike transient. A tier (hard / medium / soft) is a
harder or softer strike: its own gain, a spectral tilt (dB per octave: a soft strike excites the high modes
less) and its own strike transient. A variant is a different strike position on the tube: seeded per-mode
amplitude changes and a slight detune.

Everything is deterministic from params.json (numpy only, no target needed). params.json is what
tools/meme_pipe/fit.py optimizes; this file and fit.py share the model (model_numpy here, the same maths in torch there,
checked equal by `python fit.py --selftest`).

Usage:  python gen.py [--params params.json] [--out ../../sound/pba/pipe] [--check]
        (--check: prints the peak / duration of every file and fails if a file clips)
"""
import argparse
import json
import os
import struct
import sys
import wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
TIERS = ("hard", "medium", "soft")


def variant_draws(p, tier, var, n_modes):
    """Seeded draws of one (tier, variant): per-mode amplitude jitter (dB) and detune (ratio), the strike noise."""
    v = p["variants"]
    # jitter and detune belong to the variant (the strike position): the same for every tier, only the force differs
    rng = np.random.RandomState(int(v["seed"]) * 1000 + var)
    jit = rng.randn(n_modes) * float(v["amp_jitter_db"])
    det = rng.randn(n_modes) * float(v["detune"])
    seed = int(v["seed"]) * 1000 + TIERS.index(tier) * 100 + var
    noise = np.random.RandomState(seed + 7).randn(int(p["noise_len"]))
    return jit, det, noise


def bed_noise(p, var, N, fs):
    """[K, N] seeded white noise shaped by K triangular (log-frequency) windows centred on the bed's knots."""
    kn = np.array(p["bed"]["knots_hz"], dtype=np.float64)
    NB = int(4.1 * fs)  # always drawn at this length, then cut: every length shares the same noise
    rng = np.random.RandomState(int(p["variants"]["seed"]) * 1000 + 500 + var)
    X = np.fft.rfft(rng.randn(NB))
    fr = np.fft.rfftfreq(NB, 1.0 / fs)
    lf = np.log2(np.maximum(fr, 1.0))
    lk = np.log2(kn)
    out = np.zeros((len(kn), NB))
    for k in range(len(kn)):
        lo = lk[k - 1] if k > 0 else lk[k] - 1.0
        hi = lk[k + 1] if k < len(kn) - 1 else lk[k] + 1.0
        w = np.where(lf < lk[k], (lf - lo) / (lk[k] - lo), (hi - lf) / (hi - lk[k]))
        w = np.clip(w, 0.0, 1.0)
        out[k] = np.fft.irfft(X * w, NB)
    return out[:, :N]


def mode_arrays(p):
    m = p["modes"]
    f = np.array([x["f"] for x in m], dtype=np.float64)
    tau = np.array([x["tau"] for x in m], dtype=np.float64)
    a = np.array([x["a"] for x in m], dtype=np.float64)
    ph = np.array([x["phase"] for x in m], dtype=np.float64)
    return f, tau, a, ph


def render(p, tier, var, fs, length=None, pitch=1.0):
    """One dry sound (float64 array). pitch: playback ratio (the game's EmitSound pitch / 100)."""
    f, tau, a, ph = mode_arrays(p)
    n = len(f)
    t_cfg = p["tiers"][tier]
    length = float(length if length is not None else t_cfg["length_s"])
    N = int(round(length * fs))
    t = np.arange(N) / fs
    jit, det, noise = variant_draws(p, tier, var, n)
    fi = f * (1.0 + det) * pitch
    tilt = 10.0 ** (-t_cfg["tilt_db_oct"] * np.log2(np.maximum(f, 20.0) / 1000.0) / 20.0)
    amp = a * t_cfg["gain"] * tilt * 10.0 ** (jit / 20.0)
    amp = np.where(fi < 0.45 * fs, amp, 0.0)  # nothing above Nyquist
    y = np.zeros(N)
    # chunks of modes, to keep memory bounded
    for s in range(0, n, 16):
        sl = slice(s, s + 16)
        y += (amp[sl, None] * np.exp(-t[None, :] / (tau[sl, None] / pitch)) * np.sin(2 * np.pi * fi[sl, None] * t[None, :] + ph[sl, None])).sum(0)
    # the diffuse bed: a swarm of unresolved modes, noise in K bands, each with its own level and decay
    bed = p["bed"]
    bn = bed_noise(p, var, N, fs)
    kn = np.array(bed["knots_hz"], dtype=np.float64)
    bg = np.array(bed["gain"], dtype=np.float64) * t_cfg["gain"] * 10.0 ** (-t_cfg["tilt_db_oct"] * np.log2(kn / 1000.0) / 20.0)
    bt = np.array(bed["tau"], dtype=np.float64)
    y += (bg[:, None] * np.exp(-t[None, :] / (bt[:, None] / pitch)) * bn).sum(0)
    # strike transient: seeded white noise, one-pole-like lowpass (zero phase, in the frequency domain), exponential envelope
    nl = int(p["noise_len"])
    X = np.fft.rfft(noise)
    fr = np.fft.rfftfreq(nl, 1.0 / fs)
    X *= 1.0 / np.sqrt(1.0 + (fr / t_cfg["strike_lp_hz"]) ** 2)
    nz = np.fft.irfft(X, nl)
    nz = nz / (np.sqrt(np.mean(nz ** 2)) + 1e-12)
    ne = min(nl, N)
    env = np.exp(-t[:ne] / (t_cfg["strike_tau_ms"] * 1e-3))
    y[:ne] += t_cfg["strike_gain"] * nz[:ne] * env
    # fades: 1 ms in (no click), the tail out over tail_fade_ms
    fi_n = max(1, int(0.001 * fs))
    y[:fi_n] *= np.linspace(0, 1, fi_n)
    fo = max(1, int(p["tail_fade_ms"] * 1e-3 * fs))
    y[-fo:] *= np.linspace(1, 0, fo)
    return y * float(p["master_gain"])


def write_wav(path, y, fs):
    pcm = np.clip(np.round(y * 32767.0), -32768, 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(fs)
        w.writeframes(pcm.tobytes())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--params", default=os.path.join(HERE, "params.json"))
    ap.add_argument("--out", default=os.path.abspath(os.path.join(HERE, "..", "..", "sound", "pba", "pipe")))
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--normalize", type=float, default=None, help="rewrite master_gain in the params file so the loudest hard variant peaks at this value (0..1), then exit")
    a = ap.parse_args()
    p = json.load(open(a.params))
    if a.normalize is not None:
        pk = max(float(np.abs(render(p, "hard", v, int(p["sample_rate"]))).max()) for v in range(1, int(p["variants"]["count"]) + 1))
        p["master_gain"] = float(p["master_gain"]) * a.normalize / pk
        json.dump(p, open(a.params, "w"), indent=1)
        print("master_gain ->", p["master_gain"])
        return
    os.makedirs(a.out, exist_ok=True)
    fs = int(p["sample_rate"])
    bad = False
    for tier in TIERS:
        for var in range(1, int(p["variants"]["count"]) + 1):
            y = render(p, tier, var, fs)
            pk = float(np.abs(y).max())
            if pk > 0.999:
                bad = True
            write_wav(os.path.join(a.out, "%s_%d.wav" % (tier, var)), y, fs)
            print("%s_%d.wav  peak %.3f (%.1f dBFS)  %.2f s" % (tier, var, pk, 20 * np.log10(pk + 1e-12), len(y) / fs))
    if a.check and bad:
        print("CLIPPING: lower master_gain in params.json")
        sys.exit(1)


if __name__ == "__main__":
    main()
