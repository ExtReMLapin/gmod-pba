"""T4 menu_config_static: every pba option has its switch. Pure (no game, no lupa: the two Lua files are
read as text), runs in CI.

Usage: python -I menu_config_static.py [mcp.py]     (the argument of the other tests is accepted, ignored)
Checks (each failure prints a FAIL line, the last line is 'n/m passed'):
  1. every entry of A.CONFIG in lua/pba/sh_config.lua parses: unique name, default within [min, max],
     scope sv|cl, a non-empty help in English (ASCII, several words)
  2. every control of lua/pba/cl_menu.lua (chk / sld / tip / panel:CheckBox "pba_x") targets an existing
     option; the other pba_* names the menu touches are convars or commands created elsewhere in lua/pba
  3. every option is in the menu or in EXEMPT below (with its reason); an exemption of an option that
     now has a control, or of an unknown option, fails (the list cannot go stale)
  4. every boolean whose help documents its position 0 ("0 = ...", "(0: ...", "Off: ...") has a row in
     test/option_sweep_expect.json, the table of what position 0 must give (test T7 option_sweep)
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUA = os.path.join(ROOT, "lua", "pba")
EXPECT = os.path.join(ROOT, "test", "option_sweep_expect.json")

# Options with no control in the menu, and why. Tunings of a model constant (a number a player never
# needs), developer switches, and options whose control would have no effect worth a click.
# "GAP" marks a behaviour switch that should have a checkbox: listed so the gap stays visible.
EXEMPT = {
    "report": "developer: publishes paths on the mcpagent channel",
    "water_planes": "GAP: behaviour switch (water between source and listener), no checkbox yet",
    "split_db": "model constant of the voice split (with split_angle)",
    "split_angle": "model constant of the voice split",
    "trans_window_db": "model constant: transmission voice window (the soft edge has its checkbox)",
    "max_voices": "model budget, rarely changed",
    "max_active": "global voice budget, rarely changed",
    "edge_dup_blend_u": "model constant of the edge blend (the blend has its checkbox)",
    "diffuse_near": "model constant of the diffuse model",
    "probe_spacing": "probe grid constant (changes the graph and its cache)",
    "diff_max_edge": "model constant: cap of one diffraction",
    "diff_max_total": "model constant: cap of the path diffraction",
    "trans_max": "model constant: cap of the transmission loss",
    "trans_max_walls": "model constant: walls crossed by the transmission trace",
    "trans_prop_min": "model constant: smallest prop that blocks",
    "probe_field_ms": "performance constant of the probe field refresh",
    "trans_bundle_r": "model constant of the transmission bundle (the bundle has its checkbox)",
    "lp1_db": "model constant: low-pass level thresholds (lp1..lp4)",
    "lp2_db": "model constant: low-pass level thresholds",
    "lp3_db": "model constant: low-pass level thresholds",
    "lp4_db": "model constant: low-pass level thresholds",
    "dsp_lp2": "engine DSP preset number of level 2 (levels 1 and 3 have sliders)",
    "dsp_lp4": "engine DSP preset number of level 4",
    "probe_dist": "performance constant: distance of the probe search",
    "native_max_probes": "pathing bake constant (the pathing has its checkbox)",
    "native_probe_spacing": "pathing bake constant",
    "min_level": "model constant: lowest SNDLVL processed",
    "cache_ttl": "performance constant: result cache lifetime",
}

# pba_* names the menu uses that are not entries of A.CONFIG: name -> file (under lua/pba) that creates it
NON_CONFIG = {"native_hrtf": "cl_native.lua", "native_restart": "cl_menu.lua", "menu": "cl_menu.lua"}

fails, total = [], 0


def check(ok, msg):
    global total
    total += 1
    if not ok:
        fails.append(msg)
        print("FAIL " + msg)


def read(p):
    with open(p, encoding="utf-8", newline="") as f:
        return f.read()


def parse_config():
    s = read(os.path.join(LUA, "sh_config.lua"))
    i = s.index("A.CONFIG = {")
    j = s.index("\n}", i)
    rx = re.compile(r'\s*(\w+)\s*=\s*\{\s*([-\d.eE+]+),\s*([-\d.eE+]+),\s*([-\d.eE+]+),\s*"(sv|cl)",\s*"((?:[^"\\]|\\.)*)"\s*\},?\s*$')
    cfg = {}
    for ln in s[i:j].splitlines()[1:]:
        t = ln.strip()
        if not t or t.startswith("--"):
            continue
        m = rx.match(ln)
        check(m is not None, "sh_config.lua: line does not parse as name = { default, min, max, scope, help }: " + t[:80])
        if not m:
            continue
        name = m.group(1)
        check(name not in cfg, f"{name}: defined twice")
        cfg[name] = dict(default=float(m.group(2)), min=float(m.group(3)), max=float(m.group(4)), scope=m.group(5),
                         help=m.group(6).replace('\\"', '"'))
    return cfg


def menu_refs(menu):
    refs = set()
    # chk(panel, "label", "name"...) / sld(...), also through dep( ... ); labels may hold \" escapes
    for m in re.finditer(r'\b(?:chk|sld)\(\s*\w+\s*,\s*"(?:[^"\\]|\\.)*"\s*,\s*"(\w+)"', menu):
        refs.add(m.group(1))
    for m in re.finditer(r'\btip\(\s*"(\w+)"', menu):
        refs.add(m.group(1))
    # controls bound by hand to a convar
    for m in re.finditer(r':\w+\(\s*"(?:[^"\\]|\\.)*"\s*,\s*"pba_(\w+)"', menu):
        refs.add(m.group(1))
    return refs


cfg = parse_config()
check(len(cfg) >= 150, f"only {len(cfg)} options parsed (expected about 200: the parser lost some)")

# 1. entries
for n, c in cfg.items():
    check(c["min"] <= c["default"] <= c["max"], f"{n}: default {c['default']} outside [{c['min']}, {c['max']}]")
    h = c["help"].strip()
    check(len(h.split()) >= 3 and h.isascii(), f"{n}: help missing, too short or not plain English")

# 2. menu -> options
menu = read(os.path.join(LUA, "cl_menu.lua"))
refs = menu_refs(menu)
check(len(refs) >= 100, f"only {len(refs)} menu controls found (the parser lost some)")
other = {}
for r in sorted(refs):
    if r in cfg:
        continue
    f = NON_CONFIG.get(r)
    check(f is not None, f"cl_menu.lua targets pba_{r}, which is not an option of A.CONFIG (and not in NON_CONFIG)")
    if f:
        src = read(os.path.join(LUA, f))
        check(re.search(r'(?:CreateClientConVar|concommand\.Add)\(\s*"pba_' + r + '"', src) is not None,
              f"pba_{r} is not created in {f}")
        other[r] = f

# 3. options -> menu or exemption
in_menu = {r for r in refs if r in cfg}
for n in cfg:
    if n not in in_menu:
        check(n in EXEMPT, f"{n}: no control in cl_menu.lua and not in EXEMPT (add a checkbox/slider, or exempt it with a reason)")
for n, why in EXEMPT.items():
    check(n in cfg, f"EXEMPT lists {n}, which is not an option")
    check(n not in in_menu, f"EXEMPT lists {n}, which has a menu control now: remove the exemption")
    check(bool(why.strip()), f"EXEMPT {n}: empty reason")

# 4. booleans with a documented position 0 -> expectation table
DOC0 = re.compile(r"(?:^|[\s(])0\s*=|\(0:|\b0:\s|\bOff[:,]|\(0\b", re.I)
try:
    table = json.load(open(EXPECT, encoding="utf-8"))
except OSError:
    table = None
    check(False, "test/option_sweep_expect.json is missing")
if table is not None:
    documented = [n for n, c in cfg.items() if c["min"] == 0 and c["max"] == 1 and DOC0.search(c["help"])]
    for n in documented:
        check(n in table, f"{n}: its help documents position 0 but test/option_sweep_expect.json has no row")
    for n, row in table.items():
        check(n in cfg, f"option_sweep_expect.json: {n} is not an option")
        check(isinstance(row, dict) and row.get("pos0") in ("differs", "same", "hook") and bool(row.get("why")),
              f"option_sweep_expect.json: {n}: needs pos0 in differs/same/hook and a why")

# 5. each control on the page of its realm: a server option (sv) on the Server page (admin only: a player's
# checkbox would do nothing), a client option (cl) on the Player or Native page (on the Server page an
# admin would only set his own client)
page_of = {}
for name, body in re.findall(r"function Build\.(\w+)\(panel\)(.*?)\nend", menu, re.S):
    for r in menu_refs(body):
        page_of[r] = name
check(len(page_of) >= 100, f"only {len(page_of)} controls placed on a page (the page parser lost some)")
for r, page in sorted(page_of.items()):
    if r in cfg:
        want = "server" if cfg[r]["scope"] == "sv" else "player/native"
        check((page == "server") == (cfg[r]["scope"] == "sv"),
              f"{r}: {cfg[r]['scope']} option on the {page} page (belongs on the {want} page)")

print(f"{total - len(fails)}/{total} passed" + ("" if not fails else f"; {len(fails)} FAIL"))
sys.exit(1 if fails else 0)
