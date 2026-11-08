"""Snapshot / restore of every pba_* convar around a test run.

Tests force settings (pba_native_render, pba_native_all, reverb...) to measure one thing. Without
this, a test that fails, raises or is interrupted half-way leaves the player's settings changed,
and GMod archives them on the next config write. Usage, right after the test defines call():

    import _cvsnap
    _cvsnap.guard(call)

guard() takes the snapshot now and restores it at interpreter exit (normal end, sys.exit,
uncaught exception, Ctrl+C). A killed process cannot restore anything: never kill a test.
"""
import atexit

_SNAP_LUA = """local t = {} for n, c in pairs(pba.CONFIG) do if c[4] == '%s' then
  local cv = GetConVar('pba_' .. n) if cv then t[n] = cv:GetString() end end end return t"""


def snapshot(call):
    snap = {}
    for realm, scope in (("client", "cl"), ("server", "sv")):
        try:
            r = call("lua_exec", {"realm": realm, "code": _SNAP_LUA % scope})
            vals = (r or {}).get("values") or [{}]
            snap[realm] = vals[0] or {}
        except BaseException:
            snap[realm] = {}
    return snap


def restore(call, snap):
    if not snap:
        return
    now = snapshot(call)
    changed = []
    for realm, values in snap.items():
        for name, v in values.items():
            if now.get(realm, {}).get(name) != v:
                try:
                    call("console_exec", {"realm": realm, "cmd": f"pba_{name} {v}"})
                    changed.append(f"pba_{name}={v}")
                except BaseException:
                    pass
    if changed:
        print("restored settings: " + " ".join(changed), flush=True)


def guard(call):
    snap = snapshot(call)
    atexit.register(restore, call, snap)
    return snap
