"""Other addons' EntityEmitSound hooks and pba (parity P2-13, pba_hook_last / pba_cl_hook_last).
hook.Call stops at the first hook that returns non-nil and goes through the hook table in hash order, so pba's
"return false" hid the sounds it takes from every foreign hook after it, and a foreign hook that changed a sound
(returned true) before pba hid it from pba. hook_order.lua (both realms, pba_tworooms, sounds from behind the wall)
registers an observer, a pitch modifier and a blocker under five name prefixes and asks, whatever their order against
pba's hook: the observer sees the sound pba takes, pba gets the modified sound once at the modified pitch, the modifier
ran once, pba never sees the blocked sound, and pba's own emissions (A.Emit) reach no foreign hook.
Runs: both options on (must pass, both realms), both off (must FAIL: the bug, proving the test sees it).
Usage: python -I test/hook_order.py <mcp.py>"""
import json, os, subprocess, sys, time
MCP = sys.argv[1]
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def call(tool, a, timeout=300):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(a), "200000"],
                         capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout).stdout
    try:
        return json.loads(out)
    except ValueError:
        return {}


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


import _cvsnap
_cvsnap.guard(call)

if (call("status", {}).get("map") or "") != "pba_tworooms":
    call("map_load", {"map": "pba_tworooms"}, timeout=300)
    time.sleep(6)
CODE = open(os.path.join(HERE, "hook_order.lua"), encoding="utf-8").read()


def set_option(on):
    call("console_exec", {"realm": "server", "cmd": f"pba_hook_last {1 if on else 0}"})
    call("console_exec", {"realm": "client", "cmd": f"pba_cl_hook_last {1 if on else 0}"})
    want = "true" if on else "false"
    for realm in ("server", "client"):
        for _ in range(30):
            if lua(realm, f"return (pba.emitChainOn == true) == {want}") is True:
                break
            time.sleep(0.5)
        else:
            return f"{realm}: pba.emitChainOn did not become {want}"
    return None


def run(realm):
    r = call("lua_job", {"realm": realm, "code": CODE, "timeout_s": 60}, timeout=200)
    v = (r.get("values") or [r])[0]
    return v if isinstance(v, dict) else {"pass": False, "err": str(v)}


bad = []
for on in (True, False):
    err = set_option(on)
    if err:
        bad.append(f"option {on}: {err}")
        continue
    for realm in ("server", "client"):
        res = run(realm)
        fails = res.get("fails") or []
        print(f"option {'on ' if on else 'off'} {realm:6s}: pass={res.get('pass')} fails={len(fails)} err={res.get('err')}")
        for f in fails[:4]:
            print("    ", f)
        if on and res.get("pass") is not True:
            bad.append(f"option on, {realm}: {fails[:3] or res.get('err')}")
        if not on and res.get("pass") is True:
            bad.append(f"option off, {realm}: passed (the test does not see the bug)")
set_option(True)
print("PASS" if not bad else "FAIL: " + "; ".join(bad))
sys.exit(0 if not bad else 1)
