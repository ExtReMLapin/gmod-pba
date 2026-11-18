"""Comb ripple of a capture of a stationary noise: the long-term spectrum of out/src at 2.9 Hz resolution, minus its
own 1/3-octave trend, std in dB over 500-4000 Hz. Two equal copies Dt apart ripple at 1/Dt; a coherent pair barely."""
import sys
import numpy as np
from scipy import signal
sys.path.insert(0, __file__.rsplit("\\", 1)[0] if "\\" in __file__ else ".")
from own_shot_capture import read_wav
from warble_an import load_src

def ripple(cap, src, rate=48000, t0=1.0, t1=15.0, lo=500, hi=4000, nper=16384):
    o = read_wav(cap)
    y = (np.asarray(o["l"]) + np.asarray(o["r"])) * 0.5
    x = load_src(src, rate)
    lag = max(int(np.argmax(signal.correlate(y[: 4 * rate], x[: 2 * rate], mode="full", method="fft"))) - (2 * rate - 1), 0)
    y = y[lag + int(t0 * rate): lag + int(t1 * rate)]
    x = x[int(t0 * rate): int(t1 * rate)]
    f, Pxy = signal.csd(x, y, fs=rate, nperseg=nper)
    f, Pxx = signal.welch(x, fs=rate, nperseg=nper)
    H = 20 * np.log10(np.abs(Pxy) / Pxx + 1e-12)
    k = (f >= lo) & (f < hi)
    h = H[k]
    # trend: moving average over 1/3 octave = about 23 % of f: use a 64-bin (186 Hz) window as the baseline
    tr = np.convolve(h, np.ones(64) / 64, mode="same")
    d = (h - tr)[32:-32]
    return float(np.std(d)), lag / rate

if __name__ == "__main__":
    for p in sys.argv[2:]:
        r, lag = ripple(p, sys.argv[1])
        print(p.split("/")[-1], "ripple_sd_dB=%.2f" % r, "lag=%.3f" % lag)
