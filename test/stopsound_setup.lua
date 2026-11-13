-- Setup of stopsound (server lua_job, any map with a human; client half: stopsound.lua): a server
-- loop (CreateSound) on a prop in front of the human, its pitch changed every 0.2 s (volume / pitch
-- updates keep coming after the client's stopsound), the prop removed after 10 s.
local ply = player.GetHumans()[1]
if not IsValid(ply) then return { pass = false, err = "needs a human" } end
local e = ents.Create("prop_physics")
e:SetModel("models/props_c17/oildrum001.mdl")
e:SetPos(ply:EyePos() + ply:GetAimVector() * 150)
e:Spawn()
local phys = e:GetPhysicsObject()
if IsValid(phys) then phys:EnableMotion(false) end
local p = CreateSound(e, "ambient/machines/spin_loop.wav")
p:Play()
local n = 0
timer.Create("pba_test_stopsound", 0.2, 50, function()
	n = n + 1
	if not IsValid(e) then return end
	p:ChangePitch(100 + (n % 2) * 5, 0)
	if n == 50 then p:Stop() e:Remove() end
end)
return { pass = true, idx = e:EntIndex() }
