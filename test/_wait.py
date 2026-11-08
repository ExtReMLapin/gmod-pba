"""Waiting for a measured value to settle instead of sleeping a fixed time.

wait_stable(read) polls read() every `dt` seconds and returns the last value once `n` consecutive
reads agree within `tol` (relative, or `abs_tol` for values near zero), after at least `tmin`
seconds and at most `tmax`. read() returns a number or a list/tuple of numbers (all must settle);
None means "not ready yet". Returns (value, seconds waited, settled?).
"""
import time


def _close(a, b, tol, abs_tol):
    if isinstance(a, (list, tuple)):
        return len(a) == len(b) and all(_close(x, y, tol, abs_tol) for x, y in zip(a, b))
    if not isinstance(a, (int, float)) or not isinstance(b, (int, float)):
        return a == b
    return abs(a - b) <= max(abs_tol, tol * max(abs(a), abs(b)))


def wait_stable(read, tol=0.02, abs_tol=1e-3, n=3, dt=0.5, tmin=1.0, tmax=15.0):
    t0 = time.time()
    last, streak, v = None, 0, None
    while True:
        v = read()
        if v is not None and last is not None and _close(v, last, tol, abs_tol):
            streak += 1
        else:
            streak = 0
        last = v if v is not None else last
        waited = time.time() - t0
        if v is not None and streak >= n - 1 and waited >= tmin:
            return v, waited, True
        if waited >= tmax:
            return v, waited, False
        time.sleep(dt)
