-- Setup of quiet_loop_far (server lua_job, pba_tworooms with a human; client half: quiet_loop_far.lua):
-- a level 60 loop in room B (an anchor at the source point), heard from room A through the wall/door.
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
ply:SetPos(Vector(256, 256, 0))
job:sleep(0.3)
local e = ents.Create("info_target") -- server-only: the client mirror uses an anchor at the position
e:SetPos(Vector(784, 256, 40))
e:Spawn()
local p = CreateSound(e, "npc/attack_helicopter/aheli_rotor_loop1.wav")
p:SetSoundLevel(60)
p:Play()
job:sleep(0.3)
local l
for _, x in pairs(pba.Loops.active) do if x.ent == e then l = x end end
SetGlobalString("pba_test_quietfar_key", l and l.key or "")
PBA_TEST_QUIETFAR = { e = e, p = p }
return { pass = l ~= nil, taken = l ~= nil }
