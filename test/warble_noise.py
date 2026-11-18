"""Stationary-noise warble check: a stationary noise through a fixed system gives a band level that fluctuates like
the noise's own. Prints, per 1/3-octave band, std (dB) of the short-time level of the capture and of the source,
and the std of 1-s means (slow modulation: what ears hear as warble)."""
import sys
import numpy as np
from scipy import signal
sys.path.insert(0, __file__.rsplit("\\", 1)[0] if "\\" in __file__ else ".")
from own_shot_capture import read_wav
from warble_an import load_src

CENTERS = [250, 400, 630, 1000, 1600, 2500, 4000]

def bandseries(x, rate, frame=0.125):
    n = int(frame * rate)
    f, t, X = signal.stft(x, fs=rate, nperseg=n, noverlap=0)
    P = np.abs(X) ** 2
    out = {}
    for c in CENTERS:
        k = (f >= c / 2 ** (1 / 6)) & (f < c * 2 ** (1 / 6))
        out[c] = 10 * np.log10(P[k].sum(0) + 1e-20)
    return t, out

def run(cap, src, t0=1.5, t1=14.5, rate=48000):
    o = read_wav(cap)
    y = (np.asarray(o["l"]) + np.asarray(o["r"])) * 0.5
    x = load_src(src, rate)
    ty, by = bandseries(y, rate)
    tx, bx = bandseries(x, rate)
    res = {}
    # align by the onset of the source: assume capture starts <0.5 s before the sound; find lag with xcorr of 1/3 band 1k envelope
    lag = int(np.argmax(signal.correlate(y[: 3 * rate], x[: 2 * rate], mode="full", method="fft"))) - (2 * rate - 1)
    lag = max(lag, 0) / rate
    ky = (ty >= t0 + lag) & (ty < t1 + lag)
    kx = (tx >= t0) & (tx < t1)
    for c in CENTERS:
        a, b = by[c][ky], bx[c][kx]
        m = len(a) // 8 * 8
        slow = a[:m].reshape(-1, 8).mean(1)
        res[c] = (round(float(np.std(a)), 2), round(float(np.std(b)), 2), round(float(np.std(slow)), 2),
                  round(float(np.std(bx[c][kx][:m].reshape(-1, 8).mean(1))), 2))
    return res, lag

if __name__ == "__main__":
    r, lag = run(sys.argv[1], sys.argv[2])
    print("lag_s", round(lag, 3), "(band: out_sd, src_sd, out_slow_sd, src_slow_sd)")
    for c, v in r.items():
        print(c, v)
