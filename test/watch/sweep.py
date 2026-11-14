"""Campaign sweeper: plays maps' scripted content under the pba anomaly watchdog and reports anomalies.

Usage: MCP_INSTANCE=<id> python -I -u sweep.py <path to mcp.py> map [map ...] [--secs=240] [--idle=20]
        [--dwell=3] [--set=pba_x=v,pba_y=w] [--tag=name] [--precl=client_file.lua] [--presv=server_file.lua]
        [--spots=x,y,z;x,y,z --spotwait=30]
Per map: load it (singleplayer), load watchdog_sv.lua / watchdog_cl.lua into the instance, god mode, wait
--idle s at the spawn (scenes and speakers that run from map start), then walk the player through the
map's trigger_once / trigger_multiple volumes (nearest first from the spawn, never trigger_changelevel /
trigger_teleport / trigger_hurt), --dwell s in each, until --secs. At the end: client and server reports,
Lua errors from pba files (errors_since), and the speech events checked against the mouth drivers:
  mouth_missing  a line on a face that neither the engine nor a pba mouth copy plays on the face (still mouth)
  lip_delay    pba's propagation delay (pba_delay) puts a lip-synced line > 80 ms behind its mouth
  speech_silent  a line pba took from the engine (no engine channel on the face) that nothing on the client
               rendered within 1.5 s (+ its delay): no module voice above -60 dB that lived past 0.5 s, no engine
               emission from the client's Lua, no mirror patch playing (its caption shows, the line is never heard)
Writes test/watch/last/<map>[__tag].json and prints a one-line summary per map.
"""
import json, os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
args = [a for a in sys.argv[1:] if not a.startswith("--")]
opts = dict(a[2:].split("=", 1) if "=" in a else (a[2:], "1") for a in sys.argv[1:] if a.startswith("--"))
if len(args) < 2:
    print(__doc__)
    sys.exit(3)
MCP, MAPS = args[0], args[1:]
SECS, IDLE, DWELL = float(opts.get("secs", 240)), float(opts.get("idle", 20)), float(opts.get("dwell", 3))
SETS = [kv.split("=", 1) for kv in opts.get("set", "").split(",") if "=" in kv]
TAG = opts.get("tag", "")
SPEED = 343 / 0.01905
os.makedirs(os.path.join(HERE, "last"), exist_ok=True)


def call(tool, a, mx=400000, timeout=600):
    s = json.dumps(a)
    tmp = None
    if len(s) > 20000:
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as f:
            f.write(s)
        tmp = f.name
        s = "@" + tmp
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, s, str(mx)], capture_output=True, text=True,
                         encoding="utf-8", timeout=timeout).stdout
    if tmp:
        os.remove(tmp)
    try:
        return json.loads(out)
    except ValueError:
        return {"raw": out}


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


PAGE = 60000  # gmod-mcp returns a string over 64 KiB as {__type: string, truncated: true}: fetched in pages


def lua_json(realm, expr, default):
    """The JSON string `expr` evaluates to in `realm`, decoded, fetched in pages of PAGE characters (a report's
    rendered list reached 150 KB on d3_c17_10b: returned truncated, it was read as an empty list and every line
    the server took from the engine counted as speech_silent)."""
    n = lua(realm, f"PBA_WATCH_JSON = {expr} or '' return #PBA_WATCH_JSON")
    if not isinstance(n, (int, float)):
        raise RuntimeError(f"lua_json {realm} {expr}: {n!r}")
    parts = []
    for i in range(0, int(n), PAGE):
        p = lua(realm, f"return string.sub(PBA_WATCH_JSON, {i + 1}, {i + PAGE})")
        if not isinstance(p, str):
            raise RuntimeError(f"lua_json {realm} {expr} page {i}: {type(p).__name__}")
        parts.append(p)
    s = "".join(parts)
    if len(s) != int(n):
        raise RuntimeError(f"lua_json {realm} {expr}: {len(s)} of {int(n)} characters")
    return json.loads(s) if s else default


def wait_lua(realm, code, timeout=60):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if lua(realm, code) is True:
            return True
        time.sleep(1)
    return False


def lua_file(realm, path):
    with open(path, encoding="utf-8") as f:
        return call("lua_exec", {"realm": realm, "code": f.read()})


TRIGGERS = r"""
local out = {}
for _, e in ipairs(ents.GetAll()) do
	local c = e:GetClass()
	if c == "trigger_once" or c == "trigger_multiple" or c == "trigger_look" then
		local mn, mx = e:WorldSpaceAABB()
		out[#out + 1] = { idx = e:EntIndex(), c = c, name = e:GetName(), x = (mn.x + mx.x) / 2, y = (mn.y + mx.y) / 2, z = mn.z + 8 }
	end
end
local scenes = #ents.FindByClass("logic_choreographed_scene")
local p = Entity(1)
return { trig = out, scenes = scenes, spawn = { p:GetPos().x, p:GetPos().y, p:GetPos().z } }
"""


