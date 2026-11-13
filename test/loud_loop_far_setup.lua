-- Setup of loud_loop_far (server lua_job, pba_tworooms with a human; client half: loud_loop_far.lua):
-- a 130 dB loop (attack helicopter rotor, gunship, dropship, sirens: 130-150 dB) 7000 u away. The engine
-- sends a patch to the players in its attenuated PAS, 100 * (130 - 50) = 8000 u, and plays it at any gain
-- (AC.EngineGain(7000, 130) ~ 0.6: loud). pba suppresses it for everyone but subscribed only the players
-- within lod_dist (6000): beyond, the rotor went silent.
-- Pass (this half): the player is subscribed to the loop.
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
ply:SetPos(Vector(256, 256, 0))
job:sleep(0.3)
local e = ents.Create("info_target") -- server-only: the client mirror uses an anchor at the position
e:SetPos(pba.PlayerEar(ply) + Vector(7000, 0, 0))
e:Spawn()
local p = CreateSound(e, "npc/attack_helicopter/aheli_rotor_loop1.wav")
p:SetSoundLevel(130)
p:Play()
job:sleep(0.3)
local l
for _, x in pairs(pba.Loops.active) do if x.ent == e then l = x end end
SetGlobalString("pba_test_loudfar_key", l and l.key or "")
local res = { taken = l ~= nil, subscribed = l ~= nil and l.subs[ply] == true, lod = pba.cfg.lod_dist }
res.pass = res.taken and res.subscribed
return res
