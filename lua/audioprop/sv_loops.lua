-- Looping sounds (vehicles, fire, alarms, NPC engine loops, CSoundPatch). They cannot be
-- re-emitted as one-shots, so the server takes them over entirely: every start / volume /
-- pitch change / stop event is suppressed and relayed (reliably) to the players in range,
-- whose client plays a mirror loop on the same entity and muffles it in place (see
-- cl_loops.lua). Players entering or leaving the range are (un)subscribed periodically.

local A = audioprop
A.Loops = A.Loops or {}
local LP = A.Loops
local NET = "audioprop_loop"
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
	end
	net.Send(plys)
end

local function inRange(l, ply)
	local pos = IsValid(l.ent) and l.ent:WorldSpaceCenter() or l.pos
	local r = radiusFor(l.lvl)
	return ply:EyePos():DistToSqr(pos) <= r * r
end

--- Handles an EntityEmitSound table if it belongs to a loop. Returns true when taken over.
function LP.Handle(data)
	if A.cfg.loops < 0.5 then return false end
	local e = data.Entity
	local idx = IsValid(e) and e:EntIndex() or 0
	local key = idx .. ":" .. (data.Channel or 0) .. ":" .. data.SoundName
	local l = LP.active[key]
	local flags = data.Flags or 0
	if not l and not A.IsLooping(data.SoundName) then return false end

	-- stop events carry no sound level: test them first
	if bit.band(flags, SND_STOP) ~= 0 then
		if l then
			local plys = {}
			for p in pairs(l.subs) do if IsValid(p) then plys[#plys + 1] = p end end
			send(OP_STOP, l, plys)
			LP.active[key] = nil
		end
		return l ~= nil
	end
	if not l and (data.SoundLevel or 75) <= 0 then return false end -- 2D loops: leave to the engine
	local update = l ~= nil and bit.band(flags, SND_CHANGE_VOL + SND_CHANGE_PITCH) ~= 0
	if not l then
		l = { key = key, ent = e, idx = idx, chan = data.Channel or 0, name = data.SoundName, subs = {} }
		LP.active[key] = l
	end
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

-- (un)subscribe players moving in / out of range, drop loops of removed entities
timer.Create("audioprop_loops", 0.5, 0, function()
	for key, l in pairs(LP.active) do
		if l.idx ~= 0 and not IsValid(l.ent) then
			LP.active[key] = nil
		else
			local join, leave = {}, {}
			for _, p in ipairs(player.GetHumans()) do
				local want = inRange(l, p)
				if want and not l.subs[p] then l.subs[p] = true join[#join + 1] = p
				elseif not want and l.subs[p] then l.subs[p] = nil leave[#leave + 1] = p end
			end
			send(OP_START, l, join)
			send(OP_STOP, l, leave)
		end
	end
end)

--- Turning audioprop off: hand the running loops back to the engine.
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
