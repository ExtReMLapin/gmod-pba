-- Looping sounds (vehicles, fire, alarms, NPC engine loops, CSoundPatch) and LONG one-shot
-- sounds (music, speeches: longer than pba_max_duration). They cannot be
-- re-emitted as one-shots, so the server takes them over entirely: every start / volume /
-- pitch change / stop event is suppressed and relayed (reliably) to the players in range,
-- whose client plays a mirror loop on the same entity and muffles it in place (see
-- cl_loops.lua). Players entering or leaving the range are (un)subscribed periodically.

local A = pba
A.Loops = A.Loops or {}
local LP = A.Loops
local NET = "pba_loop"
util.AddNetworkString(NET)

LP.active = LP.active or {} -- key -> { ent, idx, chan, name, vol, pitch, lvl, flags, dsp, pos, subs = {ply=true} }
LP.released = LP.released or {} -- loops handed back to the engine while pba is off: taken again when it comes back

local OP_START, OP_UPDATE, OP_STOP = 0, 1, 2

local function radiusFor(lvl) return math.min(lvl > 50 and 100 * (lvl - 50) or 500, A.cfg.lod_dist) end

local function send(op, l, plys)
	if #plys == 0 then return end
	net.Start(NET)
	net.WriteUInt(op, 2)
	net.WriteString(l.key)
	if op ~= OP_STOP then
		net.WriteString(l.name)
		net.WriteUInt(l.idx, 16)
		net.WriteVector(l.pos)
		net.WriteUInt(math.Clamp(math.Round(l.vol * 255), 0, 255), 8)
		net.WriteUInt(math.Clamp(math.floor(l.pitch), 0, 255), 8)
		net.WriteUInt(math.Clamp(math.floor(l.lvl), 0, 511), 9)
		net.WriteUInt(math.Clamp(math.floor(l.dsp or 0), 0, 255), 8)
		net.WriteBool(l.once or false)
		net.WriteBool(l.speaker or false)
	end
	net.Send(plys)
end

local function inRange(l, ply)
	local pos = IsValid(l.ent) and l.ent:WorldSpaceCenter() or l.pos
	local r = radiusFor(l.lvl)
	return A.PlayerEar(ply):DistToSqr(pos) <= r * r
end

