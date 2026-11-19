"""One measured window of the per-item counters (optlua_meas.lua) during a running NPC fight (scout_fight_sv.lua,
branch scout/gc-profiler), on a freshly loaded map. Usage:
  MCP_INSTANCE=<id> python -I -u optlua_run.py <mcp.py> <label> [map] [secs] [--ident]
--ident: then an identity window (optlua_ident.lua, the new code only). Prints one JSON line per window."""
import json, os, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
MCP, LABEL = sys.argv[1], sys.argv[2]
POS = [a for a in sys.argv[3:] if not a.startswith("--")]
MAP = POS[0] if POS else "gm_construct"
SECS = float(POS[1]) if len(POS) > 1 else 20


def call(tool, args, timeout=900):
    for _ in range(10):
        out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), "50000000"],
                             capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout)
        try:
            return json.loads(out.stdout)
        except ValueError:
            time.sleep(3)
    raise SystemExit("game unreachable")


def lua(realm, code):
    r = call("lua_exec", {"realm": realm, "code": code})
    v = r.get("values")
    if v is None:
        print("lua error:", json.dumps(r)[:400], flush=True)
        return None
    return v[0] if v else None


r = call("map_load", {"map": MAP, "timeout_s": 300}, timeout=400)
print("map", r.get("map"), r.get("client_generation"), flush=True)
time.sleep(8)
for _ in range(120):
    if lua("client", "return pba.Probes == nil or pba.Probes.current ~= nil"):
        break
    time.sleep(1)
call("console_exec", {"cmd": "fps_max 200; fps_max_nofocus 0", "realm": "client"})
call("lua_exec_file", {"realm": "client", "path": os.path.join(HERE, "optlua_meas.lua")})
fight = open(os.path.join(HERE, "scout_fight_sv.lua"), encoding="utf-8").read()
dur = SECS + 30 + (SECS + 5 if "--ident" in sys.argv else 0)
call("lua_job", {"realm": "server", "code": fight, "args": {"dur": dur}, "async": True})
time.sleep(12)
lua("client", f"OPTM.Start({SECS}) return true")
time.sleep(SECS + 1)
while not lua("client", "return OPTM.done"):
    time.sleep(1)
res = lua("client", "return OPTM.res")
print(json.dumps({"label": LABEL, "map": MAP, **{k: (round(v, 3) if isinstance(v, float) else v) for k, v in res.items()}}), flush=True)
if "--ident" in sys.argv:
    call("lua_exec_file", {"realm": "client", "path": os.path.join(HERE, "optlua_ident.lua")})
    lua("client", f"OPTI.Start({SECS}) return true")
    time.sleep(SECS + 1)
    while not lua("client", "return OPTI.done"):
        time.sleep(1)
    print(json.dumps({"label": LABEL + " ident", **lua("client", "return OPTI.res")}), flush=True)