def order(trig, start):
    left, cur, seq = list(trig), start, []
    while left:
        i = min(range(len(left)), key=lambda k: (left[k]["x"] - cur[0]) ** 2 + (left[k]["y"] - cur[1]) ** 2 + (left[k]["z"] - cur[2]) ** 2)
        t = left.pop(i)
        seq.append(t)
        cur = (t["x"], t["y"], t["z"])
    return seq


def mouth_check(speech, copies, delay_on, enabled):
    """mouth_missing: a line on a face that pba took from the engine (no engine channel on the face) with no
    pba mouth copy on that face within 1 s (+ the voice's delay): the face says nothing. lip_delay: pba's
    propagation delay puts a lip-synced line > 80 ms behind its mouth."""
    found = {"mouth_missing": [], "lip_delay": []}
    for ev in speech:
        lag = ev["dist"] / SPEED if (delay_on and enabled and ev["dist"] > 0) else 0
        if lag > 0.08:
            found["lip_delay"].append({"class": ev["class"], "name": ev["name"], "dist": ev["dist"], "lagMs": round(lag * 1000), "t": ev["t"]})
        if ev.get("engine") or ev.get("mouthSv") or not enabled:
            continue
        ts = copies.get(str(ev["idx"])) or []
        if not any(ev["t"] - 0.05 <= t <= ev["t"] + 1 + lag for t in ts):
            found["mouth_missing"].append({"class": ev["class"], "name": ev["name"], "dist": ev["dist"], "t": ev["t"], "pos": ev.get("pos"), "via": ev.get("via")})
    return found


def fkey(name):
    return name.lstrip("*#@><^)(}$!?&~`+%").replace("\\", "/").lower()


def silent_check(speech, rendered, delay_on, enabled):
    """speech_silent: a line taken from the engine (ev not engine) with no client rendering of its file within
    [t - 0.1, t + 1.5 + lag] that stayed alive (a module voice dead within 0.5 s does not count)."""
    out = []
    if not enabled:
        return out
    for ev in speech:
        if ev.get("engine"):
            continue
        lag = ev["dist"] / SPEED if (delay_on and ev["dist"] > 0) else 0
        f = fkey(ev["name"])
        hits = [r for r in rendered if r.get("f") == f and ev["t"] - 0.1 <= r.get("t", -1) <= ev["t"] + 1.5 + lag]
        if not any(not r.get("dead") for r in hits):
            out.append({"class": ev["class"], "name": ev["name"], "dist": ev["dist"], "t": ev["t"], "pos": ev.get("pos"),
                        "killed": [r.get("dead") for r in hits if r.get("dead")]})
    return out


def report(m, t_start, cur, info, trig, visited):
    # (the long JSON fields fetched in pages, lua_json; the rest of each report without them)
    LONG = "local r = PBA_WATCH_R or {} local o = {} for k, v in pairs(r) do if not ({speech = 1, mouth = 1, census = 1, rendered = 1})[k] then o[k] = v end end return o"
    lua("server", "PBA_WATCH_R = PBA_WATCH_SV and PBA_WATCH_SV.Report() or {} return true")
    sv = lua("server", LONG) or {}
    sv["speech"] = lua_json("server", "PBA_WATCH_R.speech", [])
    lua("client", "PBA_WATCH_R = PBA_WATCH_CL and PBA_WATCH_CL.Report() or {} return true")
    cl = lua("client", LONG) or {}
    for k in ("mouth", "census", "rendered"):
        cl[k] = lua_json("client", f"PBA_WATCH_R.{k}", {} if k != "rendered" else [])
    for side in (cl, sv):
        for a in (side.get("anomalies") or {}).values():
            if isinstance(a.get("samples"), str):
                a["samples"] = json.loads(a["samples"])
    errs = call("errors_since", {"cursor": cur, "limit": 500}).get("errors", [])
    pba_errs = {}
    for e in errs:
        msg = e.get("message") or e.get("text") or json.dumps(e)
        blob = msg + json.dumps(e.get("stack", ""))
        if "pba" in blob and "watchdog" not in blob:
            pba_errs[msg] = pba_errs.get(msg, 0) + 1
    mc = mouth_check(sv.get("speech") or [], cl.get("mouth") or {}, sv.get("delay", 0) >= 0.5, sv.get("enabled", 1) >= 0.5)
    rend = cl["rendered"]
    mc["speech_silent"] = silent_check(sv.get("speech") or [], rend, sv.get("delay", 0) >= 0.5, sv.get("enabled", 1) >= 0.5)
    anomalies = {}
    for side in (cl.get("anomalies") or {}, sv.get("anomalies") or {}):
        anomalies.update(side)
    for k, lst in mc.items():
        if lst:
            anomalies[k] = {"count": len(lst), "distinct": len({x["name"] for x in lst}), "samples": lst[:6]}
    if pba_errs:
        anomalies["lua_error"] = {"count": sum(pba_errs.values()), "distinct": len(pba_errs),
                                  "samples": [{"msg": k, "n": v} for k, v in list(pba_errs.items())[:6]]}
    return {"map": m, "tag": TAG, "sets": SETS, "secs": round(time.time() - t_start), "triggers": len(trig), "visited": visited,
            "scenes": info.get("scenes"), "speech": len(sv.get("speech") or []), "anomalies": anomalies,
            "loud_census": cl["census"]}


