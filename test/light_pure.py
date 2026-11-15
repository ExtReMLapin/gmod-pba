"""PBA Light for real: a game that never sees the native module from the start of the map (the Workshop package
alone, what most players run). Other Light steps only turn native rendering off (pba_native_render 0): the module
stays loaded, N.ready stays true and every `N.ready` branch, the native world traces and the module start are
never run the Light way. light_no_module hides the module after the map started.
The test mounts (lua_mount, this game only) a temporary folder holding a copy of the Lua under test (the folder
mounted now, if any) plus lua/autorun/aaa_pba_test_light_pure.lua, loaded before pba's loader, which makes the
client believe the module is not there (file.Exists false for lua/bin/gmcl_pba_*, require "pba" fails). Then, on
pba_tworooms, in one map load:
  1. start: the stub ran first, pba_native is nil, N.ready false, N.err "module not installed", no renderer
  2. probe field rebuilt without its cache by util.* traces: as many probes as the field loaded at map start
     (from the cache, which a game with the module builds with the native traces)
  3. six existing Light tests replayed as they are: bot_gunfire, loop_removed, speech_floor, stop_followers,
     client_loop, patch_oneshot_client
  4. no Lua error in any realm since the map load (its loading included)
The previous mount is put back and the map loaded anew at the end. About 2 minutes.
Usage: python -I test/light_pure.py <mcp.py>"""
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


def wait_lua(realm, code, timeout=30.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if lua(realm, code) is True:
            return True
        time.sleep(0.5)
    return False


def job(realm, file, timeout_s=120):
    code = open(os.path.join(HERE, file), encoding="utf-8").read()
    r = call("lua_job", {"realm": realm, "code": code, "timeout_s": timeout_s}, timeout=timeout_s + 60)
    return r.get("values", [r])[0] if isinstance(r, dict) else r


STUB = """-- pba test/light_pure.py: this game behaves as if the native module were not installed (Workshop package alone)
if not CLIENT then return end
PBA_TEST_LIGHT_PURE = { first = pba == nil }
local exists, req = file.Exists, require
file.Exists = function(p, path, ...)
	if isstring(p) and string.find(string.lower(p), "gmcl_pba_", 1, true) then return false end
	return exists(p, path, ...)
end
require = function(name, ...)
	if name == "pba" then error("module not found (pba test light_pure)") end
	return req(name, ...)
end
if util.IsBinaryModuleInstalled then
	local inst = util.IsBinaryModuleInstalled
	util.IsBinaryModuleInstalled = function(name, ...) if name == "pba" then return false end return inst(name, ...) end
end
"""
MAP = "pba_tworooms"
JOBS = [("bot_gunfire", "server", "bot_gunfire.lua", 120), ("loop_removed", "server", "loop_removed.lua", 120),
        ("speech_floor", "client", "speech_floor.lua", 120), ("stop_followers", "client", "stop_followers.lua", 120),
        ("client_loop", "client", "client_loop.lua", 20), ("patch_oneshot_client", "client", "patch_oneshot_client.lua", 20)]

prev = call("lua_mount", {}).get("lua_mount")
tmp = tempfile.mkdtemp(prefix="pba_light_")
problems, res = [], {}
try:
    if prev:
        src = os.path.join(prev, "lua") if os.path.isdir(os.path.join(prev, "lua")) else prev
        shutil.copytree(src, os.path.join(tmp, "lua"))
    d = os.path.join(tmp, "lua", "autorun")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "aaa_pba_test_light_pure.lua"), "w", encoding="ascii", newline="\n") as fh:
        fh.write(STUB)
    m = call("lua_mount", {"path": tmp})
    if not m.get("base_lua_mounted", True):
        raise SystemExit("FAIL lua_mount: " + json.dumps(m)[:300])
    ml = call("map_load", {"map": MAP, "maxplayers": 4}, timeout=300)
    if "map" not in ml:
        raise SystemExit("FAIL map_load: " + json.dumps(ml)[:300])

    # 1. start without the module
    wait_lua("client", "local N = pba.Native return N ~= nil and not N.building and (N.ready == true or N.err ~= nil)", 30)
    st = lua("client", """local N = pba.Native or {}
return { stub = PBA_TEST_LIGHT_PURE, native = pba_native ~= nil, ready = N.ready == true, err = N.err, render = N.render and true or false }""") or {}
    res["start"] = st
    if not (st.get("stub") or {}).get("first"):
        problems.append("invalid run: the stub did not load before pba (%s)" % json.dumps(st.get("stub")))
    if st.get("native") or st.get("ready") or st.get("render"):
        problems.append("the module is reachable: not a Light run (%s)" % json.dumps(st))
    if st.get("err") != "module not installed":
        problems.append("N.err is %r, not 'module not installed'" % st.get("err"))

    # 2. probe field by util.* traces
    if not wait_lua("client", "return pba.Probes.current ~= nil", 60):
        problems.append("no probe field at map start")
    else:
        n0 = lua("client", "return #pba.Probes.current.nodes")
        lua("client", "pba.Probes.Start(true) return true")
        ok = wait_lua("client", "local g = pba.Probes.current return g ~= nil and not g.fromCache", 120)
        n1 = lua("client", "local g = pba.Probes.current return g and not g.fromCache and #g.nodes or -1")
        res["probes"] = {"start": n0, "rebuilt_util": n1}
        if not ok or n1 != n0:
            problems.append("probe field rebuilt by util.* traces: %s probes, %s at map start" % (n1, n0))

    # 3. existing Light tests, as they are
    for label, realm, f, t in JOBS:
        r = job(realm, f, t)
        passed = isinstance(r, dict) and (r.get("pass") is True or (label == "loop_removed"  # (run_battery's judge)
                                          and (r.get("trackedBeforeRemove") or 0) >= 1 and r.get("serverLeft") == 0))
        res[label] = r if not passed else True
        if not passed:
            problems.append("%s failed: %s" % (label, json.dumps(r)[:300]))

    # 4. no Lua error
    errs = call("errors_since", {"since_map_load": True, "limit": 50}).get("errors", [])
    if errs:
        problems.append("%d Lua error(s), first: %s" % (len(errs), json.dumps(errs[0])[:300]))
finally:
    call("lua_mount", {"path": prev})
    call("map_load", {"map": MAP, "maxplayers": 4}, timeout=300)
    shutil.rmtree(tmp, ignore_errors=True)

print(json.dumps(res, indent=1)[:4000])
print(json.dumps({"pass": not problems, "problems": problems}, indent=1))
sys.exit(0 if not problems else 1)
