"""Spectral images of a captured module output (garrysmod/data/pba/<name>.wav, 48 kHz stereo, 16 bit or float).

A sound recorded at R Hz holds nothing above R/2 (x pitch / 100 once played at another pitch). Whatever the capture
holds above that is an image of the band left by a missing or too coarse interpolation. Prints the energy above
the cut (R/2 x pitch/100 x 1.1) in dB under the energy below it, over the loud part of the file.

  python -I test/low_rate_spectrum.py <capture.wav> <source_rate> [pitch=100] [--max=-60]

Exit code 1 when the images are above --max (default -60 dB).
"""
import sys
import wave
import struct

import numpy as np


def read_wav(path):
    with open(path, "rb") as f:
        b = f.read()
    # RIFF parser (the module writes float WAVs, format 3, which the wave module refuses)
    pos, fmt, data = 12, None, None
    while pos + 8 <= len(b):
        tag, n = b[pos:pos + 4], struct.unpack("<I", b[pos + 4:pos + 8])[0]
        if tag == b"fmt ":
            fmt = struct.unpack("<HHIIHH", b[pos + 8:pos + 24])
        elif tag == b"data":
            data = b[pos + 8:pos + 8 + n]
            break
        pos += 8 + n + (n & 1)
    tag, ch, rate = fmt[0], fmt[1], fmt[2]
    bits = fmt[5]
    if tag == 3:
        x = np.frombuffer(data, dtype="<f4").astype(np.float64)
    else:
        x = np.frombuffer(data, dtype="<i2").astype(np.float64) / 32768.0
    return x.reshape(-1, ch).mean(axis=1), rate


def image_db(x, rate, cut_hz, nfft=8192):
    # loud part only: frames within 30 dB of the loudest
    hop = nfft // 2
    win = np.hanning(nfft)
    frames = [x[i:i + nfft] * win for i in range(0, len(x) - nfft, hop)]
    energies = np.array([np.sum(f * f) for f in frames])
    keep = energies > energies.max() * 1e-3
    freqs = np.fft.rfftfreq(nfft, 1.0 / rate)
    spec = np.zeros(len(freqs))
    for f, k in zip(frames, keep):
        if k:
            spec += np.abs(np.fft.rfft(f)) ** 2
    lo = spec[(freqs > 50) & (freqs < cut_hz)].sum()
    hi = spec[freqs >= cut_hz].sum()
    return 10 * np.log10(max(hi, 1e-30) / max(lo, 1e-30))


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    limit = -60.0
    for a in sys.argv[1:]:
        if a.startswith("--max="):
            limit = float(a[6:])
    path, src = args[0], float(args[1])
    pitch = float(args[2]) if len(args) > 2 else 100.0
    x, rate = read_wav(path)
    cut = 0.5 * src * pitch / 100.0 * 1.1
    img = image_db(x, rate, cut)
    print("%s: source %g Hz, pitch %g, images above %.0f Hz: %.1f dB (limit %.0f)" % (path, src, pitch, cut, img, limit))
    return 0 if img < limit else 1


if __name__ == "__main__":
    sys.exit(main())