SAVED = []


def restore():
    for realm, k, was in SAVED:
        call("console_exec", {"realm": realm, "cmd": f"{k} {was}"})
    SAVED.clear()


def sweep(m):
    t_start = time.time()
    call("map_load", {"map": m, "maxplayers": 1}, timeout=300)
    time.sleep(5)
    if not wait_lua("client", "return IsValid(LocalPlayer()) and pba ~= nil", 90):
        return {"map": m, "error": "client not ready"}
    st = call("status", {})
    if st.get("map") != m:
        return {"map": m, "error": f"map not loaded ({st.get('map')})"}
    cur = 0
    while True:  # the cursor at the end of the buffer (errors of earlier maps / runs excluded)
        e = call("errors_since", {"cursor": cur, "limit": 2000})
        n = e.get("next_cursor", cur)
        if n == cur or not e.get("errors"):
            cur = n
            break
        cur = n
    # --set values: pba convars are archived (garrysmod/cfg/*.vdf, shared by every instance and the user's
    # own game): each one is restored to its value before the run at the end of the map (see restore()).
    saved = []
    for k, v in SETS:  # (every value is read BEFORE any is set: in singleplayer both realms share the convar)
        for realm in ("server", "client"):
            was = lua(realm, f"local c = GetConVar('{k}') return c and c:GetString() or nil")
            if was is not None:
                saved.append((realm, k, was))
    for k, v in SETS:
        for realm in ("server", "client"):
            call("console_exec", {"realm": realm, "cmd": f"{k} {v}"})
    SAVED[:] = saved
    lua_file("server", os.path.join(HERE, "watchdog_sv.lua"))
    lua_file("client", os.path.join(HERE, "watchdog_cl.lua"))
    if opts.get("precl"):  # validation: a client file run after the watchdog (e.g. re-creating a fixed bug)
        lua_file("client", opts["precl"])
    if opts.get("presv"):  # the same on the server (e.g. a branch's server file over the loaded one)
        lua_file("server", opts["presv"])
    lua("server", "local p = Entity(1) if IsValid(p) then p:GodEnable() end return true")
    info = lua("server", TRIGGERS)  # (a Lua table without keys comes back as a list)
    info = info if isinstance(info, dict) else {}
    trig = order(info.get("trig") or [], info.get("spawn") or (0, 0, 0))
    print(f"##progress label=\"{m}\" msg=\"idle {IDLE:.0f}s, {len(trig)} triggers, {info.get('scenes')} scenes\"", flush=True)
    time.sleep(IDLE)
    visited = 0
    for t in trig:
        if time.time() - t_start > SECS:
            break
        lua("server", f"local p = Entity(1) if IsValid(p) then if not p:Alive() then p:Spawn() p:GodEnable() end "
                      f"p:SetPos(Vector({t['x']}, {t['y']}, {t['z']})) end return true")
        visited += 1
        time.sleep(DWELL)
    for spot in [x for x in opts.get("spots", "").split(";") if x]:
        x, y, z = spot.split(",")
        lua("server", f"local p = Entity(1) if IsValid(p) then p:SetPos(Vector({x}, {y}, {z})) end return true")
        time.sleep(float(opts.get("spotwait", 30)))
    time.sleep(3)
    res = report(m, t_start, cur, info, trig, visited)
    name = m + (f"__{TAG}" if TAG else "") + ".json"
    with open(os.path.join(HERE, "last", name), "w", encoding="utf-8") as f:
        json.dump(res, f, indent=1)
    return res


if __name__ == "__main__":
    for m in MAPS:
        try:
            r = sweep(m)
        except Exception as ex:  # one map failing must not stop the sweep
            r = {"map": m, "error": repr(ex)}
        finally:
            restore()
        summ = {k: v["count"] for k, v in (r.get("anomalies") or {}).items()}
        print(f"=== {m}: {r.get('error') or ''} visited {r.get('visited')}/{r.get('triggers')} speech {r.get('speech')} anomalies {json.dumps(summ)}", flush=True)
    print("##progress done=ok", flush=True)
