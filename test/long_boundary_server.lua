-- T15 long_sound_boundary, server half (pba_tworooms, a human; lua_job; T15_MAXD = max_duration to try is prepended
-- by the driver). Barney in room B, the closed wall between him and the player in room A, says the 10.48 s scripted
-- line Trainyard.ba_getoutfast_cc. Same file on both sides of the boundary: max_duration just under its length
-- makes it a long sound (followed by sv_loops like a loop, the mirror on the client), just over a short one
-- (relayed once, copies and the mouth copy by the client). Returns which path took it and the lip sync count.
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { err = "needs pba_tworooms with a human" } end
RunConsoleCommand("pba_max_duration", tostring(T15_MAXD))
job:sleep(1)
for _, e in ipairs(ents.FindByName("pba_test_barney")) do e:Remove() end
ply:SetPos(Vector(256, 256, 0))
ply:SetEyeAngles(Angle(0, 0, 0))
local e = ents.Create("npc_barney")
e:SetPos(Vector(784, 256, 0))
e:SetName("pba_test_barney")
e:Spawn() e:Activate()
job:sleep(1.5)
local A = pba
local mouth0, rel0 = A.stats.mouthLong or 0, (A.stats.relayed or 0) + (A.stats.relayMuffled or 0)
e:EmitSound("Trainyard.ba_getoutfast_cc")
local long = false
for _, l in pairs(A.Loops.active) do if l.ent == e and l.once then long = true end end
job:sleep(3)
local res = { long = long, relayed = (A.stats.relayed or 0) + (A.stats.relayMuffled or 0) - rel0,
	mouthLong = (A.stats.mouthLong or 0) - mouth0, dur = A.SoundDuration("Trainyard.ba_getoutfast_cc") }
job:sleep(9) -- the line ends
e:Remove()
return res
