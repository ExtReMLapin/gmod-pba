"""Golden results of the path computation, to prove that a performance refactor changes nothing.
gm_construct, the perf_crowd scene (40 hidden emitters, player at a fixed spot; both frozen in paths_golden_pairs.json): 40 pairs source ->
player, 40 pairs between emitters, and 3 listener fields (paths_golden.lua). Every number is written
with all its digits.
  --save            write the reference (test/paths_golden_ref.txt, not versioned)
  (default)         compare with the reference: exit 1 on any difference beyond --tol
  --tol=x           relative tolerance on numbers (default 0: bit for bit)
  --regen           write the emitters' positions again (paths_golden_pairs.json, from perf_crowd.lua)
  --nopin           (diagnosis) do not pin the options to their defaults
  --out=file        (diagnosis) also write this run's rows
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
                         capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout).stdout
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
PAIRS = os.path.join(HERE, "paths_golden_pairs.json")
if "regen" in OPT:
    # The emitters' positions come from perf_crowd.lua, which draws math.random and yields every 50 tries: any
    # code that draws a number between two frames (the earlier emitters' one-shots, other addons' hooks) shifts
    # the rest of the sequence, so another run could place the 37th emitter elsewhere and every pair after it
    # moved (80 rows against a reference of another crowd). The positions are therefore frozen in
    # paths_golden_pairs.json; --regen writes them again (then the reference has to be saved again too).
    crowd = open(os.path.join(HERE, "perf_crowd.lua"), encoding="utf-8").read()
    call("lua_job", {"realm": "server", "code": crowd, "args": {"n": 40, "atomic": True}, "timeout_s": 120})
    time.sleep(2)
    pos = lua("server", "local t = {} for _, e in ipairs(PBA_CROWD or {}) do local p = e:WorldSpaceCenter() t[#t+1] = {p.x, p.y, p.z} end return t") or []
    L = lua("client", "local v = pba.ListenerPos() return { v.x, v.y, v.z }")
    call("lua_job", {"realm": "server", "code": crowd, "args": {"stop": True}, "timeout_s": 30})
    if pos:
        json.dump({"listener": L, "emitters": pos}, open(PAIRS, "w", encoding="utf-8", newline=""))
        print(f"wrote {PAIRS}")
else:
    frozen = json.load(open(PAIRS, encoding="utf-8"))
    pos, L = frozen["emitters"], frozen["listener"]
if not pos:
    sys.exit("no crowd emitter placed (the map or the player was not ready)")
# the state the job starts from, printed so that two runs can be compared (the job itself pins every option to
# its default and drops the kept listener fields: paths_golden.lua)
print("start state: " + str(lua("client", """local PR, A = pba.Probes, pba
local dev = {} for k, c in pairs(A.CONFIG) do if math.abs((A.cfg[k] or 0) - c[1]) > 1e-6 * math.max(1, math.abs(c[1])) then dev[#dev + 1] = k .. '=' .. tostring(A.cfg[k]) end end
table.sort(dev)
local g = PR.current
return string.format('map %s, graph %s probes %s spacing %s, native traces %s, options off default: %s',
  game.GetMap(), g and #g.nodes or 'none', g and (g.fromCache and 'from cache' or 'built') or '', g and g.spacing or '-',
  tostring(PR.NativeTraces and PR.NativeTraces()), #dev > 0 and table.concat(dev, ' ') or 'none')""")), flush=True)
pairs = [p + L for p in pos] + [pos[i] + [pos[(i + 7) % len(pos)][0], pos[(i + 7) % len(pos)][1], pos[(i + 7) % len(pos)][2] + 40]
                               for i in range(len(pos))]
fields = [L, pos[0], pos[len(pos) // 2]]
code = open(os.path.join(HERE, "paths_golden.lua"), encoding="utf-8").read()
jargs = {"pairs": pairs, "fields": fields}
if "nopin" in OPT:  # diagnosis: keep the options as the previous steps left them
    jargs["nopin"] = True
res = call("lua_job", {"realm": "client", "code": code, "args": jargs, "timeout_s": 600}, timeout=900)
rows = (res.get("values") or [None])[0]
if not rows:
    sys.exit(f"no result: {json.dumps(res)[:600]}")
print(f"{len(rows)} rows ({len(pairs)} pairs, {len(fields)} fields)", flush=True)
if "out" in OPT:  # diagnosis: the rows of this run, to diff two runs
    open(OPT["out"], "w", encoding="utf-8", newline="\n").write("\n".join(rows) + "\n")
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
