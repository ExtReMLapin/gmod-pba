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

--- Handles an EntityEmitSound table if it belongs to a loop. Returns true when taken over.
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
	-- engine-driven physics loops (scraping / rolling friction): their envelope lives in the physics
	-- engine; leave them to it
	if not l and LP.IsPhysicsLoop(data.SoundName) then return false end
	local once, dur = false, 0
	if not l and not A.IsLooping(data.SoundName) then
		once, dur = LP.IsLong(data)
		if not once then return false end
	end

	-- stop events carry no sound level: test them first
	if bit.band(flags, SND_STOP) ~= 0 then
		return LP.Stop(idx, data.SoundName)
	end
	if not l and (data.SoundLevel or 75) <= 0 then return false end -- 2D loops: leave to the engine
	if not l and table.Count(LP.active) >= (A.cfg.loops_max or 64) then return false end -- cap: left to the engine
	local update = l ~= nil and bit.band(flags, SND_CHANGE_VOL + SND_CHANGE_PITCH) ~= 0
	if not l then
		l = { key = key, ent = e, idx = idx, chan = data.Channel or 0, name = data.SoundName, subs = {} }
		if once then l.once, l.endT = true, CurTime() + dur * 100 / math.max(data.Pitch or 100, 1) + 0.5 end
		-- moving brushes (func_door noise1, func_tracktrain MoveSound, func_rotating...): their C++
		-- stops the loop with a StopSound that never reaches Lua; the mirror stops with the motion
		l.mover = IsValid(e) and e:GetMoveType() == MOVETYPE_PUSH or nil
		LP.active[key] = l
	end
	l.t = CurTime()
	if not update or bit.band(flags, SND_CHANGE_VOL) ~= 0 then l.vol = data.Volume or 1 end
	if not update or bit.band(flags, SND_CHANGE_PITCH) ~= 0 then l.pitch = data.Pitch or 100 end
	if not update then
		l.lvl, l.dsp = data.SoundLevel or 75, data.DSP or 0
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

--- A moving brush at rest (no linear nor angular velocity): its movement loop is over.
function LP.MoverStill(e)
	return e:GetVelocity():LengthSqr() < 1 and e:GetLocalAngularVelocity():IsZero()
end

-- (un)subscribe players moving in / out of range, drop loops of removed entities
timer.Create("pba_loops", 0.5, 0, function()
	for key, l in pairs(LP.active) do
		if l.mover and IsValid(l.ent) and CurTime() - l.t > 0.4 and LP.MoverStill(l.ent) then
			LP.Stop(l.idx, l.name)
		elseif l.idx ~= 0 and not IsValid(l.ent) then
			-- entity removed (a rocket that exploded...): its sounds stopped without any STOP
			-- event; the clients' mirrors must stop too
			local plys = {}
			for p in pairs(l.subs) do if IsValid(p) then plys[#plys + 1] = p end end
			send(OP_STOP, l, plys)
			LP.active[key] = nil
		elseif l.once and CurTime() > l.endT then
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
		end
		LP.active[key] = nil
	end
end
