"""Offline check of the probe graph's compiled kernels (lua/pba/cl_probes_kernels.lua) against reference code.
Loads the pure modules twice, once from a git revision (the reference: e.g. the commit before the kernels)
and once from the checkout, builds fields and link costs on real probe graph caches (data/pba/<map>.txt,
read only) with fixed pseudo-random seed sets, mock doors and portals, and compares every result as text
(costs to the bit, next hops, roots, link costs). --bench prints ms per build instead, for the reference,
the current code with the JIT and the current code with the JIT off.
Usage: python -I test/offline/kernels_check.py [--ref REV] [--bench] [--reps N] cache.txt ...
"""
import argparse
import hashlib
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(HERE, "pylib"))
from lupa import luajit21 as lj  # noqa: E402

FILES = ("sh_config.lua", "sh_bsp.lua", "sh_acoustics.lua", "sh_graph.lua", "sh_paths.lua", "sh_core.lua",
         "cl_probes_kernels.lua", "cl_probes.lua")


def source(rev, f):
    if rev is None:
        p = os.path.join(REPO, "lua", "pba", f)
        return open(p, encoding="utf-8").read() if os.path.exists(p) else None
    r = subprocess.run(["git", "-C", REPO, "show", "%s:lua/pba/%s" % (rev, f)], capture_output=True)
    return r.stdout.decode("utf-8") if r.returncode == 0 else None


def runtime(rev, jit_off=False):
    L = lj.LuaRuntime(unpack_returned_tuples=True)
    L.execute(open(os.path.join(HERE, "gmshim.lua"), encoding="utf-8").read())
    if jit_off:
        L.execute("jit.off() jit.flush()")
    for f in FILES:
        src = source(rev, f)
        if src is not None:
            L.execute(src)
    return L


def run(L, text, mode, reps):
    drv = open(os.path.join(HERE, "kernels_check.lua"), encoding="utf-8").read()
    return L.execute(drv, text, mode, reps)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", default="HEAD")
    ap.add_argument("--bench", action="store_true")
    ap.add_argument("--reps", type=int, default=20)
    ap.add_argument("caches", nargs="+")
    a = ap.parse_args()
    ok = True
    for path in a.caches:
        text = open(path, encoding="utf-8").read()
        name = os.path.basename(path)
        if a.bench:
            for label, rev, off in (("ref", a.ref, False), ("new jit", None, False), ("new nojit", None, True)):
                print("%-28s %-10s %s" % (name, label, run(runtime(rev, off), text, "bench", a.reps)))
            continue
        ref = run(runtime(a.ref), text, "check", 0)
        new = run(runtime(None), text, "check", 0)
        same = ref == new
        ok = ok and same
        print("%s %s: %d result blocks, sha256 %s %s" % ("PASS" if same else "FAIL", name, ref.count("\n\n") + 1,
              hashlib.sha256(ref.encode()).hexdigest()[:16], hashlib.sha256(new.encode()).hexdigest()[:16]))
        print("  " + new.split("\n\n", 1)[0])
        if not same:
            for i, (x, y) in enumerate(zip(ref.split("\n"), new.split("\n"))):
                if x != y:
                    print("  first difference, line %d:\n  ref %s\n  new %s" % (i + 1, x, y))
                    break
    sys.exit(0 if ok else 1)


main()
