"""Path quality bench over several maps (see path_quality.lua): how far PBA's level is from an
independent single-bend reference. Prints the metrics per map; with --check, fails above the
thresholds below (set from the measured baseline before each path feature, TDD style).
Usage: python -I -u path_quality.py <mcp.py> [--check] [maps...]
"""
import json
import subprocess
import sys
import time

MCP = sys.argv[1]
CHECK = "--check" in sys.argv[2:]
DETAILS = "--details" in sys.argv[2:]
LIFT = next((float(a[len("--lift="):]) for a in sys.argv[2:] if a.startswith("--lift=")), 12)
SETS = [a[len("--set="):] for a in sys.argv[2:] if a.startswith("--set=")]  # e.g. --set=pba_probe_bridge_max=0
MAPS = [a for a in sys.argv[2:] if not a.startswith("--")] or ["pba_demo", "gm_construct", "d1_town_01"]
PAIRS = 30
# thresholds (share of pairs): None = report only. Set from the baseline, see docs/JOURNAL.md.
MAX_OVER6 = None
MAX_SILENT = 0.07  # warm, regression guard (0.033-0.067 today: street-to-rooftop bends in open air, target of the edge graph)
MAX_COLD_SILENT = 0.15        # cold one-shots: ~1.0 before the inline probe solve (absolute guard)
MAX_COLD_EXTRA_SILENT = 0.01  # cold silences beyond the warm ones: the listener field leaves none (check it with --set=pba_probe_inline_ms=0)
MAX_COLD_GAP = None if "--no-gap" in sys.argv[2:] else 1.0  # dB, cold vs warm median (default settings;
# --no-gap with --set=pba_probe_inline_ms=0: the field alone gives the best route, not the alternatives)


def call(tool, args, timeout=900):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), "2000000"],
                         capture_output=True, text=True, encoding="utf-8", timeout=timeout).stdout
    try:
        return json.loads(out)
    except ValueError:
        return {"raw": out[-500:]}


code = open(__file__.replace(".py", ".lua"), encoding="utf-8").read()
ok_all = True
for m in MAPS:
    if call("status", {}).get("map") != m:
        call("map_load", {"map": m, "maxplayers": 4}, timeout=300)
        time.sleep(4)
    # pba_demo starts in mode A (PBA off: no probe graph): mode C
    call("lua_exec", {"realm": "server", "code": "if pba.DemoMap and pba.DemoMap.SetMode then pba.DemoMap.SetMode(3) end return true"})
    call("lua_exec", {"realm": "client", "code": "if pba.Probes and not pba.Probes.current then pba.Probes.Start() end return true"})
    for kv in SETS:
        k, v = kv.split("=", 1)
        call("console_exec", {"realm": "client", "cmd": f"{k} {v}"})
    time.sleep(0.5)
    t0 = time.time()
    r = call("lua_job", {"realm": "client", "code": code, "timeout_s": 600,
                         "args": {"pairs": PAIRS, "seed": 1, "max_over6": MAX_OVER6, "max_silent": MAX_SILENT, "max_cold_silent": MAX_COLD_SILENT, "max_cold_gap": MAX_COLD_GAP, "max_cold_extra_silent": MAX_COLD_EXTRA_SILENT, "details": DETAILS, "lift": LIFT}})
    v = (r.get("values") or [r])[0]
    print(f"{m} ({time.time() - t0:.0f}s): {json.dumps(v)}", flush=True)
    if CHECK and not (isinstance(v, dict) and v.get("pass")):
        ok_all = False
print("PASS" if ok_all else "FAIL")
sys.exit(0 if ok_all or not CHECK else 1)
