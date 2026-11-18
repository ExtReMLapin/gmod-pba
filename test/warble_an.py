"""Warble metrics of a module capture against the dry source file (offline).
LTI-ness: how much of the output a fixed linear filter of the source explains (coherence), and the short-time
spread of the per-band output/source level ratio (a gain or EQ that moves = warble)."""
import sys
import numpy as np
from scipy import signal
sys.path.insert(0, __file__.rsplit("\\", 1)[0] if "\\" in __file__ else ".")
from own_shot_capture import read_wav

def load_src(path, rate=48000):
    w = read_wav(path)
    x = np.asarray(w["l"], dtype=np.float64)
    if w["rate"] != rate:
        from math import gcd
        g = gcd(rate, w["rate"])
        x = signal.resample_poly(x, rate // g, w["rate"] // g)
    return x

def analyze(out_path, src_path, rate=48000):
    o = read_wav(out_path)
    y = (np.asarray(o["l"]) + np.asarray(o["r"])) * 0.5
    x = load_src(src_path, rate)
    # onset alignment by cross-correlation (up to 3 s)
    n = min(len(y), 6 * rate)
    xc = signal.correlate(y[:n], x[: 4 * rate], mode="full", method="fft")
    lag = int(np.argmax(np.abs(xc))) - (4 * rate - 1)
    lag = max(lag, 0)
    y = y[lag: lag + len(x)]
    m = min(len(y), len(x))
    y, x = y[:m], x[:m]
    f, coh = signal.coherence(x, y, fs=rate, nperseg=4096)
    bands = [(150, 500), (500, 1000), (1000, 2000), (2000, 4000), (4000, 8000)]
    res = {"lag_ms": lag * 1000 / rate, "peak": float(np.max(np.abs(y)))}
    for lo, hi in bands:
        k = (f >= lo) & (f < hi)
        res["coh_%d_%d" % (lo, hi)] = round(float(np.mean(coh[k])), 3)
    # per-band short-time level ratio spread
    fb, tb, X = signal.stft(x, fs=rate, nperseg=2048, noverlap=1024)
    _, _, Y = signal.stft(y, fs=rate, nperseg=2048, noverlap=1024)
    for lo, hi in bands:
        k = (fb >= lo) & (fb < hi)
        ex = np.sum(np.abs(X[k]) ** 2, axis=0)
        ey = np.sum(np.abs(Y[k]) ** 2, axis=0)
        good = ex > np.max(ex) * 1e-3
        r = 10 * np.log10((ey[good] + 1e-20) / (ex[good] + 1e-20))
        res["ratio_sd_%d_%d" % (lo, hi)] = round(float(np.std(r)), 2)
    return res

if __name__ == "__main__":
    print(analyze(sys.argv[1], sys.argv[2]))
