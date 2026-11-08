"""LuaJIT state of PBA's hot loops after real play (jit_report.lua): which loops the JIT compiled,
which it blacklisted after repeated trace aborts, and what in them it cannot record.
Same scene as perf_crowd (40 hidden emitters, player at a fixed spot of gm_construct, Lua rendering).
The map is reloaded first (clean JIT state), the crowd plays for --window seconds without any lua_exec
(its debug hook would abort the traces being recorded), with a burst of path computations and two
listener field builds run from a game timer, then the bytecode is read.
Usage: python -I -u jit_report.py <mcp.py> [--window=20] [--all]
"""
import json
import os
import subprocess
import sys
import time

MCP = sys.argv[1]
OPT = dict(a[2:].split("=", 1) if "=" in a else (a[2:], "1") for a in sys.argv[2:] if a.startswith("--"))
WINDOW = float(OPT.get("window", 20))
HERE = os.path.dirname(os.path.abspath(__file__))


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
scene = (call("lua_job", {"realm": "server", "code": crowd, "args": {"n": 40}, "timeout_s": 120}).get("values") or [{}])[0]
print(f"scene: {json.dumps(scene)}", flush=True)
pos = lua("server", "local t = {} for _, e in ipairs(PBA_CROWD or {}) do local p = e:WorldSpaceCenter() t[#t+1] = {p.x, p.y, p.z} end return t") or []
lua("client", """local srcs = {} for i, p in ipairs(util.JSONToTable([==[%s]==])) do srcs[i] = Vector(p[1], p[2], p[3]) end
timer.Simple(2, function()
  local P, PR, L = pba.Paths, pba.Probes, pba.ListenerPos()
  for _ = 1, 5 do for _, S in ipairs(srcs) do P.InvalidateCache() P.Compute(S, L, 75) end end
  if PR and PR.current then PR.BuildField(PR.current, L) PR.BuildField(PR.current, L) end
end) return true""" % json.dumps(pos))
time.sleep(WINDOW)
rep = lua("client", open(os.path.join(HERE, "jit_report.lua"), encoding="utf-8").read())
call("lua_job", {"realm": "server", "code": crowd, "args": {"stop": True}, "timeout_s": 30})
if not rep:
    sys.exit("no report")
c = rep["count"]
print(f"{rep['functions']} PBA functions, {sum(c.values())} loops: {c['compiled']} compiled, {c['blacklisted']} blacklisted, "
      f"{c['plain']} not compiled (never hot, or still tried)")
json.dump(rep, open(os.path.join(HERE, "jit_report_last.json"), "w"), indent=1)
for r in rep["rows"]:
    if not isinstance(r, dict) or "st" not in r:
        print(f"  ? {r}")
    elif r["st"] != "plain" or "all" in OPT or r["nyi"]:
        print(f"  {r['st']:12s} {r['op']:7s} {r['at']:32s} {r['nyi']}")
