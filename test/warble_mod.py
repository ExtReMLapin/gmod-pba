"""Modulation spectrum: share of the envelope's fluctuation power at 6-14 Hz (warble) over 0.5-4 Hz (syllables), per band."""
import sys
import numpy as np
from scipy import signal
sys.path.insert(0, __file__.rsplit("\\", 1)[0] if "\\" in __file__ else ".")
from own_shot_capture import read_wav
from warble_an import load_src

def modshare(x, rate=48000, bands=((300, 700), (700, 1500), (1500, 3000), (3000, 6000)), t0=0.5, t1=9.0):
    hop = int(0.01 * rate)
    f, t, X = signal.stft(x, fs=rate, nperseg=2 * hop, noverlap=hop)
    res = []
    for lo, hi in bands:
        k = (f >= lo) & (f < hi)
        e = np.sqrt((np.abs(X[k]) ** 2).sum(0)) + 1e-12
        e = e[(t >= t0) & (t < t1)]
        e = e / e.mean()
        e = e - e.mean()
        F = np.abs(np.fft.rfft(e * np.hanning(len(e)))) ** 2
        fr = np.fft.rfftfreq(len(e), 0.01)
        a = F[(fr >= 0.5) & (fr < 4)].sum()
        b = F[(fr >= 6) & (fr < 14)].sum()
        res.append(round(float(b / max(a, 1e-20)), 3))
    return res

def load_out(p, rate=48000):
    o = read_wav(p)
    return (np.asarray(o["l"]) + np.asarray(o["r"])) * 0.5

if __name__ == "__main__":
    src = load_src(sys.argv[1])
    print("src ", modshare(src))
    for p in sys.argv[2:]:
        y = load_out(p)
        print(p.split("/")[-1], modshare(y))
