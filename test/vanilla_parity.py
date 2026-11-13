"""T2 vanilla_parity: pba does not touch what is free, and pba_enable 0 is the vanilla game.
pba_tworooms, engine rendering (pba_native_render 0), door shut. A prop in the listener's room (A) and one in
the next room (B) play the same sound 10 times; the engine's own starts are read from snd_showstart.
  - same room: the same starts, volumes within 0.01 (measured 1.00 both) with pba_enable 0 and 1; pba relayed
    nothing and registered no copy (the sound is the engine's own: no relay, no pba copy);
  - the system is active: behind the shut door and wall the same sound starts muffled with pba_enable 1
    (measured vol 0.03, played by a pba copy), at 1.00 with pba_enable 0;
  - pba_enable 0: no EntityEmitSound hook of pba (server and client), the door timer stopped, no loop followed;
  - pba_cl_enable 0: the client takes no part (no hook, no copy); the sound behind the wall is the original at 1.00
    (the server still relays it, 3 sounds measured: the client replays the original).
Usage: python -I vanilla_parity.py <mcp.py>
"""
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _coretest import Core  # noqa: E402

T = Core(sys.argv[1])
N = 10
RX = re.compile(r"button14\.wav : src (\d+).*?vol ([\d.]+)")

T.load("pba_tworooms")
T.con("server", "sv_cheats 1")
T.con("client", "developer 1")
T.con("client", "snd_showstart 1")
T.con("client", "pba_native_render 0")
T.place([256, 256, 0])
T.door("door1", "closed")
T.lua("server", "PBA_T2 = {} for _, p in ipairs({ { 'A', Vector(200, 256, 40) }, { 'B', Vector(784, 256, 40) } }) do "
                "local e = ents.Create('prop_physics') e:SetModel('models/props_junk/PopCan01a.mdl') e:SetPos(p[2]) e:Spawn() "
                "e:GetPhysicsObject():EnableMotion(false) PBA_T2[p[1]] = e end return true")
time.sleep(1)

STATE = ("local h = hook.GetTable().EntityEmitSound local n = 0 for _, l in pairs(pba.emitted or {}) do n = n + #l end "
         "return util.TableToJSON({ hook = h ~= nil and h.pba ~= nil, copies = n, on = pba.Enabled(), "
         "relayed = pba.stats.relayed or 0, timer = timer.Exists('pba_doors'), loops = pba.Loops and table.Count(pba.Loops.active or {}) or -1 })")


def state(realm):
    import json
    return json.loads(T.lua(realm, STATE))


def emit(which, n, gap=0.35):
    """n emissions of the sound from prop `which`; the engine's starts of it: [(src, vol)]."""
    cur = T.call("console_read", {"limit": 1})["next_cursor"]
    for _ in range(n):
        T.lua("server", "PBA_T2['%s']:EmitSound('buttons/button14.wav', 75, 100, 1) return true" % which)
        time.sleep(gap)
    time.sleep(0.8)
    lines = T.call("console_read", {"cursor": cur, "limit": 5000}).get("lines", [])
    return [(int(m.group(1)), float(m.group(2))) for m in (RX.search(l["text"]) for l in lines) if m]


def setmode(sv_enable=1, cl_enable=1):
    T.con("server", "pba_enable %d" % sv_enable)
    T.con("client", "pba_cl_enable %d" % cl_enable)
    time.sleep(2)  # (the client reads the replicated switch on its 0.5 s poll)


