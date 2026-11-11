"""Snapshot / restore of every pba_* convar around a test run.

Tests force settings (pba_native_render, pba_native_all, reverb...) to measure one thing. Without
this, a test that fails, raises or is interrupted half-way leaves the player's settings changed,
and GMod archives them on the next config write. Usage, right after the test defines call():

    import _cvsnap
    _cvsnap.guard(call)

guard() takes the snapshot now and restores it at interpreter exit (normal end, sys.exit,
uncaught exception, Ctrl+C). A killed process cannot restore anything, and the game archives what
it left (the instances share the player's config): so guard() also writes its snapshot to a journal
(JOURNAL_DIR, one file per process) and the next guard() puts back the snapshot of every process
that died without restoring it (the oldest one last: it holds the values from before them all).
"""
import atexit
import json
import os
import sys
import tempfile
import time

JOURNAL_DIR = os.path.join(tempfile.gettempdir(), "pba_cvsnap")

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


def _alive(pid):
    if pid == os.getpid():
        return True
    if sys.platform == "win32":
        import ctypes
        k = ctypes.windll.kernel32
        h = k.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not h:
            return k.GetLastError() == 5  # access denied: it exists
        code = ctypes.c_ulong()
        ok = k.GetExitCodeProcess(h, ctypes.byref(code))
        k.CloseHandle(h)
        return bool(ok) and code.value == 259  # STILL_ACTIVE
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def recover(call):
    """Restores the snapshots of guarded processes that were killed (their journal is still there)."""
    try:
        names = os.listdir(JOURNAL_DIR)
    except OSError:
        return
    dead = []
    for n in names:
        path = os.path.join(JOURNAL_DIR, n)
        try:
            pid = int(n.split(".")[0])
            if _alive(pid):
                continue
            with open(path, encoding="utf-8") as f:
                dead.append((json.load(f), path))
        except (ValueError, OSError):
            continue
    dead.sort(key=lambda e: -e[0].get("t", 0))  # newest first: the oldest snapshot is applied last
    for j, path in dead:
        print("settings left by a killed test (pid %s):" % os.path.basename(path).split(".")[0], flush=True)
        restore(call, j.get("snap"))
        try:
            os.remove(path)
        except OSError:
            pass


def _journal():
    return os.path.join(JOURNAL_DIR, "%d.json" % os.getpid())


def release(call, snap):
    """Restores snap and drops this process's journal (what atexit does)."""
    restore(call, snap)
    try:
        os.remove(_journal())
    except OSError:
        pass


def guard(call):
    recover(call)
    snap = snapshot(call)
    try:
        os.makedirs(JOURNAL_DIR, exist_ok=True)
        if not os.path.exists(_journal()):  # a second guard() in the same process keeps the first one
            with open(_journal(), "w", encoding="utf-8") as f:
                json.dump({"t": time.time(), "snap": snap}, f)
    except OSError:
        pass
    atexit.register(release, call, snap)
    return snap
