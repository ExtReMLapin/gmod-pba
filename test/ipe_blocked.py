"""Another addon's InitPostEntity hook that returns a value (Workshop report, 2026-11-15: "Steam Audio is not
installed" with both DLLs in lua/bin, gone once a Z-City NPC addon was disabled).
hook.Call stops at the first hook that returns non-nil and goes through the hook table in hash order: every pba
InitPostEntity hook after such a hook never ran. The native module never started (N.err stayed nil, which the menu
shows as NOT INSTALLED) and the client never sent pba_ready, so the server relayed nothing to it.
The test mounts (lua_mount, this game only) a temporary folder holding a copy of the Lua under test (the folder
mounted now, if any) plus a blocker addon in autorun/client and autorun/server: 40 InitPostEntity hooks returning
true. (Files written into the game's own lua/ folder while it runs are not seen: the engine caches the file list.)
It loads gm_construct, then asserts:
  - the blocker did block (one of its hooks ran and stopped the call), otherwise the run is invalid
  - client: the native module start was attempted (N.ready, N.building or N.err set)
  - server: the local player is marked ready for the relay (pba_ready received)
  - client: the probe field was started (pba_probes)
The previous mount is put back and the map loaded anew at the end.
Usage: python -I test/ipe_blocked.py <mcp.py>"""
import json, os, shutil, subprocess, sys, tempfile, time

MCP = sys.argv[1]
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def call(tool, a, timeout=300):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(a), "200000"],
                         capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout).stdout
    try:
        return json.loads(out)
    except ValueError:
        return {"raw": out}


import _cvsnap
_cvsnap.guard(call)


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


BLOCKER = """-- pba test/ipe_blocked.py: a stand-in for another addon whose InitPostEntity hook returns a value
for i = 1, 40 do
	hook.Add("InitPostEntity", "pba_test_ipe_block_" .. i, function()
		PBA_TEST_IPE_BLOCKED = (PBA_TEST_IPE_BLOCKED or 0) + 1
		return true
	end)
end
"""
MAP = "gm_construct"  # (shipped with the game: the test does not depend on the addon's maps)

prev = call("lua_mount", {}).get("lua_mount")
tmp = tempfile.mkdtemp(prefix="pba_ipe_")
problems, res = [], {}
try:
    if prev:
        src = os.path.join(prev, "lua") if os.path.isdir(os.path.join(prev, "lua")) else prev
        shutil.copytree(src, os.path.join(tmp, "lua"))
    for r in ("client", "server"):
        d = os.path.join(tmp, "lua", "autorun", r)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "zz_pba_test_ipe_block.lua"), "w", encoding="ascii", newline="\n") as fh:
            fh.write(BLOCKER)
    m = call("lua_mount", {"path": tmp})
    if not m.get("base_lua_mounted", True):
        raise SystemExit("FAIL lua_mount: " + json.dumps(m)[:300])
    ml = call("map_load", {"map": MAP, "maxplayers": 4}, timeout=300)
    if "map" not in ml:
        raise SystemExit("FAIL map_load: " + json.dumps(ml)[:300])
    time.sleep(8)  # pba's own delays after InitPostEntity (module 1 s, probes 2 s) and any fallback
    res["client"] = lua("client", """local N = pba.Native or {}
return { blocked = PBA_TEST_IPE_BLOCKED, ready = N.ready == true, building = N.building ~= nil, err = N.err,
	probes = pba.Probes and (pba.Probes.current ~= nil or pba.Probes.building ~= nil) or false }""")
    res["server"] = lua("server", """local p = player.GetAll()[1]
return { blocked = PBA_TEST_IPE_BLOCKED, ready = IsValid(p) and pba.PState(p).ready == true }""")
    c, s = res["client"] or {}, res["server"] or {}
    print("client:", json.dumps(c))
    print("server:", json.dumps(s))
    if not c.get("blocked"):
        problems.append("invalid run: the blocker did not run on the client")
    if not (c.get("ready") or c.get("building") or c.get("err")):
        problems.append("native module start never attempted (menu would say NOT INSTALLED)")
    if not s.get("ready"):
        problems.append("server never got pba_ready from the client (nothing relayed to it)")
    if not c.get("probes"):
        problems.append("probe field never started on the client (pba_probes never ran)")
finally:
    call("lua_mount", {"path": prev})
    call("map_load", {"map": MAP, "maxplayers": 4}, timeout=300)
    shutil.rmtree(tmp, ignore_errors=True)

print(json.dumps({"pass": not problems, "problems": problems}, indent=1))
sys.exit(0 if not problems else 1)
