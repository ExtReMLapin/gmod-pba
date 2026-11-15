"""Synthesizes the metal pipe sounds (sound/pba/pipe/<tier>_<n>.wav) from params.json.

A struck steel tube, by modal synthesis: a sum of exponentially decaying sinusoids (the partials of params.json:
frequency, level, T60) plus a short noise click for the strike. A tier (hard / medium / soft) is a harder or softer
strike: its gain, a tilt above 1 kHz (a soft strike excites the high partials less), its click and its decay. A variant
is a different strike position: seeded per-partial amplitude changes and a slight detune, the same for every tier.

A first take fitted ~100 modes and a noise bed to the meme recording's spectrum and level curve by gradient descent:
the recording is brick-wall compressed (flat for 2.4 s, then cut), so the fit made a tone without attack that never
decays, and its close modes beat at 50-130 Hz: it sounded like a drill. These few separated partials with a real
attack and decay are what a pipe sounds like; the room comes from pba (Steam Audio), not from the file.

Deterministic, numpy only. Usage:  python gen.py [--params params.json] [--out ../../sound/pba/pipe] [--check]
(--check prints the peak / duration of every file and fails if one clips)
"""
import argparse
import json
import os
import sys
import wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
TIERS = ("hard", "medium", "soft")


def render(p, tier, var):
    """One file (float, unnormalized): tier name, variant index 1..count."""
    sr = int(p["sample_rate"])
    t = np.arange(int(sr * float(p["duration"]))) / sr
    tr = p["tiers"][tier]
    v = p["variants"]
    rng = np.random.RandomState(int(v["seed"]) * 1000 + var)  # the strike position: same for every tier
    y = np.zeros_like(t)
    for f, db, t60 in p["partials"]:
        f = f * (1 + rng.randn() * float(v["detune"]))
        a = 10 ** (db / 20) * (1 + rng.randn() * float(v["amp_jitter"]))
        phase = rng.uniform(0, 2 * np.pi)
        if f > 1000:
            a *= 10 ** (float(tr["tilt_db_oct"]) * np.log2(f / 1000) / 20)
        t60 *= float(p["decay_scale"]) * float(tr["decay"])
        y += a * np.sin(2 * np.pi * f * t + phase) * np.exp(-6.91 * t / t60)
    c = p["click"]
    nrng = np.random.RandomState(int(v["seed"]) * 1000 + TIERS.index(tier) * 100 + var + 7)
    n = nrng.randn(len(t)) * np.exp(-t / float(c["tau"]))
    n = np.diff(n, prepend=0.0)
    y += float(c["level"]) * float(tr["click"]) * n / np.abs(n).max() * np.abs(y).max()
    y *= np.minimum(1.0, t / float(c["attack"]))
    k = int(sr * float(p["fade_out"]))
    y[-k:] *= np.linspace(1.0, 0.0, k)
    return y * 10 ** (float(tr["gain_db"]) / 20)


def render_all(p):
    """{(tier, var): float array}, scaled together so the loudest hard file peaks at p.peak."""
    out = {(tier, i): render(p, tier, i) for tier in TIERS for i in range(1, int(p["variants"]["count"]) + 1)}
    scale = float(p["peak"]) / max(np.abs(y).max() for (tier, _), y in out.items() if tier == "hard")
    return {k: y * scale for k, y in out.items()}


def write_wav(path, y, sr):
    pcm = np.clip(np.round(y * 32767), -32768, 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm.tobytes())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--params", default=os.path.join(HERE, "params.json"))
    ap.add_argument("--out", default=os.path.join(HERE, "..", "..", "sound", "pba", "pipe"))
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    with open(a.params) as f:
        p = json.load(f)
    os.makedirs(a.out, exist_ok=True)
    bad = False
    for (tier, i), y in render_all(p).items():
        write_wav(os.path.join(a.out, "%s_%d.wav" % (tier, i)), y, int(p["sample_rate"]))
        if a.check:
            pk = np.abs(y).max()
            print("%s_%d  peak %.1f dBFS  %.2f s" % (tier, i, 20 * np.log10(pk), len(y) / int(p["sample_rate"])))
            bad = bad or pk >= 1.0
    if bad:
        print("CLIPPING: lower peak in params.json")
        sys.exit(1)


if __name__ == "__main__":
    main()
