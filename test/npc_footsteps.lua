-- NPC footsteps (part 2, client lua_job, after npc_footsteps_setup.lua): records for 8 s what the client does
-- with the walking soldier's footsteps. They are played by the engine, from the client's own copy of the NPC
-- (animation events; "player/footsteps/<surface>N.wav"): they reach EntityEmitSound on the client only.
--   steps    = footsteps seen by the client's EntityEmitSound hook (the original sound of the engine);
--   taken    = of these, those pba took (the hook returned false: the engine does not play the original);
--   engine   = originals the engine still plays (hook returned nil / true), not pba's own re-emissions;
--   copies   = pba's own re-emissions in the engine (A.reemitting): volume and DSP they carry;
--   plays    = voices the module started (pba_native.Play) for a footstep file: gain, EQ bands (low / mid / high), distance;
--   doubles  = an engine original and a module play of the same step within 50 ms of each other;
--   voices   = per taken step, how many module plays (native) or pba copies (Light) it got within 0.3 s: a step
--     heard through a wall and a doorway may get one voice per route (two positions), never two at one spot:
--     unplayed = taken steps with no voice, maxVoices, sameSpot = pairs of voices of one step less than 2 u apart.
-- Returns the numbers; the verdict is the caller's (run_battery.npc_footsteps), which compares two rooms.
local A = pba
local ply = LocalPlayer()
local npc
local t0 = RealTime()
while RealTime() - t0 < 6 do
	npc = ents.FindByClass("npc_combine_s")[1]
	if IsValid(npc) and npc:GetPos():Distance(ply:GetPos()) < 400 then break end
	npc = nil
	job:sleep(0.2)
end
if not npc then return { pass = false, err = "the soldier is not on the client (not in its PVS?)" } end
local N, NA = A.Native, pba_native
local hooks = hook.GetTable().EntityEmitSound
local origHook = hooks and hooks.pba
if not origHook then return { pass = false, err = "pba's EntityEmitSound hook is missing" } end
local origPlay = NA and NA.Play
-- the footstep files decoded first: a step whose file is not decoded yet stays with the engine (not a double, but
-- not what is measured here either)
if N and N.render and NA then
	for _, surf in ipairs({ "concrete" }) do
		for i = 1, 4 do
			local f = "player/footsteps/" .. surf .. i .. ".wav"
			local t1 = RealTime()
			while not N.EnsureSound(f) and RealTime() - t1 < 5 do job:sleep(0.1) end
		end
	end
end
local function isStep(name) return isstring(name) and string.find(string.lower(name), "footstep", 1, true) ~= nil end
local steps, copies, plays = {}, {}, {}
local function nearNpc(pos) return pos and IsValid(npc) and pos:Distance(npc:GetPos()) < 160 end
hook.Add("EntityEmitSound", "pba", function(d)
	local r = origHook(d)
	if isStep(d.SoundName) then
		local ent = d.Entity
		-- (pba's own re-emissions are at the apparent source's position, not on the soldier: every footstep counts)
		local mine = A.reemitting or (IsValid(ent) and ent == npc) or (d.Pos ~= nil and nearNpc(d.Pos))
		if mine then
			local rec = { t = RealTime(), name = d.SoundName, vol = d.Volume or 1, dsp = d.DSP or 0, taken = r == false,
				re = A.reemitting and true or false, pos = d.Pos, dist = npc:GetPos():Distance(ply:GetPos()) }
			if rec.re then copies[#copies + 1] = rec else steps[#steps + 1] = rec end
		end
	end
	return r
end)
if origPlay then
	NA.Play = function(n, pos, g, l, m, h, ...)
		local id = origPlay(n, pos, g, l, m, h, ...)
		-- (every footstep file: the host stands still, the soldier is the only one stepping; a path voice's position
		-- is the apparent source, not the soldier)
		if isStep(n) then
			plays[#plays + 1] = { t = RealTime(), name = n, gain = g, l = l, m = m, h = h, dist = pos:Distance(ply:GetPos()), id = id, pos = pos }
		end
		return id
	end
end
local ok, err = pcall(function() job:sleep(8) end)
hook.Add("EntityEmitSound", "pba", origHook)
if origPlay then NA.Play = origPlay end
if not ok then return { pass = false, err = tostring(err) } end
local res = { steps = #steps, copies = #copies, plays = #plays, native = N and N.render == true or false,
	nativeAll = A.cfg.native_all, npcDist = math.Round(npc:GetPos():Distance(ply:GetPos())) }
local taken, engine = 0, 0
for _, s in ipairs(steps) do if s.taken then taken = taken + 1 else engine = engine + 1 end end
res.taken, res.engine = taken, engine
-- doubles: an engine original (not taken) with a module play within 50 ms
local doubles = 0
for _, s in ipairs(steps) do
	if not s.taken then
		for _, p in ipairs(plays) do if math.abs(p.t - s.t) <= 0.05 then doubles = doubles + 1 break end end
	end
end
res.doubles = doubles
-- level: mean gain and EQ of the module plays, gain x distance (the module's law is 1/r), mean volume
-- and DSP of pba's engine copies, volume and DSP of the originals left to the engine
local function mean(t, f) local s = 0 for _, v in ipairs(t) do s = s + f(v) end return #t > 0 and s / #t or nil end
res.playGain = mean(plays, function(p) return p.gain end)
res.playLevel = mean(plays, function(p) return p.gain * math.max(p.dist, 1) end)
res.playL = mean(plays, function(p) return p.l or 0 end)
res.playM = mean(plays, function(p) return p.m or 0 end)
res.playH = mean(plays, function(p) return p.h or 0 end)
res.copyVol = mean(copies, function(c) return c.vol end)
res.copyDsp = mean(copies, function(c) return c.dsp end)
res.engineVol = mean(steps, function(s) return not s.taken and s.vol or 0 end)
res.stepDist = mean(steps, function(s) return s.dist end)
-- voices per taken step
local function voices(list)
	local unplayed, maxV, sameSpot = 0, 0, 0
	for _, s in ipairs(steps) do
		if s.taken then
			local v = {}
			for _, p in ipairs(list) do if p.t >= s.t - 0.05 and p.t <= s.t + 0.3 then v[#v + 1] = p end end
			if #v == 0 then unplayed = unplayed + 1 end
			maxV = math.max(maxV, #v)
			for a = 1, #v do for b = a + 1, #v do
				if v[a].pos and v[b].pos and v[a].pos:Distance(v[b].pos) < 2 then sameSpot = sameSpot + 1 end
			end end
		end
	end
	return unplayed, maxV, sameSpot
end
res.unplayed, res.maxVoices, res.sameSpot = voices(res.native and plays or copies)
return res
