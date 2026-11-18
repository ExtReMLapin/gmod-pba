"""Normalised autocorrelation of a capture of band-limited noise at lags 5..300 ms: two equal copies Dt apart give a
peak (~0.5 for equal gains) at Dt; a single copy or a coherent pair has none. Prints the largest |acf| lag >= 20 ms."""
import sys
import numpy as np
from scipy import signal
sys.path.insert(0, __file__.rsplit("\\", 1)[0] if "\\" in __file__ else ".")
from own_shot_capture import read_wav

def acf_peak(cap, rate=48000, t0=2.0, t1=15.0):
    o = read_wav(cap)
    y = (np.asarray(o["l"]) + np.asarray(o["r"])) * 0.5
    y = y[int(t0 * rate): int(t1 * rate)]
    # whiten lightly (pre-emphasis) so the low band does not dominate the correlation
    y = signal.lfilter([1, -0.9], [1], y)
    n = len(y)
    F = np.fft.rfft(y, 2 * n)
    r = np.fft.irfft(F * np.conj(F))[: int(0.4 * rate)]
    r = r / r[0]
    lo = int(0.02 * rate)
    k = lo + int(np.argmax(np.abs(r[lo:])))
    return float(r[k]), k / rate

if __name__ == "__main__":
    for p in sys.argv[1:]:
        v, lag = acf_peak(p)
        print(p.split("/")[-1], "acf_peak=%.3f at %.1f ms" % (v, lag * 1000))
