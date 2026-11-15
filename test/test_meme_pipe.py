"""Pure test (no game): the checked-in metal pipe clangs (sound/pba/pipe/*.wav) are a strike that rings down, not a
drone. The first synthesized set had no attack and held its level for seconds (fitted to a brick-wall compressed
recording) and sounded like a drill.
For every file: the loudest 10 ms is within the first 30 ms (an attack), and the 1.0-1.2 s window is at least 20 dB
under the first 50 ms (it decays). Red on the first set (hard_1: peak at 1.4 s, -2 dB at 1 s), green on gen.py's.
Usage: python -I test_meme_pipe.py [ignored args]   (PIPE_DIR=<folder> to check another set)
"""
import glob
import os
import sys
import unittest
import wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
DIR = os.environ.get("PIPE_DIR") or os.path.join(HERE, "..", "sound", "pba", "pipe")


def load(path):
    with wave.open(path, "rb") as w:
        sr = w.getframerate()
        x = np.frombuffer(w.readframes(w.getnframes()), "<i2").astype(float) / 32768
    return x, sr


def db(x):
    return 10 * np.log10(np.mean(x ** 2) + 1e-20)


class Clang(unittest.TestCase):
    def test_strike_then_decay(self):
        files = sorted(glob.glob(os.path.join(DIR, "*.wav")))
        self.assertEqual(len(files), 12, DIR)
        for f in files:
            x, sr = load(f)
            h = sr // 100
            n = len(x) // h
            e = [db(x[i * h:(i + 1) * h]) for i in range(n)]
            name = os.path.basename(f)
            self.assertLessEqual(int(np.argmax(e)), 2, "%s: loudest 10 ms at %.2f s, no attack" % (name, np.argmax(e) / 100))
            drop = db(x[: sr // 20]) - db(x[sr: int(sr * 1.2)])
            self.assertGreaterEqual(drop, 20, "%s: only %.1f dB down at 1 s, it does not ring down" % (name, drop))


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]])
