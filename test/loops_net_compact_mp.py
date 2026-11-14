"""A followed loop's compact updates (pba_loops_net_compact) with TWO real players on a listen server: a player who
subscribes late (walks into range while the loop's volume and pitch change at every tick) and a player who loses his
mirror (a missed message) get a correct mirror (entity, position, volume, pitch) within 2 s, and every client follows
the volume / pitch ramp. Halves: loops_net_compact_mp_sv.lua (server) and loops_net_compact_mp_cl.lua (each client).
Needs two game instances: the host (listen server on pba_tworooms, maxplayers 4, sv_lan 1) and a second one that
joins it (`connect <LAN address>:27015`; sv_lan 1 is what lets the same Steam account in twice). The script sets up
the host's map and connects the second instance when it is not in yet.
Usage: MCP_INSTANCE=<host> MCP_INSTANCE_B=<second> python -I test/loops_net_compact_mp.py <mcp.py> [--off]
  --off: pba_loops_net_compact 0 (every update full: the same results are expected, it is a control)."""
import json, os, socket, subprocess, sys, time

MCP = sys.argv[1]
OFF = "--off" in sys.argv
HOST, B = os.environ.get("MCP_INSTANCE"), os.environ.get("MCP_INSTANCE_B")
HERE = os.path.dirname(os.path.abspath(__file__))
if not HOST or not B or HOST == B:
    print("INCONCLUSIVE: needs MCP_INSTANCE (host) and MCP_INSTANCE_B (a second game), two different instances", flush=True)
    sys.exit(0)


def call(tool, args, inst, timeout=300):
    env = dict(os.environ, MCP_INSTANCE=inst)
    a = json.dumps(args)
    tmp = None
    if len(a) > 20000:
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as f:
            f.write(a)
        tmp = f.name
        a = "@" + tmp
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, a, "200000"], env=env, capture_output=True,
                         text=True, encoding="utf-8", errors="replace", timeout=timeout).stdout
    if tmp:
        os.remove(tmp)
    try:
        return json.loads(out)
    except Exception:
        return {"raw": out[:2000]}


def lua(realm, code, inst):
    r = call("lua_exec", {"realm": realm, "code": code}, inst)
    v = r.get("values")
    return v[0] if v else None


def wait_lua(realm, code, inst, secs):
    t = time.time()
    while time.time() - t < secs:
        if lua(realm, code, inst) is True:
            return True
        time.sleep(1)
    return False


def src(name):
    return open(os.path.join(HERE, name), encoding="utf-8").read()


two = "return #player.GetHumans() == 2 and game.MaxPlayers() == 4 and game.GetMap() == 'pba_tworooms'"
if lua("server", two, HOST) is not True:
    st = call("status", {}, HOST)
    # the host: sv_lan 1 and maxplayers 4 need the map to be started from the menu
    call("disconnect", {}, HOST)
    call("console_exec", {"realm": "menu", "cmd": "sv_lan 1; maxplayers 4; map pba_tworooms"}, HOST)
    if not wait_lua("server", "return game.MaxPlayers() == 4 and #player.GetHumans() >= 1 and game.GetMap() == 'pba_tworooms'", HOST, 90):
        print("FAIL: host listen server not up", flush=True)
        sys.exit(1)
    call("disconnect", {}, B)
    ip = socket.gethostbyname(socket.gethostname())
    call("console_exec", {"realm": "menu", "cmd": f"connect {ip}:27015"}, B)
    if not wait_lua("server", two, HOST, 90):
        print("FAIL: second instance did not join", flush=True)
        sys.exit(1)
for inst in (HOST, B):
    if not wait_lua("client", "return LocalPlayer():IsValid() and pba ~= nil and pba.Loops ~= nil", inst, 30):
        print("FAIL: pba not ready on " + inst, flush=True)
        sys.exit(1)
time.sleep(3)
call("console_exec", {"realm": "server", "cmd": f"pba_loops_net_compact {0 if OFF else 1}"}, HOST)
time.sleep(1)
try:
    jobs = {}
    for inst in (HOST, B):
        r = call("lua_job", {"realm": "client", "code": src("loops_net_compact_mp_cl.lua"), "timeout_s": 60, "async": True}, inst)
        jobs[inst] = r.get("job_id")
    time.sleep(1)
    sv = call("lua_job", {"realm": "server", "code": src("loops_net_compact_mp_sv.lua"), "timeout_s": 60}, HOST, timeout=120)
    sv = sv.get("values", [sv])[0]
    cl = {}
    for inst, jid in jobs.items():
        r = call("lua_job_status", {"id": jid, "wait_s": 40}, inst, timeout=120)
        cl[inst] = r.get("values", [r])[0] if isinstance(r, dict) else r
finally:
    call("console_exec", {"realm": "server", "cmd": "pba_loops_net_compact 1"}, HOST)
print(json.dumps({"server": sv, "clients": cl}, indent=1), flush=True)
ok = isinstance(sv, dict) and sv.get("pass") is True and all(isinstance(c, dict) and c.get("pass") is True for c in cl.values())
print("PASS" if ok else "FAIL", flush=True)
sys.exit(0 if ok else 1)
