"""Scenario campaign: runs audioprop_demo scenarios in the game through the gmod-mcp server
and checks numeric assertions on the audioprop.paths reports.

Usage: python -I run_scenarios.py <path to mcp.py client> [scenario ...]
"""
import json
import subprocess
import sys
import time

MCP = sys.argv[1]
ONLY = sys.argv[2:]


def call(tool, args, mx=2_000_000):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), str(mx)],
                         capture_output=True, text=True, encoding="utf-8").stdout
    try:
        return json.loads(out)
    except Exception:
        return {"raw": out}


def lua(realm, code):
    r = call("lua_exec", {"realm": realm, "code": code})
    vals = r.get("values") if isinstance(r, dict) else None
    return vals[0] if vals else None


def ensure_map(m):
    st = call("status", {})
    if st.get("map") != m:
        call("map_load", {"map": m, "maxplayers": 4})
        lua("client", 'RunConsoleCommand("audioprop_report","1")')


def run(name, map_, wait=2.5, sound="click"):
    return run_snd(name, map_, wait, sound)


def run_snd(name, map_, wait=2.5, sound="click"):
    ensure_map(map_)
    call("reports_clear", {})
    srv0 = lua("server", "return audioprop.stats.relayed")
    call("console_exec", {"realm": "server", "cmd": f"audioprop_demo {name} {sound} 0.7"})
    time.sleep(wait)
    rep = call("reports_read", {"channel": "audioprop.paths", "limit": 50})
    items = [i["value"] for i in rep.get("items", [])]
    srv1 = lua("server", "return audioprop.stats.relayed")
    call("console_exec", {"realm": "server", "cmd": "audioprop_demo stop"})
    return items[-1] if items else None, items, (srv1 or 0) - (srv0 or 0)


results = []


def check(sid, cond, detail):
    results.append((sid, bool(cond), detail))
    print(("PASS " if cond else "FAIL ") + sid + " :: " + detail, flush=True)


def want(n):
    return not ONLY or n in ONLY


def dom(r):
    return r["voices"][0] if r and r.get("voices") else None


if want("tworooms_open"):
    r, _, _ = run("tworooms_open", "ap_tworooms")
    v = dom(r)
    check("P3-door-right", v and v["kind"] == "portal" and v["az"] > 15, f"dominant={v}")
    open_level = v["level_db"] if v else None

if want("tworooms_left"):
    r, _, _ = run("tworooms_left", "ap_tworooms")
    v = dom(r)
    check("P3-door-left", v and v["az"] < -15, f"dominant={v}")

if want("tworooms_closed"):
    r, _, _ = run("tworooms_closed", "ap_tworooms", wait=3.5)
    p = r["paths"][0] if r and r.get("paths") else None
    check("P3-door-closed-loss", p and p["door_db"] > 10, f"path={p} trans={r and r.get('trans')}")
    v = dom(r)
    if v and want("tworooms_open"):
        check("P3-door-closed-quieter", v["level_db"] < open_level - 10, f"closed={v['level_db']} open={open_level}")

if want("tworooms_half"):
    r, _, _ = run("tworooms_half", "ap_tworooms", wait=3.5)
    p = r["paths"][0] if r and r.get("paths") else None
    check("P3-door-half", p and 0 < p["door_db"] < 10, f"path={p}")

if want("noportal"):
    r, _, _ = run("noportal", "ap_noportal", wait=6)
    v = dom(r)
    check("P3-probe-right", v and v["kind"] == "portal" and v["az"] > 15, f"dominant={v} paths={r and r.get('paths')}")

if want("twodoors"):
    r, _, _ = run("twodoors", "ap_twodoors", wait=3.5)
    azs = sorted(v["az"] for v in (r or {}).get("voices", []) if v["kind"] == "portal")
    check("P3-two-doors", len(azs) >= 2 and azs[0] < -15 and azs[-1] > 15, f"voice az={azs} paths={r and r.get('paths')}")

