"""Golden results of the path computation, to prove that a performance refactor changes nothing.
gm_construct, the perf_crowd scene (40 hidden emitters, player at a fixed spot): 40 pairs source ->
player, 40 pairs between emitters, and 3 listener fields (paths_golden.lua). Every number is written
with all its digits.
  --save            write the reference (test/paths_golden_ref.txt, not versioned)
  (default)         compare with the reference: exit 1 on any difference beyond --tol
  --tol=x           relative tolerance on numbers (default 0: bit for bit)
Usage: python -I -u paths_golden.py <mcp.py> [--save] [--tol=1e-9]
"""
import json
import os
import re
import subprocess
import sys
import time

MCP = sys.argv[1]
OPT = dict(a[2:].split("=", 1) if "=" in a else (a[2:], "1") for a in sys.argv[2:] if a.startswith("--"))
TOL = float(OPT.get("tol", 0))
HERE = os.path.dirname(os.path.abspath(__file__))
REF = os.path.join(HERE, "paths_golden_ref.txt")


def call(tool, args, timeout=900):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), "4000000"],
                         capture_output=True, text=True, encoding="utf-8", timeout=timeout).stdout
    try:
        return json.loads(out)
    except ValueError:
        return {"raw": out[-400:]}


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


sys.path.insert(0, HERE)
import _cvsnap  # restores every pba_* setting at exit
_cvsnap.guard(call)

call("map_load", {"map": "gm_construct", "maxplayers": 4}, timeout=300)
time.sleep(8)
lua("server", "local p = player.GetHumans()[1] p:SetPos(Vector(-1800, -1200, -140)) p:SetEyeAngles(Angle(0, 0, 0)) return true")
call("console_exec", {"realm": "client", "cmd": "pba_native_render 0"})
for _ in range(120):
    if lua("client", "return pba.Probes == nil or pba.Probes.current ~= nil"):
        break
    time.sleep(1)
crowd = open(os.path.join(HERE, "perf_crowd.lua"), encoding="utf-8").read()
call("lua_job", {"realm": "server", "code": crowd, "args": {"n": 40}, "timeout_s": 120})
time.sleep(2)
pos = lua("server", "local t = {} for _, e in ipairs(PBA_CROWD or {}) do local p = e:WorldSpaceCenter() t[#t+1] = {p.x, p.y, p.z} end return t") or []
L = lua("client", "local v = pba.ListenerPos() return { v.x, v.y, v.z }")
call("lua_job", {"realm": "server", "code": crowd, "args": {"stop": True}, "timeout_s": 30})
pairs = [p + L for p in pos] + [pos[i] + [pos[(i + 7) % len(pos)][0], pos[(i + 7) % len(pos)][1], pos[(i + 7) % len(pos)][2] + 40]
                               for i in range(len(pos))]
fields = [L, pos[0], pos[len(pos) // 2]]
code = open(os.path.join(HERE, "paths_golden.lua"), encoding="utf-8").read()
res = call("lua_job", {"realm": "client", "code": code, "args": {"pairs": pairs, "fields": fields}, "timeout_s": 600}, timeout=900)
rows = (res.get("values") or [None])[0]
if not rows:
    sys.exit(f"no result: {json.dumps(res)[:600]}")
print(f"{len(rows)} rows ({len(pairs)} pairs, {len(fields)} fields)", flush=True)
if "save" in OPT:
    open(REF, "w", encoding="utf-8", newline="\n").write("\n".join(rows) + "\n")
    print(f"saved {REF}")
    sys.exit(0)

NUM = re.compile(r"-?\d+(?:\.\d+)?(?:e[-+]?\d+)?")
ref = open(REF, encoding="utf-8").read().splitlines()
diffs, worst = 0, 0.0
for i, (a, b) in enumerate(zip(ref, rows)):
    if a == b:
        continue
    na, nb = NUM.findall(a), NUM.findall(b)
    ok = NUM.sub("#", a) == NUM.sub("#", b) and len(na) == len(nb)
    if ok:
        for x, y in zip(na, nb):
            x, y = float(x), float(y)
            rel = abs(x - y) / max(abs(x), abs(y), 1.0)
            worst = max(worst, rel)
            if rel > TOL:
                ok = False
    if not ok:
        diffs += 1
        if diffs <= 5:
            print(f"row {i}:\n  ref {a[:400]}\n  now {b[:400]}")
if len(ref) != len(rows):
    diffs += 1
    print(f"row count {len(ref)} -> {len(rows)}")
print(f"{diffs} differing rows, worst relative number difference {worst:.3g} (tolerance {TOL:g})")
print("PASS" if diffs == 0 else "FAIL")
sys.exit(1 if diffs else 0)
