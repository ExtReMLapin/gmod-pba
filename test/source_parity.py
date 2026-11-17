"""Source-parity differential test: the ENGINE is the oracle.

Why. Six Workshop reports of 2026-11-17 were lifecycle / timing / listening-position gaps between pba and the engine
(an antlion's flight loop never stopped, physics scrapes never rendered, the antlion guard's near steps silent one in
two, automatic fire cut at arrival instead of at start, the camera view's own sounds glued to the ear, bullet whizzes
played by the engine through no hook). Our tests never saw them: they check OUR reading of the engine. This one runs
the same scripted scenario twice in the same game and compares the two:

  oracle run  pba off (pba_enable 0, pba_cl_enable 0): what the engine plays, read every frame from its own channel
              list (snd_dumpclientsounds: one line per mixer channel, "SERVER" or "CLIENT" side, file, entity, channel,
              left / right / volume, time left), written by test/source_parity_cl.lua (MsgN marker + the command each
              frame) and read back from the console buffer (console_read).
  pba run     pba on, native rendering (defaults). Alive = the module's voices (pba_native.Play / Update / StopVoice /
              SetListener wrapped by source_parity_cl.lua: start, stop, death, file length; nothing of pba's own
              state is read, so it works on any version of the Lua) + whatever the engine still plays (same dump).
              The EntityEmitSound calls of both realms are recorded too (hooks named "!aaa_par_hook", first in order).

Comparison, by sound file (sound characters stripped, variants 1/2/3 of a file are one family), instance by instance
(an instance of the engine = a channel followed from frame to frame by its time left; a looped sound the engine stops
and restarts closer than 0.6 s is one). pba's muffling, reverb, paths, echoes and levels are out of scope: only
existence, lifecycle and time, plus the listening position of the player's own sounds. Gaps, times in seconds after
the scenario's start (same script, same clock in both runs):
  MISSING      an engine instance has no pba counterpart (never played, or cut before it was audible)
  EXTRA        a pba instance the engine does not play
  LATE / EARLY starts more than tol_start apart
  OVERRUN      pba plays on after the engine's end: a loop nobody stopped
  CUT          pba ends before the engine
  COUNT        (AI scenarios) number of instances of a family differs by more than 25 % (a near step silent one in two)
  PASSTHROUGH  the engine plays it in the pba run and pba never took it: a server channel left playing, or a client
               channel no EntityEmitSound hook announced (an unrendered sound: scrapes before they were followed,
               bullet whizzes)
  LISTEN       own sound whose listener-to-source distance is under 15 % of the engine's (camera view: collapsed on the ear)
Scenarios (gm_construct, singleplayer, source_parity_sv.lua): antlion_flight, guard_walk, physics_scrape, ar2_burst (two
250 ms frame hitches during the burst), camera_view (gmod_cameraprop), combine_whiz. AI scenarios are not frame exact
(the engine's own run-to-run noise was measured with --noise: oracle against oracle): they check the looped sounds
instance by instance and a few families by count (SCENARIOS, below).
Known and wanted differences are listed in EXPECTED (a reason each); any other gap turns the verdict red.

Usage:  python -I -u test/source_parity.py <mcp.py> [scenario,...] [--noise] [--save=DIR] [--load=DIR]
          --noise  a second oracle run per scenario: the engine's run-to-run noise (reported, not judged)
          --save   writes the raw runs (json); --load analyses saved runs again without a game
        MCP_INSTANCE=<id> picks the game. About 4 minutes. Exit 0 / 1; the last line is a JSON verdict.
Needs gmod-mcp and the native module (pba_native_render 1); the driver loads gm_construct and restores pba_enable /
pba_cl_enable. Run the old Lua with instances_launch {lua_mount: <worktree of a commit>}: the oracle must turn red on it.
Limits: a sound shorter than a frame (33 ms at the test clients' 30 fps) and everything inside a frame hitch is invisible
to the dump (hitch windows are skipped, in both runs); the oracle sees lifecycle and time, not level or path, so a
sound the engine plays that pba leaves to it (the whizz) differs only as PASSTHROUGH; the dump lists the CLIENT's mixer.
"""
import json
import os
import re
import sys
import time
from collections import Counter, defaultdict

