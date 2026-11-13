-- Setup of loop_channel (server lua_job, pba_tworooms with a human; client half: loop_channel.lua): a long
-- line (73 s file) on an entity's CHAN_VOICE, followed by sv_loops.
-- Pass (this half): taken over; its key is published for the client half.
local ply = player.GetHumans()[1]
if not IsValid(ply) then return { pass = false, err = "needs a human" } end
local e = ents.Create("prop_physics")
e:SetModel("models/props_junk/popcan01a.mdl")
e:SetPos(ply:EyePos() + ply:GetForward() * 120)
e:Spawn()
local phys = e:GetPhysicsObject()
if IsValid(phys) then phys:EnableMotion(false) end
job:sleep(0.3)
e:EmitSound("music/hl2_song12_long.mp3", 75, 100, 1, CHAN_VOICE)
local key
for k, l in pairs(pba.Loops.active) do if l.ent == e then key = k end end
SetGlobalString("pba_test_loopchan_key", key or "")
SetGlobalEntity("pba_test_loopchan_ent", e)
-- removed by the client half's cleanup (a timer: the client reads the mirror first)
timer.Simple(8, function() if IsValid(e) then e:StopSound("music/hl2_song12_long.mp3") e:Remove() end end)
return { pass = key ~= nil, key = key }