--- Physics friction / scrape loops (driven by the physics engine's own envelope).
local PHYS_PATTERNS = { "scrape", "friction", "_roll", "rolling", "_slide" }
function LP.IsPhysicsLoop(name)
	local n = string.lower(name or "")
	if not string.find(n, "physics/", 1, true) then return false end
	for _, p in ipairs(PHYS_PATTERNS) do if string.find(n, p, 1, true) then return true end end
	return false
end

--- Long one-shot sound worth following like a loop (its path is re-evaluated while it plays).
function LP.IsLong(data)
	if (A.cfg.long_sounds or 0) < 0.5 or (data.SoundLevel or 75) <= 0 then return false end
	local st = data.SoundTime or 0
	if st ~= 0 and math.abs(st - CurTime()) > 0.25 then return false end
	local dur = A.SoundDuration(data.SoundName) or 0
	return dur > A.cfg.max_duration and dur <= 1800, dur
end

--- Stops the loops / long sounds `name` of entity idx (any channel: a stop may come on another
-- channel than the start). Returns true when one was running.
function LP.Stop(idx, name)
	local found = false
	for k, x in pairs(LP.released) do
		if x.idx == idx and (name == nil or name == "" or x.name == name) then LP.released[k] = nil end
	end
	for k, x in pairs(LP.active) do
		if x.idx == idx and (name == nil or name == "" or x.name == name) then
			local plys = {}
			for p in pairs(x.subs) do if IsValid(p) then plys[#plys + 1] = p end end
			send(OP_STOP, x, plys)
			LP.active[k] = nil
			found = true
		end
	end
	return found
end

-- The entity's own movement sound, by class (Source SDK datadesc): func_door / func_plat / func_train
-- noise1, func_tracktrain MoveSound, func_rotating message, prop_door_rotating soundmoveoverride,
-- func_movelinear StartSound, momentary_rot_button sounds.
local MOVE_KEYS = { "m_NoiseMoving", "m_iszSoundMove", "m_NoiseRunning", "m_SoundMoving", "m_soundStart", "m_sNoise" }

--- True when `name` is the movement sound of entity e (sound scripts resolved to their wave): only
-- that sound stops with the motion. Another loop played from the entity (an ambient_generic whose
-- SourceEntityName is a still train: train_idle on d1_trainstation_01) keeps playing.
function LP.IsMoveSound(e, name)
	local f = string.lower(A.SoundFile(name or ""))
	for _, k in ipairs(MOVE_KEYS) do
		local v = e:GetInternalVariable(k)
		if isstring(v) and v ~= "" then
			local props = sound.GetProperties(v)
			local w = props and props.sound or v
			if istable(w) then
				for _, x in ipairs(w) do if string.lower(A.SoundFile(x)) == f then return true end end
			elseif string.lower(A.SoundFile(w)) == f then
				return true
			end
		end
	end
	return false
end

--- Handles an EntityEmitSound table if it belongs to a loop. Returns true when taken over.
local CHARGERS = { item_suitcharger = true, item_healthcharger = true, func_recharge = true, func_healthcharger = true }

LP.capped = LP.capped or {} -- loops left to the engine by the pba_loops_max cap (their later changes too)

local function replacing(chan) return chan and chan ~= CHAN_AUTO and chan ~= CHAN_STATIC and chan > 0 end

function LP.Handle(data)
	if A.cfg.loops < 0.5 then return false end
	local e = data.Entity
	-- players' own loops (underwater ambience...) are started and stopped by the engine's C++
	-- code: that StopSound never reaches Lua, a mirror would play forever. Left to the engine.
	if IsValid(e) and e:IsPlayer() then return false end
	local idx = IsValid(e) and e:EntIndex() or 0
	local key = idx .. ":" .. (data.Channel or 0) .. ":" .. data.SoundName
	local l = LP.active[key]
	local flags = data.Flags or 0
	-- SND_STOP_LOOPING ("stop all looping sounds on the entity") comes on any name (common/null.wav)
	if bit.band(flags, SND_STOP_LOOPING or 32) ~= 0 and idx ~= 0 then
		LP.Stop(idx, nil)
		return false
	end
	-- a new sound on a replacing channel (CHAN_VOICE...) cuts what that channel played, a followed long
	-- line included (the engine replaces it; the mirror must go too)
	if bit.band(flags, SND_STOP + SND_CHANGE_VOL + SND_CHANGE_PITCH) == 0 and replacing(data.Channel) then
		for k, x in pairs(LP.active) do
			if x.idx == idx and x.chan == data.Channel and k ~= key then LP.Stop(idx, x.name) end
		end
	end
	-- left to the engine by the cap: its changes stay the engine's too (else a mirror doubles it)
	if LP.capped[key] then
		if bit.band(flags, SND_STOP + (SND_STOP_LOOPING or 32)) ~= 0 then LP.capped[key] = nil end
		return false
	end
	-- engine-driven physics loops (scraping / rolling friction): their envelope lives in the physics
	-- engine; leave them to it
	if not l and LP.IsPhysicsLoop(data.SoundName) then return false end
	local once, dur = false, 0
	if not l and not A.IsLooping(data.SoundName) then
		once, dur = LP.IsLong(data)
		if not once then return false end
	end

	-- stop events carry no sound level: test them first (SND_STOP_LOOPING ends a loop the same way)
	if bit.band(flags, SND_STOP + (SND_STOP_LOOPING or 32)) ~= 0 then
		return LP.Stop(idx, data.SoundName)
	end
	if not l and (data.SoundLevel or 75) <= 0 then return false end -- 2D loops: leave to the engine
	if not l and table.Count(LP.active) >= (A.cfg.loops_max or 64) then -- cap: left to the engine
		LP.capped[key] = true
		return false
	end
	local update = l ~= nil and bit.band(flags, SND_CHANGE_VOL + SND_CHANGE_PITCH) ~= 0
	if not l then
		l = { key = key, ent = e, idx = idx, chan = data.Channel or 0, name = data.SoundName, subs = {} }
		-- sounds play in real time whatever the time scale (game.SetTimeScale, host_timescale): ends in real time
		if once then l.once, l.endT = true, RealTime() + dur * 100 / math.max(data.Pitch or 100, 1) + 0.5 end
		-- moving brushes (func_door noise1, func_tracktrain MoveSound, func_rotating...) and model doors:
		-- their C++ stops the loop with a StopSound that never reaches Lua; the mirror stops with the
		-- motion. Brush models only ("*N"): a prop_dynamic is MOVETYPE_PUSH too, and a still machine
		-- or radio plays its loop for good
		l.mover = IsValid(e) and e:GetMoveType() == MOVETYPE_PUSH
			and (string.byte(e:GetModel() or "", 1) == 42 or e:GetClass() == "prop_door_rotating")
			and LP.IsMoveSound(e, data.SoundName) or nil
		LP.active[key] = l
	end
	l.t = CurTime()
	if not update or bit.band(flags, SND_CHANGE_VOL) ~= 0 then l.vol = data.Volume or 1 end
	if not update or bit.band(flags, SND_CHANGE_PITCH) ~= 0 then l.pitch = data.Pitch or 100 end
	if not update then
		l.lvl, l.dsp = data.SoundLevel or 75, data.DSP or 0
		-- a microphone's speaker copy (Breencast on a jumbotron): the engine filters it by its SND_SPEAKER
		-- flag, which a mirror (CSoundPatch) cannot carry: the speaker preset becomes the mirror's DSP
		l.speaker = bit.band(flags, SND_SPEAKER or 64) ~= 0 or nil
		if l.dsp == 0 and l.speaker then
			local c = GetConVar("dsp_speaker")
			l.dsp = c and c:GetInt() or 0
		end
		l.pos = data.Pos or (IsValid(e) and e:WorldSpaceCenter()) or Vector()
	end
	local plys = {}
	for _, p in ipairs(player.GetHumans()) do
		if l.subs[p] or inRange(l, p) then
			l.subs[p] = true
			plys[#plys + 1] = p
		end
	end
	send(update and OP_UPDATE or OP_START, l, plys)
	return true
end

-- Server CSoundPatch (CreateSound of addons and gamemodes): its Stop / FadeOut never reach
-- EntityEmitSound while the entity lives on. Patches are registered (weak keys) and both detoured, so
-- the mirror stops with them. Originals kept only as the engine's C functions (autorefresh safe).
LP.origCreateSound = LP.origCreateSound or CreateSound
LP.patchInfo = LP.patchInfo or setmetatable({}, { __mode = "k" })
function CreateSound(ent, name, filter)
	local p = LP.origCreateSound(ent, name, filter)
	if p and IsValid(ent) then LP.patchInfo[p] = { ent = ent, name = name } end
	return p
end
do
	local PATCH = FindMetaTable("CSoundPatch")
	LP.origPatch = LP.origPatch or {}
	for _, k in ipairs({ "Stop", "FadeOut" }) do
		local f = PATCH[k]
		if not LP.origPatch[k] and f and debug.getinfo(f, "S").what == "C" then LP.origPatch[k] = f end
	end
	local function ended(p)
		local i = LP.patchInfo[p]
		if not (i and IsValid(i.ent)) then return end
		LP.Stop(i.ent:EntIndex(), i.name)
		-- the mirror carries the wave a sound script resolved to
		local props = sound.GetProperties(i.name)
		local w = props and props.sound
		if isstring(w) then LP.Stop(i.ent:EntIndex(), w)
		elseif istable(w) then for _, x in ipairs(w) do LP.Stop(i.ent:EntIndex(), x) end end
	end
	function PATCH:Stop() LP.origPatch.Stop(self) ended(self) end
	function PATCH:FadeOut(t) LP.origPatch.FadeOut(self, t) ended(self) end
end

--- A moving brush at rest (no linear nor angular velocity): its movement loop is over.
function LP.MoverStill(e)
	return e:GetVelocity():LengthSqr() < 1 and e:GetLocalAngularVelocity():IsZero()
end

-- (un)subscribe players moving in / out of range, drop loops of removed entities
timer.Create("pba_loops", 0.5, 0, function()
	for key, l in pairs(LP.active) do
		if l.mover and IsValid(l.ent) and CurTime() - l.t > 0.4 and LP.MoverStill(l.ent) then
			LP.Stop(l.idx, l.name)
		elseif IsValid(l.ent) and CHARGERS[l.ent:GetClass()] and l.ent:GetInternalVariable("m_iOn") == 0
			and CurTime() - l.t > 0.5 then
			-- HL2 chargers: their charging loop ends in C++ when the use stops (m_iOn back to 0)
			LP.Stop(l.idx, l.name)
		elseif IsValid(l.ent) and l.ent:IsVehicle() and l.ent.IsEngineStarted and not l.ent:IsEngineStarted()
			and CurTime() - l.t > 1 then
			-- a vehicle's engine loops end in C++ when it is switched off (driver out): never seen by Lua
			LP.Stop(l.idx, l.name)
		elseif l.idx ~= 0 and not IsValid(l.ent) then
			-- entity removed (a rocket that exploded...): its sounds stopped without any STOP
			-- event; the clients' mirrors must stop too
			local plys = {}
			for p in pairs(l.subs) do if IsValid(p) then plys[#plys + 1] = p end end
			send(OP_STOP, l, plys)
			LP.active[key] = nil
		elseif l.once and RealTime() > l.endT then
			LP.active[key] = nil -- finished: the client mirrors end by themselves
		else
			local join, leave = {}, {}
			for _, p in ipairs(player.GetHumans()) do
				local want = inRange(l, p)
				-- a long one-shot cannot be joined midway (it would restart from the beginning)
				if want and not l.subs[p] and not l.once then l.subs[p] = true join[#join + 1] = p
				elseif not want and l.subs[p] then l.subs[p] = nil leave[#leave + 1] = p end
			end
			send(OP_START, l, join)
			send(OP_STOP, l, leave)
		end
	end
end)

--- Wave of a sound name (a sound script: its first wave).
local function waveOf(name)
	local props = name ~= "" and name:sub(1, 1) ~= "!" and sound.GetProperties(name)
	if not props then return name end
	local w = props.sound
	return istable(w) and (w[1] or "") or w or name
end

--- Looping ambient_generic already playing when pba's hooks went in: started in Activate() at
-- map load, before InitPostEntity, they never reached the hook and stayed vanilla (through every
-- wall). Restarted through their own inputs, so the hook takes them over. Idempotent: an ambient
-- already mirrored is left alone. Returns how many were restarted.
function LP.AdoptAmbients()
	if A.cfg.loops < 0.5 or not A.hooksInstalled then return 0 end
	-- loops handed back to the engine when pba was turned off: the engine's copy stops, the mirror
	-- starts again (the engine never says which loops it plays, so pba keeps the list itself)
	for key, l in pairs(LP.released) do
		LP.released[key] = nil
		-- (an ambient switched off meanwhile stays off)
		local off = IsValid(l.ent) and l.ent:GetClass() == "ambient_generic" and not l.ent:GetInternalVariable("m_fActive")
		if IsValid(l.ent) and not off and not (l.mover and LP.MoverStill(l.ent)) then
			A.orig.EntStopSound(l.ent, l.name)
			LP.Handle({ Entity = l.ent, SoundName = l.name, Channel = l.chan, Volume = l.vol, Pitch = l.pitch,
				SoundLevel = l.lvl, DSP = l.dsp, Flags = 0 })
		end
	end
	local mirrored = {}
	for _, l in pairs(LP.active) do if IsValid(l.ent) then mirrored[l.ent] = true end end
	local n = 0
	for _, e in ipairs(ents.FindByClass("ambient_generic")) do
		local src = e:GetInternalVariable("m_hSoundSource")
		if e:GetInternalVariable("m_fActive") and bit.band(e:GetSpawnFlags(), 1) == 0 -- not "play everywhere"
			and not mirrored[e] and not (IsValid(src) and mirrored[src]) then
			local wav = waveOf(e:GetInternalVariable("message") or "")
			if wav ~= "" and wav:sub(1, 1) ~= "!" and A.IsLooping(wav) then
				e:Input("StopSound")
				e:Input("PlaySound")
				n = n + 1
			end
		end
	end
	return n
end

--- Turning pba off: hand the running loops back to the engine.
function LP.Release()
	for key, l in pairs(LP.active) do
		local plys = {}
		for p in pairs(l.subs) do if IsValid(p) then plys[#plys + 1] = p end end
		send(OP_STOP, l, plys)
		if IsValid(l.ent) then
			A.Emit(A.orig.EntEmitSound, l.ent, l.name, l.lvl, l.pitch, l.vol, l.chan, 0, l.dsp)
			if not l.once then l.subs = {} LP.released[key] = l end
		end
		LP.active[key] = nil
	end
end