TEST = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TEST)

DUMP_RE = re.compile(
    r"(CLIENT|SERVER) l\(\s*(-?\d+)\) c\(\s*(-?\d+)\) r\(\s*(-?\d+)\) rl\(\s*(-?\d+)\) rr\(\s*(-?\d+)\) vol\(\s*(-?\d+)\)"
    r" pos\(\s*(-?\d+)\s+(-?\d+)\s+(-?\d+)\) timeleft\(\s*(-?[\d.]+)\) looped\((\d)\)\s+(\S+)\s+chan:(-?\d+) ent\((-?\d+)\):(.*)$")
MARK_RE = re.compile(r"@@S (\d+\.\d+)")
PREFIX_RE = re.compile(r"^[\^\)\*#@<>!\?\$&~`+%\(}]+")


def norm(name):
    """The file of a sound name: sound characters stripped, forward slashes, lower case, no sound/ folder."""
    n = PREFIX_RE.sub("", name.strip()).replace("\\", "/").lower()
    return n[6:] if n.startswith("sound/") else n


# ---------------------------------------------------------------------------------------------- scenarios
# tolerances: start window within which an engine instance and a pba instance are the same event (matching), and
# the allowed gap of starts / ends. AI-driven scenarios are not frame exact: wider.
SCENARIOS = {
    # AI scenarios (not frame exact: the engine's own run-to-run noise was measured, oracle against oracle): only the
    # families of `focus` are checked for PASSTHROUGH, those of `count` by number (+-25 %, at least 1), looped sounds
    # instance by instance. `ignore`: families that differ run to run (impacts); `settle` / `until`: the seconds of the
    # scenario compared (the first instants of a held trigger, a prop coming to rest).
    "antlion_flight": dict(map="gm_construct", dur=16, match=4.0, tol_start=4.0, tol_end=0.6, ai=True, relative=True, focus=[], count=[]),
    "guard_walk": dict(map="gm_construct", dur=12, match=1.5, tol_start=1.0, tol_end=0.8, ai=True, focus=[r"foot"], count=[r"foot"], ignore=[r"growl"]),
    "physics_scrape": dict(map="gm_construct", dur=6.5, match=1.5, tol_start=0.6, tol_end=1.2, ai=False, ignore=[r"impact"], until=4.5),
    "ar2_burst": dict(map="gm_construct", dur=4.5, match=0.4, tol_start=0.3, tol_end=0.3, ai=False, ignore=[r"impact"], settle=0.4, until=2.5),
    "camera_view": dict(map="gm_construct", dur=8, match=0.6, tol_start=0.3, tol_end=0.3, ai=False, own_files=["weapons/ar2/fire1.wav"]),
    "combine_whiz": dict(map="gm_construct", dur=10, match=2.0, tol_start=1.0, tol_end=1.0, ai=True, focus=[r"nearmiss"], count=[]),
}

# Sounds that never take part (ambient beds and the like that differ by design or run on their own clock).
IGNORE = [r"^ambient/", r"^npc/.*/(idle|breath)"]

# Known and wanted differences: (scenario, file regex, kind) -> reason. Keep it short and honest.
EXPECTED = {
    ("combine_whiz", r"nearmiss", "PASSTHROUGH"): "the engine's tracer whizz is a client effect that reaches no hook: left to the engine (pba_native_whiz is off by default, by decision); the oracle cannot tell its path, only that pba never takes it",
}


# ---------------------------------------------------------------------------------------------- analysis
def parse_console(lines):
    """[(sysTime, [ {file, ent, chan, l, r, vol, timeleft, looped} ... ]) ...] from the console lines of a run."""
    samples = []
    cur = None
    for ln in lines:
        txt = ln.get("text", "")
        m = MARK_RE.search(txt)
        if m:
            cur = (float(m.group(1)), [])
            samples.append(cur)
            continue
        m = DUMP_RE.search(txt)
        if m and cur is not None:
            g = m.groups()[1:]
            cur[1].append(dict(file=norm(g[11]), raw=g[11], ent=int(g[13]), chan=int(g[12]), l=int(g[0]), r=int(g[2]),
                               vol=int(g[5]), timeleft=float(g[9]), looped=int(g[10]), cls=g[14].strip(), side=m.group(1)))
    return samples


