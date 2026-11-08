-- Load scene for the perf bench (server lua_job): N emitters around the player, all OUT OF SIGHT of
-- the listener (a trace from the eye hits the world), half looping ambiences, half one-shots repeated
-- every 0.4-1.2 s. They keep playing after the job returns (timers); job.args.stop removes them.
-- args: { n = 40, radius = 1500, seed = 7, stop = false, loopsOnly = false (every emitter a loop) }
local args = job.args or {}
local function stop()
	for _, e in ipairs(PBA_CROWD or {}) do
		if IsValid(e) then
			if e.pbaLoop then e:StopSound(e.pbaLoop) end
			e:Remove()
		end
	end
	for i = 1, 400 do timer.Remove("pba_crowd_" .. i) end
	PBA_CROWD = nil
end
stop()
if args.stop then return { stopped = true } end

local function exists(s) return file.Exists("sound/" .. s, "GAME") end
local LOOPS, SHOTS = {}, {}
for _, s in ipairs({ "ambient/fire/fire_small_loop2.wav", "ambient/fire/fire_med_loop1.wav", "ambient/water/water_flow_loop1.wav",
	"ambient/machines/combine_terminal_loop1.wav", "ambient/levels/labs/machine_ring_resonance_loop1.wav", "ambient/alarms/alarm1.wav" }) do
	if exists(s) then LOOPS[#LOOPS + 1] = s end
end
for _, s in ipairs({ "physics/metal/metal_box_impact_hard1.wav", "physics/wood/wood_crate_break1.wav", "weapons/smg1/smg1_fire1.wav",
	"npc/zombie/zombie_voice_idle1.wav", "physics/concrete/concrete_impact_hard1.wav", "weapons/pistol/pistol_fire2.wav" }) do
	if exists(s) then SHOTS[#SHOTS + 1] = s end
end
local n, radius = args.n or 40, args.radius or 1500
local ply = player.GetHumans()[1]
local eye, base = ply:EyePos(), ply:GetPos()
math.randomseed(args.seed or 7)
PBA_CROWD = {}
local placed, tries, loops, shots = 0, 0, 0, 0
while placed < n and tries < n * 200 do
	tries = tries + 1
	local a = math.random() * math.pi * 2
	local r = 250 + math.random() * (radius - 250)
	local top = base + Vector(math.cos(a) * r, math.sin(a) * r, 300 + math.random() * 400)
	local tr = util.TraceLine({ start = top, endpos = top - Vector(0, 0, 2000), mask = MASK_SOLID_BRUSHONLY })
	if tr.Hit and not tr.StartSolid then
		local p = tr.HitPos + Vector(0, 0, 24)
		local free = bit.band(util.PointContents(p), CONTENTS_SOLID) == 0
		local hidden = util.TraceLine({ start = eye, endpos = p, mask = MASK_SOLID_BRUSHONLY }).Hit
		if free and hidden then
			placed = placed + 1
			local e = ents.Create("prop_physics")
			e:SetModel("models/props_junk/PopCan01a.mdl")
			e:SetPos(p)
			e:Spawn()
			local ph = e:GetPhysicsObject()
			if IsValid(ph) then ph:EnableMotion(false) end
			e:SetNoDraw(true)
			PBA_CROWD[#PBA_CROWD + 1] = e
			if (placed % 2 == 1 or args.loopsOnly) and #LOOPS > 0 then
				e.pbaLoop = LOOPS[math.random(#LOOPS)]
				e:EmitSound(e.pbaLoop, 75)
				loops = loops + 1
			elseif #SHOTS > 0 then
				local snd = SHOTS[math.random(#SHOTS)]
				local period = 0.4 + math.random() * 0.8
				timer.Create("pba_crowd_" .. placed, period, 0, function()
					if IsValid(e) then e:EmitSound(snd, 85) end
				end)
				shots = shots + 1
			end
		end
	end
	if tries % 50 == 0 then job:step() end
end
return { placed = placed, loops = loops, oneshots = shots, tries = tries, loopSounds = #LOOPS, shotSounds = #SHOTS }
