"""Controlled per-item bench (optlua_bench.lua) on a freshly loaded map: 8 combine soldiers with SMGs 400-700 u in
front of the player, AI off, each followed by a module voice. Usage:
  MCP_INSTANCE=<id> python -I -u optlua_bench.py <mcp.py> <label> [map] [secs]   -> one JSON line"""
import json, os, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
MCP, LABEL = sys.argv[1], sys.argv[2]
MAP = sys.argv[3] if len(sys.argv) > 3 else "gm_construct"
SECS = float(sys.argv[4]) if len(sys.argv) > 4 else 10


def call(tool, args, timeout=900):
    for _ in range(10):
        out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), "50000000"],
                             capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout)
        try:
            return json.loads(out.stdout)
        except ValueError:
            time.sleep(3)
    raise SystemExit("game unreachable")


def lua(realm, code):
    r = call("lua_exec", {"realm": realm, "code": code})
    v = r.get("values")
    if v is None:
        print("lua error:", json.dumps(r)[:400], flush=True)
        return None
    return v[0] if v else None


call("map_load", {"map": MAP, "timeout_s": 300}, timeout=400)
time.sleep(6)
call("console_exec", {"cmd": "fps_max 200; fps_max_nofocus 0", "realm": "client"})
call("console_exec", {"cmd": "ai_disabled 1", "realm": "server"})
lua("server", """local ply = Entity(1) ply:GodEnable()
local f, r = ply:GetForward(), ply:GetRight() f.z = 0 f:Normalize()
for i = 1, 8 do
  local e = ents.Create("npc_combine_s")
  local p = ply:GetPos() + f * (400 + 40 * i) + r * ((i - 4.5) * 60)
  local tr = util.TraceLine({ start = p + Vector(0, 0, 100), endpos = p - Vector(0, 0, 300), mask = MASK_SOLID_BRUSHONLY })
  e:SetPos(tr.HitPos + Vector(0, 0, 4)) e:SetKeyValue("additionalequipment", "weapon_smg1") e:Spawn() e:Activate()
end return true""")
time.sleep(4)
call("lua_exec_file", {"realm": "client", "path": os.path.join(HERE, "optlua_bench.lua")})
lua("client", f"OPTB.Start({SECS}) return true")
time.sleep(SECS + 1)
while not lua("client", "return OPTB.done"):
    time.sleep(1)
res = lua("client", "return OPTB.res")
print(json.dumps({"label": LABEL, **{k: (round(v, 3) if isinstance(v, float) else v) for k, v in res.items()}}), flush=True)