def engine_instances(samples, origin):
    """Per file: instances [{s, e, kind, looped}] from the channels of that file at each sample. An open instance is
    followed from sample to sample by its time left (it can only go down: a larger one is a restart, a new instance:
    a weapon sound replaced on its channel within one frame keeps the count but not the clock); a looped one by order."""
    inst = defaultdict(list)
    open_ = defaultdict(list)  # file -> [(instance, last timeleft)]
    first = True
    prev_t = None
    for t, chans in samples:
        now = defaultdict(list)
        for c in chans:
            now[c["file"]].append(c)
        for f in set(now) | set(open_):
            cur = sorted(now.get(f, []), key=lambda c: -c["timeleft"])
            op = sorted(open_[f], key=lambda x: -x[1])
            new_open = []
            used = set()
            for i, last in op:
                best = None
                for k, c in enumerate(cur):
                    if k in used:
                        continue
                    ok = c["looped"] or c["timeleft"] <= last + 0.02
                    if ok and (best is None or abs((last - (t - prev_t)) - c["timeleft"]) < best[0]):
                        best = (abs((last - (t - prev_t)) - c["timeleft"]), k)
                if best:
                    used.add(best[1])
                    new_open.append((i, cur[best[1]]["timeleft"]))
                else:
                    i["e"] = prev_t - origin  # last seen at the previous sample
            for k, c in enumerate(cur):
                if k not in used:
                    i = dict(s=t - origin, e=None, kind="engine", openStart=first, looped=c["looped"], side=c["side"], ent=c["ent"], chan=c["chan"], cls=c["cls"])
                    inst[f].append(i)
                    new_open.append((i, c["timeleft"]))
            open_[f] = new_open
        first = False
        prev_t = t
    return inst


def native_instances(voices, origin, endt, first_t=None):
    """Module voices as instances: [start = t + delay, end = stop / death / file length, open = still alive]."""
    inst = defaultdict(list)
    for v in voices:
        s = v["t"] + v["delay"]
        ends = []
        if v.get("tStop") is not None:
            ends.append(v["tStop"])
        if v.get("tDead") is not None:
            ends.append(v["tDead"])
        if not v["loop"] and v.get("dur"):
            ends.append(s + v["dur"])
        e = min(ends) if ends else None
        if e is not None and e < s:
            e = s
        if first_t is not None and e is not None and e < first_t:
            continue  # over before the sampling began (the scenario's setup)
        if e is not None and not v["loop"] and e - s < 0.02:
            continue  # stopped before it was audible (cut when its replacement ARRIVED, before its own start): not a sound
        if first_t is not None and s < first_t:
            s_cmp = first_t  # alive before the sampling began: its start is the first sample, as an engine instance's
        else:
            s_cmp = s
        inst[v["file"]].append(dict(s=s_cmp - origin, e=(e - origin) if e is not None else None, kind="native", id=v["id"],
                                    loop=v["loop"], pos=v.get("pos"), openStart=first_t is not None and s < first_t))
    return inst


def merge_kinds(a, b, win=0.25):
    """pba's alive set: native voices + engine instances; an engine copy beside a native voice of the same file
    (a mouth copy, an anchor copy) starting within `win` of it is the same event, kept once (the native one)."""
    out = defaultdict(list)
    for f in set(a) | set(b):
        nat = list(a.get(f, []))
        eng = []
        for i in b.get(f, []):
            dup = [n for n in nat if abs(n["s"] - i["s"]) <= win]
            if not dup:
                eng.append(i)
        out[f] = sorted(nat + eng, key=lambda x: x["s"])
    return out


def merge_gaps(lst, gap):
    """A looped sound the engine stops and restarts (a scrape below its volume threshold) is one sound for the ear:
    instances closer than `gap` are one."""
    out = []
    for i in sorted(lst, key=lambda x: x["s"]):
        if out and out[-1]["e"] is not None and i["s"] - out[-1]["e"] < gap:
            out[-1] = dict(out[-1], e=i["e"])
        else:
            out.append(dict(i))
    return out


