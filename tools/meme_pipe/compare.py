"""Compares recordings of the in-game stack fall (pba_native.CaptureStart / CaptureStop WAVs) with the target.

Same loss parts as fit.py (long-term spectrum as mean power / mean log, 1/3-octave band levels in time, overall RMS
matched) on the first WIN seconds from each file's onset, plus the RMS / peak levels and a side-by-side PNG:
spectrograms, the long-term spectra and the band-level envelope.

Usage: python compare.py --target meme.wav --png out.png capture1.wav [capture2.wav ...]
"""
import argparse
import os
import sys

import numpy as np
import scipy.signal as ss
import soundfile as sf

import fit

FS = fit.FS


def onset_seg(path):
    x, fs = sf.read(path)
    m = x.mean(1) if x.ndim > 1 else x
    if fs != FS:
        m = ss.resample_poly(m, FS, fs)
    env = np.convolve(m ** 2, np.ones(480) / 480, mode="same")
    on = max(0, int(np.argmax(env > 1e-3 * env.max())) - 48)
    seg = m[on:on + int(fit.WIN * FS)]
    return np.concatenate([np.zeros(int(fit.LEAD * FS)), seg]), x


def metrics(seg, tseg, dev="cpu"):
    import torch
    feats = fit.Feats(torch, dev)
    a = feats(torch.tensor(seg[:len(tseg)], dtype=torch.float32))
    b = feats(torch.tensor(tseg, dtype=torch.float32))
    l, parts = fit.loss_fn(a, b, feats.fine)
    return parts


def main():
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", required=True)
    ap.add_argument("--png", required=True)
    ap.add_argument("files", nargs="+")
    a = ap.parse_args()
    tseg = fit.load_target(a.target)
    segs = [("target", tseg, None)]
    for f in a.files:
        s, x = onset_seg(f)
        segs.append((os.path.basename(f), s, x))
    n = len(segs)
    fig, ax = plt.subplots(3, n, figsize=(5.2 * n, 10), squeeze=False)
    colors = ["k", "C1", "C2", "C3", "C4"]
    for j, (name, s, x) in enumerate(segs):
        ax[0, j].specgram(s, NFFT=2048, Fs=FS, noverlap=1536, cmap="magma", vmin=-140, vmax=-30 + 20 * np.log10(np.sqrt(np.mean(s ** 2)) / 0.1 + 1e-9) * 0 )
        ax[0, j].set_ylim(0, 12000)
        title = name
        if j > 0:
            p = metrics(s, tseg)
            rms = 20 * np.log10(np.sqrt(np.mean(s[int(fit.LEAD * FS):] ** 2)) + 1e-12)
            pk = 20 * np.log10(np.abs(x).max() + 1e-12)
            title += "\nltas %.2f mlog %.2f bands %.2f | rms %.1f pk %.1f dBFS" % (p[0], p[1], p[2], rms, pk)
            print(name, "ltas %.2f mlog %.2f bands %.2f env %.2f | rms %.1f dBFS peak %.1f dBFS" % (p[0], p[1], p[2], p[3], rms, pk))
        else:
            rms = 20 * np.log10(np.sqrt(np.mean(s[int(fit.LEAD * FS):] ** 2)) + 1e-12)
            title += "\nrms %.1f dBFS" % rms
        ax[0, j].set_title(title, fontsize=9)
        f, P = ss.welch(s[int(fit.LEAD * FS):], FS, nperseg=8192, noverlap=4096)
        P = P / P.sum()
        ax[1, 0].semilogx(f[1:], 10 * np.log10(P[1:] + 1e-14) + 10 * np.log10(len(P)), color=colors[j % 5], lw=.7, label=name)
        # band envelope (total level per 50 ms)
        hop = int(0.05 * FS)
        env = [10 * np.log10(np.mean(s[i:i + hop] ** 2) + 1e-12) for i in range(0, len(s) - hop, hop)]
        ax[2, 0].plot(np.arange(len(env)) * 0.05, env, color=colors[j % 5], lw=.9, label=name)
        if j > 0:
            ax[1, j].axis("off"); ax[2, j].axis("off")
    ax[1, 0].set_xlim(80, 16000); ax[1, 0].set_ylim(-50, 20); ax[1, 0].legend(fontsize=7); ax[1, 0].set_title("long-term spectrum (dB, normalized)")
    ax[2, 0].set_title("level per 50 ms (dB re full scale)"); ax[2, 0].legend(fontsize=7); ax[2, 0].set_ylim(-80, -5)
    plt.tight_layout()
    plt.savefig(a.png, dpi=70)


if __name__ == "__main__":
    main()
