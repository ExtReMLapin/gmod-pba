-- Setup of loop_far_muffle (server lua_job, pba_tworooms with a human; client half: loop_far_muffle.lua): a
-- loop in room B behind the wall from the player in room A (straight line through the wall, 528 u).
-- Pass (this half): the player is subscribed to it; its key is published for the client half.
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
ply:SetPos(Vector(256, 256, 0))
job:sleep(0.3)
local e = ents.Create("info_target") -- server-only: the client mirror uses an anchor at the position
e:SetPos(Vector(784, 256, 40))
e:Spawn()
local p = CreateSound(e, "ambient/machines/spin_loop.wav")
p:SetSoundLevel(80)
p:Play()
job:sleep(0.3)
local l
for _, x in pairs(pba.Loops.active) do if x.ent == e then l = x end end
SetGlobalString("pba_test_loopfar_key", l and l.key or "")
-- removed after the client half (a timer: the client reads the mirror first)
timer.Simple(12, function() p:Stop() if IsValid(e) then e:Remove() end end)
local res = { taken = l ~= nil, subscribed = l ~= nil and l.subs[ply] == true }
res.pass = res.taken and res.subscribed
return res