def match(o_list, p_list, window):
    """Greedy matching by nearest start within `window`. -> pairs, unmatched o, unmatched p."""
    o_list = sorted(o_list, key=lambda x: x["s"])
    p_free = sorted(p_list, key=lambda x: x["s"])
    pairs, miss = [], []
    for o in o_list:
        best = None
        for p in p_free:
            d = abs(p["s"] - o["s"])
            if d <= window and (best is None or d < best[0]):
                best = (d, p)
        if best:
            p_free.remove(best[1])
            pairs.append((o, best[1]))
        else:
            miss.append(o)
    return pairs, miss, p_free


FAMILY_RE = re.compile(r"\d+(\.\w+)$")


def family(f):
    """near_foot_heavy1.wav and near_foot_heavy2.wav are one family: the variant is drawn at random."""
    return FAMILY_RE.sub(lambda m: m.group(1), f)


def by_family(inst):
    out = defaultdict(list)
    for f, lst in inst.items():
        out[family(f)] += lst
    return out


def blind_windows(samples, origin):
    """Stretches where the sampler saw nothing (a frame hitch: no frame, no dump): events inside them cannot be compared."""
    ts = [t - origin for t, _ in samples]
    if len(ts) < 3:
        return []
    gaps = sorted(b - a for a, b in zip(ts, ts[1:]))
    med = gaps[len(gaps) // 2]
    return [(a, b) for a, b in zip(ts, ts[1:]) if b - a > max(0.12, 3 * med)]


def in_blind(t, blind, pad=0.15):
    return t is not None and any(a - pad <= t <= b + pad for a, b in blind)


def compare(oracle_inst, pba_inst, sc, run_end, blind=()):
    """The gaps, a list of dicts {kind, file, ...}. Deterministic scenarios: instance by instance. AI scenarios: the
    families of sc['focus'] by count, the looped ones instance by instance."""
    gaps = []
    oracle_inst, pba_inst = by_family(oracle_inst), by_family(pba_inst)
    for f in sorted(set(oracle_inst) | set(pba_inst)):
        if any(re.search(p, f) for p in IGNORE + sc.get("ignore", [])):
            continue
        if sc.get("ai"):
            looped = any(i.get("looped") for i in oracle_inst.get(f, [])) or any(i.get("loop") for i in pba_inst.get(f, []))
            if any(re.search(p, f) for p in sc.get("count", [])) and not looped:
                no, npb = len(oracle_inst.get(f, [])), len(pba_inst.get(f, []))
                if abs(no - npb) > max(1, 0.25 * max(no, npb)):
                    gaps.append(dict(kind="COUNT", file=f, oracle=no, pba=npb))
                continue
            if not looped:
                continue
        oi, pi = oracle_inst.get(f, []), pba_inst.get(f, [])
        if sc.get("until"):  # what the scenario leaves to settle after its action (a prop coming to rest) is not compared
            oi, pi = [i for i in oi if i["s"] <= sc["until"]], [i for i in pi if i["s"] <= sc["until"]]
        if sc.get("settle"):  # the first instants of a scripted action (a held trigger's first shots) differ run to run
            oi, pi = [i for i in oi if i["s"] >= sc["settle"]], [i for i in pi if i["s"] >= sc["settle"]]
        if any(i.get("looped") or i.get("loop") for i in oi + pi):
            oi, pi = merge_gaps(oi, sc.get("loop_gap", 0.6)), merge_gaps(pi, sc.get("loop_gap", 0.6))
        pairs, miss, extra = match(oi, pi, sc["match"])
        for o in miss:
            if not in_blind(o["s"], blind):
                gaps.append(dict(kind="MISSING", file=f, s=o["s"], e=o["e"]))
        for p in extra:
            if not in_blind(p["s"], blind):
                gaps.append(dict(kind="EXTRA", file=f, s=p["s"], e=p["e"], loop=p.get("loop")))
        for o, p in pairs:
            ds = p["s"] - o["s"]
            if in_blind(o["s"], blind) or in_blind(p["s"], blind):
                continue
            if o.get("openStart") or p.get("openStart"):
                ds = 0
            if not o.get("openStart") and ds > sc["tol_start"]:
                gaps.append(dict(kind="LATE", file=f, s=o["s"], d=round(ds, 3)))
            elif not o.get("openStart") and ds < -sc["tol_start"]:
                gaps.append(dict(kind="EARLY", file=f, s=o["s"], d=round(ds, 3)))
            oe = o["e"] if o["e"] is not None else run_end
            pe = p["e"] if p["e"] is not None else run_end
            if sc.get("relative"):  # AI timing differs run to run: the length of the sound is what must agree
                oe, pe = oe - o["s"], pe - p["s"]
            if o["e"] is None and p["e"] is None:
                continue
            if in_blind(o["e"], blind) or in_blind(p["e"], blind):
                continue
            if pe - oe > sc["tol_end"]:
                gaps.append(dict(kind="OVERRUN", file=f, s=o["s"], oracle_end=None if o["e"] is None else round(o["e"], 3),
                                 pba_end=None if p["e"] is None else round(p["e"], 3), d=round(pe - oe, 3), loop=p.get("loop")))
            elif oe - pe > sc["tol_end"]:
                gaps.append(dict(kind="CUT", file=f, s=o["s"], oracle_end=None if o["e"] is None else round(o["e"], 3),
                                 pba_end=round(pe, 3), d=round(pe - oe, 3)))
    return gaps


def passthrough_gaps(sc, p_eng, p_nat, hooks, origin, blind):
    """Sounds the engine plays in the pba run that pba did not take: an engine channel of at least 0.2 s (or a looped one)
    that is (a) the SERVER's own channel (pba's hook returns false for everything it takes, so a server channel left
    playing is a sound pba let through or never saw: a CSoundPatch scrape before pba followed it), or (b) a client
    channel no EntityEmitSound hook call announced (client and server hooks are recorded by the driver: bullet
    whizzes, viewmodel events, client effects) and with no module voice of its file around it. A pba engine copy is
    announced by the hook call that pba took; it is not one."""
    gaps = []
    for f, lst in p_eng.items():
        if any(re.search(x, f) for x in IGNORE + sc.get("ignore", [])):
            continue
        if sc.get("ai") and not any(re.search(x, f) for x in sc.get("focus", [])):
            continue
        for i in lst:
            dur = (i["e"] if i["e"] is not None else sc["dur"] + 1.5) - i["s"]
            if dur < 0.2 and not i.get("looped"):
                continue
            if in_blind(i["s"], blind):
                continue
            if any(n["s"] - 0.3 <= i["s"] <= (n["e"] if n["e"] is not None else 1e9) + 0.3 for n in p_nat.get(f, [])):
                continue
            if i.get("side") != "SERVER":
                if any(h["file"] == f and i["s"] - 0.8 <= h["t"] - origin <= i["s"] + 0.2 for h in hooks):
                    continue
            gaps.append(dict(kind="PASSTHROUGH", file=f, s=i["s"], e=i["e"], dur=round(dur, 2), side=i.get("side"), ent=i.get("ent"),
                             chan=i.get("chan"), cls=i.get("cls")))
    return gaps


def listen_gaps(oracle, pba):
    """Own sounds through a camera: the engine's listener-to-source distance (truth: view entity vs player) against
    the module's (voice position at its start vs the listener the module was given). Only voices starting when the
    camera is far (the truth > 150 u) and whose file is one the player emitted (notes.own_files)."""
    gaps = []
    files = set(oracle["notes"].get("own_files", []))
    track = oracle.get("lisTrack") or []
    if not files or not track:
        return gaps
    far = [s for s in track if s.get("view") and s.get("ply")]
    if not far:
        return gaps
    d_true = max(((s["view"][0] - s["ply"][0]) ** 2 + (s["view"][1] - s["ply"][1]) ** 2 + (s["view"][2] - s["ply"][2]) ** 2) ** 0.5
                 for s in far)
    if d_true < 150:
        return gaps
    for v in pba.get("voices", []):
        if v["file"] not in files or not v.get("pos") or not v.get("lisAtPlay"):
            continue
        d = sum((a - b) ** 2 for a, b in zip(v["pos"], v["lisAtPlay"])) ** 0.5
        if d < 0.15 * d_true:
            gaps.append(dict(kind="LISTEN", file=v["file"], s=round(v["t"] - pba["origin"], 3), d_pba=round(d, 1), d_engine=round(d_true, 1)))
    return gaps


def analyse(sc_name, oracle, pba):
    sc = SCENARIOS[sc_name]
    o_inst = engine_instances(oracle["samples"], oracle["origin"])
    p_eng = engine_instances(pba["samples"], pba["origin"])
    p_nat = native_instances(pba["voices"], pba["origin"], pba["end"], pba["samples"][0][0] if pba["samples"] else None)
    p_inst = merge_kinds(p_nat, p_eng)
    blind = blind_windows(oracle["samples"], oracle["origin"]) + blind_windows(pba["samples"], pba["origin"])
    gaps = compare(o_inst, p_inst, sc, sc["dur"] + 1.5, blind)
    gaps += passthrough_gaps(sc, p_eng, p_nat, pba.get("hooks", []), pba["origin"], blind)
    gaps += listen_gaps(oracle, pba)
    return dict(gaps=gaps, oracle_files={f: len(v) for f, v in o_inst.items() if not any(re.search(p, f) for p in IGNORE)},
                pba_files={f: len(v) for f, v in p_inst.items() if not any(re.search(p, f) for p in IGNORE)})


# ---------------------------------------------------------------------------------------------- driver
def read_console(T, cursor):
    lines = []
    while True:
        r = T.call("console_read", {"cursor": cursor, "limit": 10000, "regex": r"@@S|(CLIENT|SERVER) l\("}, mx=50_000_000)
        lines += r.get("lines", [])
        nxt = r.get("next_cursor", cursor)
        if len(r.get("lines", [])) < 10000 or nxt == cursor:
            return lines
        cursor = nxt


def lua_file(T, realm, path, args=None, timeout_s=90):
    a = {"realm": realm, "path": path, "timeout_s": timeout_s}
    if args is not None:
        a["args"] = args
    r = T.call("lua_job", a, timeout=timeout_s + 60)
    v = r.get("values")
    return v[0] if v else r


def sv(T, scenario, phase, timeout_s=90):
    return lua_file(T, "server", os.path.join(TEST, "source_parity_sv.lua"), {"scenario": scenario, "phase": phase}, timeout_s)


AR2_CL = """
-- client half of ar2_burst: hold +attack 2.7 s (under one 30-round clip), two 0.25 s frame hitches (a busy wait) at 0.8 and 1.7 s
PAR.Mark()
local t0 = SysTime()
RunConsoleCommand("+attack")
local hit = { 0.8, 1.7 }
local k = 1
while SysTime() - t0 < 2.7 do
	if hit[k] and SysTime() - t0 >= hit[k] then
		local w = SysTime() while SysTime() - w < 0.25 do end
		k = k + 1
	end
	job:sleep(0.02)
end
RunConsoleCommand("-attack")
job:sleep(1.4)
return true
"""


def set_pba(T, on):
    v = 1 if on else 0
    T.con("server", f"pba_enable {v}")
    T.con("client", f"pba_cl_enable {v}")
    time.sleep(1.5)


def one_run(T, name, mode):
    sc = SCENARIOS[name]
    set_pba(T, mode == "pba")
    T.con("client", "stopsound")
    T.call("lua_exec_file", {"realm": "client", "path": os.path.join(TEST, "source_parity_cl.lua")})
    T.lua("client", f"PAR.Arm('{name}/{mode}') return true")
    prep = sv(T, name, "prepare")
    print(f"  [{name}/{mode}] prepared {prep}", flush=True)
    if isinstance(prep, dict) and prep.get("err"):
        raise RuntimeError(prep["err"])
    time.sleep(1.0)
    cur = T.call("console_read", {"limit": 1}).get("next_cursor", 0)
    T.lua("client", f"PAR.Start('{name}/{mode}') return true")
    if sc.get("own_files"):
        T.lua("client", "PAR.Note('own_files', %s) return true" % json.dumps(sc["own_files"]).replace("[", "{").replace("]", "}"))
    if name == "ar2_burst":
        sv(T, name, "go")
        r = T.call("lua_job", {"realm": "client", "code": AR2_CL, "timeout_s": 40}, timeout=100)
    else:
        sv(T, name, "go", timeout_s=sc["dur"] + 40)
        time.sleep(0.5)
    time.sleep(0.6)
    res = T.lua("client", "PAR.Stop() return PAR.Result() .. '\\n' .. GetGlobalString('par_mark')")
    note, mark = res.rsplit("\n", 1)
    data = json.loads(note)
    notes = sv(T, name, "teardown")
    lines = read_console(T, cur)
    origin = data["mark"] if data.get("mark") else (float(mark) if mark else data["t0"])
    samples = parse_console(lines)
    hooks = list(data.get("hooks", [])) + list((notes or {}).get("hooks", []) if isinstance(notes, dict) else [])
    run = dict(hooks=hooks, samples=samples, voices=data["voices"], origin=origin, end=data["now"], notes=dict(data["notes"]),
               lisTrack=data.get("lisTrack"), ticks=data["ticks"], sv_notes=notes)
    print(f"  [{name}/{mode}] {len(samples)} samples, {len(data['voices'])} module voices, origin t0+{origin - data['t0']:.2f}s", flush=True)
    T.con("client", "stopsound")
    time.sleep(1.0)
    return run


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    opts = dict(a[2:].split("=", 1) if "=" in a else (a[2:], "1") for a in sys.argv[1:] if a.startswith("--"))
    mcp = args[0]
    names = args[1].split(",") if len(args) > 1 else list(SCENARIOS)
    report = {}
    if "load" in opts:
        runs = {}
        for n in names:
            runs[n] = {m: json.load(open(os.path.join(opts["load"], f"{n}_{m}.json"), encoding="utf-8")) for m in ("oracle", "pba")}
    else:
        from _coretest import Core
        T = Core(mcp)
        T.load("gm_construct", mp=1)
        runs = {}
        try:
            for n in names:
                runs[n] = {}
                for m in ("oracle", "pba") + (("oracle2",) if "noise" in opts else ()):
                    runs[n][m] = one_run(T, n, "pba" if m == "pba" else "oracle")
                    if "save" in opts:
                        os.makedirs(opts["save"], exist_ok=True)
                        json.dump(runs[n][m], open(os.path.join(opts["save"], f"{n}_{m}.json"), "w", encoding="utf-8"))
        finally:
            set_pba(T, True)
    fails = []
    for n in names:
        r = runs[n]
        res = analyse(n, r["oracle"], r["pba"])
        report[n] = res
        print(f"\n== {n}: {len(res['gaps'])} gap(s)", flush=True)
        print("   oracle instances:", json.dumps(res["oracle_files"]))
        print("   pba    instances:", json.dumps(res["pba_files"]))
        for g in res["gaps"]:
            tag = None
            for (sn, rx, kind), why in EXPECTED.items():
                if sn == n and kind == g["kind"] and re.search(rx, g["file"]):
                    tag = why
            print(("   known  " if tag else "   GAP    ") + json.dumps(g) + (f"   # {tag}" if tag else ""), flush=True)
            if not tag:
                fails.append(f"{n}: {g['kind']} {g['file']} @ {g.get('s')}")
        if "oracle2" in r:
            res2 = analyse(n, r["oracle"], r["oracle2"])
            res2["gaps"] = [g for g in res2["gaps"] if g["kind"] != "PASSTHROUGH"]  # (meaningless: pba is off in both)
            print(f"   noise (oracle vs oracle): {len(res2['gaps'])} gap(s)", flush=True)
            for g in res2["gaps"]:
                print("   noise  " + json.dumps(g))
    print(json.dumps({"pass": not fails, "fails": fails}))
    sys.exit(0 if not fails else 1)


if __name__ == "__main__":
    main()
