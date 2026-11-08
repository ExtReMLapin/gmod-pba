-- pba phase 0: scripted coverage scenario (server realm, run with lua_job).
-- Each category runs inside a time window; windows are returned for correlation with
-- the probe logs and the client's snd_showstart output.
local ply = player.GetAll()[1]
ply:GodEnable()
local base = ply:GetPos()
local fwd = Vector(1, 0, 0)
local windows = {}
local spawned = {}

local function window(name, fn)
	local w = { name = name, t0 = RealTime() }
	job:progress(name)
	fn()
	job:sleep(0.6) -- let tail sounds start
	w.t1 = RealTime()
	windows[#windows + 1] = w
	job:sleep(0.4)
end

local function spawn(class, pos, kv)
	local e = ents.Create(class)
	for k, v in pairs(kv or {}) do e:SetKeyValue(k, v) end
	e:SetPos(pos)
	e:Spawn()
	e:Activate()
	spawned[#spawned + 1] = e
	return e
end

local botAct = nil
hook.Add("StartCommand", "pba_probe_bots", function(p, cmd)
	if not p:IsBot() or not botAct then return end
	cmd:ClearButtons()
	cmd:ClearMovement()
	if botAct == "fire" then cmd:SetButtons(IN_ATTACK) end
	if botAct == "walk" then cmd:SetForwardMove(200) end
end)

ply:SetEyeAngles(Angle(0, 0, 0))
ply:Give("weapon_smg1")
ply:SelectWeapon("weapon_smg1")
ply:GiveAmmo(200, "SMG1", true)
job:sleep(1)

window("local_fire", function()
	ply:ConCommand("+attack")
	job:sleep(1)
	ply:ConCommand("-attack")
end)

window("local_footsteps", function()
	ply:ConCommand("+forward")
	job:sleep(1.5)
	ply:ConCommand("-forward")
end)
ply:SetPos(base)

-- bots
local before = #player.GetAll()
for i = 1, 2 do player.CreateNextBot("apbot" .. i) end
job:sleep(1)
local bots = {}
for _, p in ipairs(player.GetAll()) do
	if p:IsBot() then
		bots[#bots + 1] = p
		p:GodEnable()
		p:SetPos(base + fwd * 300 + Vector(0, 80 * #bots, 0))
		p:SetEyeAngles(Angle(0, 90, 0))
		p:Give("weapon_smg1")
		p:SelectWeapon("weapon_smg1")
		p:GiveAmmo(200, "SMG1", true)
	end
end
job:sleep(1)

window("bot_fire", function()
	botAct = "fire"
	job:sleep(1)
	botAct = nil
end)

window("bot_footsteps", function()
	botAct = "walk"
	job:sleep(1.5)
	botAct = nil
end)

window("physics_impacts", function()
	for i = 1, 3 do
		local e = spawn("prop_physics", base + fwd * 200 + Vector(0, i * 50 - 100, 120), { model = "models/props_c17/oildrum001.mdl" })
	end
	job:sleep(2)
end)

window("npc", function()
	local c = spawn("npc_combine_s", base + fwd * 500, { additionalequipment = "weapon_smg1" })
	local r = spawn("npc_citizen", base + fwd * 500 + Vector(0, 300, 0), { additionalequipment = "weapon_pistol", citizentype = "3" })
	c:AddEntityRelationship(r, D_HT, 99)
	r:AddEntityRelationship(c, D_HT, 99)
	job:sleep(6)
end)

window("door", function()
	local d = spawn("prop_door_rotating", base + fwd * 150 + Vector(0, -150, 54), {
		model = "models/props_c17/door01_left.mdl", hardware = "1", distance = "90", speed = "100", returndelay = "-1",
	})
	job:sleep(0.3)
	d:Fire("Open")
	job:sleep(2)
	d:Fire("Close")
	job:sleep(2)
end)

window("ambient_generic", function()
	local a = spawn("ambient_generic", base + fwd * 200, {
		message = "ambient/alarms/klaxon1.wav", health = "10", radius = "1250", spawnflags = "48", targetname = "ap_amb",
	})
	job:sleep(0.2)
	a:Fire("PlaySound")
	job:sleep(1.5)
	a:Fire("StopSound")
end)

window("createsound_server", function()
	local s = CreateSound(game.GetWorld(), "ambient/fire/fire_small_loop1.wav")
	s:Play()
	job:sleep(1.5)
	s:Stop()
end)

window("createsound_client", function()
	ply:SendLua([[AP_CS=CreateSound(LocalPlayer(),"ambient/fire/fire_small_loop1.wav") AP_CS:Play() timer.Simple(1.5,function() AP_CS:Stop() end)]])
	job:sleep(2)
end)

window("sound_play_server", function()
	sound.Play("buttons/button10.wav", base + fwd * 100, 75, 100, 1)
	job:sleep(0.5)
end)

window("sound_play_client", function()
	ply:SendLua([[sound.Play("buttons/button11.wav", LocalPlayer():GetPos(), 75, 100, 1)]])
	job:sleep(0.5)
end)

window("surface_playsound", function()
	ply:SendLua([[surface.PlaySound("buttons/button15.wav")]])
	job:sleep(0.5)
end)

window("emitsound_global_server", function()
	EmitSound("buttons/button16.wav", base + fwd * 100, 0, CHAN_AUTO, 1, 75)
	job:sleep(0.5)
end)

window("emitsound_ent_client", function()
	ply:SendLua([[LocalPlayer():EmitSound("buttons/button17.wav")]])
	job:sleep(0.5)
end)

window("explosion", function()
	local x = spawn("env_explosion", base + fwd * 400, { iMagnitude = "40" })
	x:Fire("Explode")
	job:sleep(1.5)
end)

window("vehicle", function()
	local j = spawn("prop_vehicle_jeep", base + fwd * 250 + Vector(0, 0, 20), {
		model = "models/buggy.mdl", vehiclescript = "scripts/vehicles/jeep_test.txt",
	})
	job:sleep(0.5)
	ply:EnterVehicle(j)
	job:sleep(0.5)
	ply:ConCommand("+forward")
	job:sleep(2)
	ply:ConCommand("-forward")
	job:sleep(0.5)
	ply:ExitVehicle()
end)

hook.Remove("StartCommand", "pba_probe_bots")
for _, e in ipairs(spawned) do if IsValid(e) then e:Remove() end end
for _, b in ipairs(bots) do if IsValid(b) then b:Kick("done") end end
ply:SetPos(base)
return windows
