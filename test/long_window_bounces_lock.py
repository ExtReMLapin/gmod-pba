"""Static lock of the bounce cap of the long-window simulations (native/src/pba_native.cpp, kLongWindowBounces).
The native test pba_long_window_bounces_test measures that a cap of 1024 gives the room's own reverb time where 256
cut a very reverberant small room 29 % short; this lock keeps the module's constant, the three places that use it
(g_revSim, g_slotRevSim, the baked reverb) and the value the test is built with (native/CMakeLists.txt) in step.
Usage: python -I test/long_window_bounces_lock.py   (exit 0 = locked)"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
cpp = open(os.path.join(ROOT, "native", "src", "pba_native.cpp"), encoding="utf-8").read()
cmake = open(os.path.join(ROOT, "native", "CMakeLists.txt"), encoding="utf-8").read()
bad = []
m = re.search(r"constexpr int kLongWindowBounces = (\d+);", cpp)
if not m:
    sys.exit("FAIL kLongWindowBounces not defined in pba_native.cpp")
cap = int(m.group(1))
if cap < 512:
    bad.append("kLongWindowBounces = %d: below 512 a very reverberant small room is cut short" % cap)
uses = len(re.findall(r"numBounces = kLongWindowBounces;", cpp))
if uses != 3:
    bad.append("expected 3 uses of kLongWindowBounces (g_revSim, g_slotRevSim, the bake), found %d" % uses)
# the only other numBounces assignment is the main simulator's configurable one
others = [l.strip() for l in cpp.splitlines() if "numBounces =" in l and "kLongWindowBounces" not in l]
if others != ["sh.numBounces = g_reflBounces.load();"]:
    bad.append("unexpected numBounces assignments: %r" % others)
t = re.search(r"pba_long_window_bounces_test PRIVATE PBA_BOUNCES=(\d+)", cmake)
if not t or int(t.group(1)) != cap:
    bad.append("native/CMakeLists.txt builds pba_long_window_bounces_test with PBA_BOUNCES=%s, the module uses %d" % (t and t.group(1), cap))
print("\n".join(("FAIL " + b) for b in bad) if bad else "ok   kLongWindowBounces = %d, 3 uses, test built with the same value" % cap)
sys.exit(1 if bad else 0)