if want("twodoors_south"):
    r, _, _ = run("twodoors_south", "ap_twodoors", wait=3.5)
    v = dom(r)
    check("P3-two-doors-south-only", v and v["az"] > 15, f"dominant={v} paths={r and r.get('paths')}")

if want("window"):
    r, _, _ = run("window", "ap_window")
    v = dom(r)
    check("P3-window-left", v and v["az"] < -15, f"dominant={v}")

if want("lcorridor"):
    r, _, _ = run("lcorridor", "ap_lcorridor")
    p = r["paths"][0] if r and r.get("paths") else None
    v = dom(r)
    check("P3-lcorridor", p and len(p["portals"]) == 3 and v and abs(v["az"]) < 30, f"path={p} dominant={v}")

mats = {}
for m in ["concrete", "brick", "wood", "metal", "glass", "plaster"]:
    if want("mat_" + m):
        r, _, _ = run("mat_" + m, "ap_materials")
        t = r and r.get("trans")
        v = dom(r)
        mats[m] = t["loss_db"] if t else None
        check(f"P3-mat-{m}", t and v and v["kind"] == "transmission" and abs(v["az"]) < 10, f"trans={t} voice={v}")
if "concrete" in mats and "wood" in mats and mats["concrete"] and mats["wood"]:
    check("P3-concrete-gt-wood", mats["concrete"] > mats["wood"], f"losses={mats}")

if want("prop_wall"):
    r, _, _ = run("prop_wall", "gm_flatgrass", wait=3)
    v = dom(r)
    t = r and r.get("trans")
    check("P3-prop-sheet-metal", v and v["kind"] == "transmission" and abs(v["az"]) < 10 and t and t["loss_db"] < 40 and (v.get("vol") or 0) > 0.01,
          f"trans={t} voice={v}")

if want("loud_through_concrete"):
    rv, _, _ = run_snd("mat_concrete", "ap_materials", 3, "voice")
    rg, _, _ = run_snd("mat_concrete", "ap_materials", 3, "gun")
    vv, vg = dom(rv), dom(rg)
    check("P3-loud-headroom", vv and vg and vg["level_db"] > vv["level_db"] + 15 and (vg.get("vol") or 0) > 0.01,
          f"voice={vv} gun={vg}")

def trans_loss(r):
    t = r and r.get("trans")
    return t["loss_db"] if t else None


if want("obs_can"):
    r, items, relayed = run("obs_can", "gm_flatgrass", wait=3)
    v = dom(r)
    check("O-can", not items or (trans_loss(r) or 0) < 3, f"reports={len(items)} trans={r and r.get('trans')} voice={v}")

if want("obs_car"):
    r, items, _ = run("obs_car", "gm_flatgrass", wait=3)
    tl = trans_loss(r)
    check("O-car", tl is not None and 1 < tl < 15, f"trans={r and r.get('trans')} voice={dom(r)}")

if want("obs_container"):
    r, items, _ = run("obs_container", "gm_flatgrass", wait=3)
    tl = trans_loss(r)
    check("O-container", tl is not None and tl > 4, f"trans={r and r.get('trans')} voice={dom(r)}")

if want("obs_crate"):
    r, items, _ = run("obs_crate", "gm_flatgrass", wait=3)
    tl = trans_loss(r)
    check("O-crate-enclosed", tl is not None and tl > 10, f"trans={r and r.get('trans')} voice={dom(r)}")

if want("obs_crowd"):
    r, items, relayed = run("obs_crowd", "gm_flatgrass", wait=3)
    check("O-crowd-untouched", not items and relayed == 0, f"reports={len(items)} relayed={relayed}")

if want("open_field"):
    r, items, relayed = run("open_field", "gm_flatgrass")
    check("P3-open-field-untouched", not items and relayed == 0, f"reports={len(items)} relayed={relayed}")

ok = sum(1 for _, c, _ in results if c)
print(f"\n{ok}/{len(results)} passed")
json.dump([{"id": i, "pass": c, "detail": d} for i, c, d in results], open("scenario_results.json", "w"), indent=1)
