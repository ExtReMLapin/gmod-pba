"""Lifecycle checks (pba_tworooms; engine rendering, then native rendering):
1. a looping sound on an entity that is removed stops everywhere (RPG rocket bug);
2. physics scrape / friction loops are left to the engine (never taken over);
3. StopSound on a relayed one-shot stops the client's copies;
4. a new sound on the same entity channel (CHAN_VOICE) replaces the previous copy;
5. removing the entity stops its copies;
6. the listener follows the rendered view (camera / view entity), not the player's eyes.
Usage: python -I lifecycle.py <mcp.py>
"""
import json
import subprocess
import sys
import time

MCP = sys.argv[1]


def call(tool, args, mx=5_000_000):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), str(mx)],
                         capture_output=True, text=True, encoding="utf-8").stdout
    try:
        return json.loads(out)
    except ValueError:
        return {"raw": out}


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


results = []


def check(name, ok, info):
    results.append(ok)
    print(("PASS " if ok else "FAIL ") + name + " :: " + json.dumps(info, default=str)[:400], flush=True)


if call("status", {}).get("map") != "pba_tworooms":
    call("map_load", {"map": "pba_tworooms", "maxplayers": 4})
    time.sleep(3)
lua("server", "local p = player.GetHumans()[1] if not p:Alive() then p:Spawn() end p:SetPos(Vector(256,256,0)) p:SetEyeAngles(Angle(0,0,0)) return true")
call("console_exec", {"realm": "server", "cmd": "pba_demo tworooms_closed"})
time.sleep(2)
call("console_exec", {"realm": "server", "cmd": "pba_demo stop"})

for render in ("0", "1"):
    call("console_exec", {"realm": "client", "cmd": f"pba_native_render {render}"})
    time.sleep(1.5)
    tag = "native" if render == "1" else "engine"
    # 1. loop on a removed entity (the other room, behind the closed door)
    lua("server", """local e = ents.Create('prop_physics') e:SetModel('models/props_junk/PopCan01a.mdl') e:SetPos(Vector(784,256,40)) e:Spawn()
        e:GetPhysicsObject():EnableMotion(false) _G.pba_t = e timer.Simple(0.3, function() _G.pba_snd = CreateSound(e, 'weapons/rpg/rocket1.wav') _G.pba_snd:Play() end) return true""")
    time.sleep(1.5)
    before = lua("client", "local n = 0 for _, m in pairs(pba.Loops.mirrors) do if string.find(m.name, 'rocket1', 1, true) then n = n + 1 end end return n")
    lua("server", "_G.pba_t:Remove() return true")
    time.sleep(2)
    after = lua("client", "local n = 0 for _, m in pairs(pba.Loops.mirrors) do if string.find(m.name, 'rocket1', 1, true) then n = n + 1 end end return n")
    check(f"[{tag}] loop on removed entity stops", before == 1 and after == 0, {"before": before, "after": after})

    # 2. physics scrape loops are not taken over
    phys = lua("server", "return { pba.Loops.IsPhysicsLoop('physics/metal/metal_box_scrape_rough_loop1.wav'), pba.Loops.IsPhysicsLoop('weapons/rpg/rocket1.wav') }")
    check(f"[{tag}] physics scrape left to the engine", phys == [True, False], phys)

    # 3-5. one-shots of an NPC-like source on CHAN_VOICE behind the wall
    lua("server", """local e = ents.Create('prop_physics') e:SetModel('models/props_junk/PopCan01a.mdl') e:SetPos(Vector(784,256,40)) e:Spawn()
        e:GetPhysicsObject():EnableMotion(false) _G.pba_t = e return e:EntIndex()""")
    time.sleep(0.5)
    idx = lua("server", "return _G.pba_t:EntIndex()")
    count = f"""local n, names = 0, {{}} for _, c in pairs(pba.copies) do if c.idx == {idx} then
        for _, a in pairs(c.anchors) do if IsValid(a) and a.pbaName then n = n + 1 names[#names + 1] = a.pbaName end end
        n = n + #c.native for _, x in ipairs(c.native) do names[#names + 1] = x[2] end end end return {{ n = n, names = names }}"""
    lua("server", "_G.pba_t:EmitSound('vo/npc/male01/question06.wav', 75, 100, 1, CHAN_VOICE) return true")
    time.sleep(0.4)
    one = lua("client", count)
    lua("server", "_G.pba_t:EmitSound('vo/npc/male01/question20.wav', 75, 100, 1, CHAN_VOICE) return true")
    time.sleep(0.4)
    two = lua("client", count)
    names_two = (two or {}).get("names", [])
    check(f"[{tag}] same channel replaces the previous copy",
          one and one.get("n", 0) >= 1 and names_two and all("question20" in n for n in names_two), {"first": one, "second": two})
    lua("server", "_G.pba_t:StopSound('vo/npc/male01/question20.wav') return true")
    time.sleep(0.6)
    stopped = lua("client", count)
    check(f"[{tag}] StopSound stops the copies", stopped and stopped.get("n") == 0, stopped)
    lua("server", "_G.pba_t:EmitSound('vo/npc/male01/question06.wav', 75, 100, 1, CHAN_VOICE) return true")
    time.sleep(0.4)
    lua("server", "_G.pba_t:Remove() return true")
    time.sleep(0.8)
    gone = lua("client", count)
    check(f"[{tag}] removing the entity stops its copies", gone and gone.get("n") == 0, gone)

# 6. listener = rendered view (view entity on the server, RenderScene origin on the client)
lua("server", """local p = player.GetHumans()[1] local c = ents.Create('prop_physics') c:SetModel('models/props_junk/PopCan01a.mdl')
    c:SetPos(Vector(780, 400, 60)) c:Spawn() c:GetPhysicsObject():EnableMotion(false) _G.pba_cam = c p:SetViewEntity(c) return true""")
time.sleep(1.0)
ear = lua("server", "local v = pba.PlayerEar(player.GetHumans()[1]) return { v.x, v.y, v.z }")
lis = lua("client", "local v = pba.ListenerPos() return { v.x, v.y, v.z }")
lua("server", "local p = player.GetHumans()[1] p:SetViewEntity(p) if IsValid(_G.pba_cam) then _G.pba_cam:Remove() end return true")
check("listener follows the view entity", ear and ear[0] > 700 and lis and lis[0] > 700, {"server_ear": ear, "client_listener": lis})

call("console_exec", {"realm": "client", "cmd": "pba_native_render 0"})
print(f"\n{sum(results)}/{len(results)} passed")