try:
    res = {}
    for mode in (0, 1):
        setmode(mode)
        sa, ca = state("server"), state("client")
        same = emit("A", N)
        sb, cb = state("server"), state("client")
        wall = emit("B", 3)
        sc, cc = state("server"), state("client")
        res[mode] = {"same": same, "wall": wall, "sa": sa, "ca": ca, "sb": sb, "cb": cb, "sc": sc, "cc": cc, "hooks": (sc["hook"], cc["hook"])}
    same0, same1 = [v for _, v in res[0]["same"]], [v for _, v in res[1]["same"]]
    T.measured["same_room_vols"] = {"enable0": sorted(set(same0)), "enable1": sorted(set(same1))}
    T.check("same room: %d engine starts with pba_enable 0 and 1" % N, len(same0) == N and len(same1) == N, f"{len(same0)} / {len(same1)}")
    T.check("same room: volumes identical within 0.01 (and 1.00)", len(same0) == len(same1) and all(abs(a - b) <= 0.01 for a, b in zip(same0, same1)) and min(same1) >= 0.99, f"{sorted(set(same0))} / {sorted(set(same1))}")
    T.check("same room: nothing relayed, no pba copy (pba_enable 1): every start is the prop's own, none is an anchor's",
            res[1]["sb"]["relayed"] == res[1]["sa"]["relayed"] and res[1]["cb"]["copies"] == res[1]["ca"]["copies"] and len({s for s, _ in res[0]["same"] + res[1]["same"]}) == 1,
            f"relayed {res[1]['sa']['relayed']} -> {res[1]['sb']['relayed']}, copies {res[1]['ca']['copies']} -> {res[1]['cb']['copies']}, sources {sorted({s for s, _ in res[0]['same'] + res[1]['same']})}")
    w0, w1 = [v for _, v in res[0]["wall"]], [v for _, v in res[1]["wall"]]
    T.measured["behind_wall_vols"] = {"enable0": w0, "enable1": w1}
    T.check("active: behind the shut door pba_enable 1 plays it muffled (vol < 0.3), pba_enable 0 as vanilla (1.00)", len(w1) >= 3 and max(w1) < 0.3 and len(w0) == 3 and min(w0) >= 0.99, f"enable 0 {w0}, enable 1 {w1}")
    T.check("active: pba_enable 1 relayed the sounds behind the wall, played by a copy (an anchor, not the prop)", res[1]["sc"]["relayed"] >= res[1]["sb"]["relayed"] + 3 and all(s != res[1]["same"][0][0] for s, _ in res[1]["wall"]), str(res[1]["sc"]) + str(res[1]["wall"]))
    T.check("pba_enable 1: EntityEmitSound hook of pba installed (server, client)", res[1]["hooks"] == (True, True), str(res[1]["hooks"]))
    T.check("pba_enable 0: no EntityEmitSound hook of pba (server, client), the door timer stopped, nothing followed, nothing relayed or copied",
            res[0]["hooks"] == (False, False) and not res[0]["sc"]["timer"] and res[0]["sc"]["loops"] == 0 and res[0]["sc"]["relayed"] == res[0]["sa"]["relayed"]
            and res[0]["cc"]["copies"] == res[0]["ca"]["copies"], str(res[0]["sc"]) + str(res[0]["cc"]))
    T.check("pba_enable 1: the door timer runs (the system is on)", res[1]["sc"]["timer"] is True, str(res[1]["sc"]))

    # pba_cl_enable 0: this client opts out, the server stays on
    setmode(1, 0)
    s0, c0 = state("server"), state("client")
    wall = emit("B", 3)
    s1, c1 = state("server"), state("client")
    T.measured["cl_enable0"] = {"vols": [v for _, v in wall], "relayed_by_server": s1["relayed"] - s0["relayed"], "client": c1}
    T.check("pba_cl_enable 0: the client has no pba hook and is off", c1["hook"] is False and c1["on"] is False and all(s != 8193 for s, _ in wall), str(c1))
    T.check("pba_cl_enable 0: the sound behind the wall is heard as vanilla (3 starts at 1.00)", len(wall) == 3 and min(v for _, v in wall) >= 0.99, str(wall))
finally:
    setmode(1, 1)
    T.con("client", "snd_showstart 0")
    T.con("client", "developer 0")
    T.lua("server", "for _, e in pairs(PBA_T2 or {}) do if IsValid(e) then e:Remove() end end return true")

T.finish()
