-- Server side: sounds born on the server are intercepted; for every player who would hear
-- them through a wall, the sound is relayed to that client (which computes the paths and
-- re-emits). Players with a clear line of sight get the original sound re-emitted
-- unchanged. If nobody is obstructed nothing is touched (vanilla).

local A = audioprop
local NET = "audioprop_snd"
local NET_ACK = "audioprop_snd_ack"
util.AddNetworkString(NET)
util.AddNetworkString(NET_ACK)

-- Sound-name dictionary: a name travels in full until the client acknowledges its id,
-- then as a 16-bit id (~20-byte messages instead of ~50).
A.dict = A.dict or { ids = {}, names = {}, n = 0 }
local function nameId(name)
	local id = A.dict.ids[name]
	if not id then
		A.dict.n = A.dict.n + 1
		id = A.dict.n
		A.dict.ids[name], A.dict.names[id] = id, name
	end
	return id
end

net.Receive(NET_ACK, function(_, ply)
	ply.audioprop_known = ply.audioprop_known or {}
	for _ = 1, math.min(net.ReadUInt(8), 64) do ply.audioprop_known[net.ReadUInt(16)] = true end
end)

-- Lua callers passing an explicit recipient filter: leave those sounds alone (we cannot
-- see the filter from EntityEmitSound and must not widen their audience).
local ENT = FindMetaTable("Entity")
A.orig = A.orig or { EntEmitSound = ENT.EmitSound, EmitSound = EmitSound }
A.explicitFilter = false

function ENT:EmitSound(name, lvl, pitch, vol, chan, flags, dsp, filter)
	if filter ~= nil then
		A.explicitFilter = true
		local ok, err = pcall(A.orig.EntEmitSound, self, name, lvl, pitch, vol, chan, flags, dsp, filter)
		A.explicitFilter = false
		if not ok then error(err, 2) end
		return
	end
	return A.orig.EntEmitSound(self, name, lvl, pitch, vol, chan, flags, dsp, filter)
end

function EmitSound(name, pos, ent, chan, vol, lvl, flags, pitch, dsp, filter)
	if filter ~= nil then
		A.explicitFilter = true
		local ok, err = pcall(A.orig.EmitSound, name, pos, ent, chan, vol, lvl, flags, pitch, dsp, filter)
		A.explicitFilter = false
		if not ok then error(err, 2) end
		return
	end
	return A.orig.EmitSound(name, pos, ent, chan, vol, lvl, flags, pitch, dsp, filter)
end

local function audibleRadius(lvl)
	-- the engine sends to players within 100*(lvl-50) units (500 if lvl <= 50)
	return lvl > 50 and 100 * (lvl - 50) or 500
end

local function writeSound(data, pos, id, full)
	net.WriteUInt(id, 16)
	net.WriteBool(full)
	if full then net.WriteString(data.SoundName) end
	net.WriteVector(pos)
	net.WriteUInt(math.Clamp(math.floor(data.SoundLevel or 75), 0, 511), 9)
	net.WriteUInt(math.Clamp(math.floor(data.Pitch or 100), 0, 255), 8)
	net.WriteUInt(math.Clamp(math.Round((data.Volume or 1) * 255), 0, 255), 8)
	net.WriteInt(data.Channel or CHAN_AUTO, 8)
	net.WriteUInt(data.Flags or 0, 16)
	net.WriteUInt(math.Clamp(math.floor(data.DSP or 0), 0, 255), 8)
	local e = data.Entity
	net.WriteUInt(IsValid(e) and e:EntIndex() or 0, 16)
end

A.stats = A.stats or { seen = 0, relayed = 0, untouched = 0 }

A.AddHook("EntityEmitSound", function(data)
	if A.reemitting or A.explicitFilter then return end
	A.stats.seen = A.stats.seen + 1
	if A.Loops and A.Loops.Handle(data) then return false end
	if not A.Eligible(data) then return end
	local pos = A.SoundPos(data)
	if not pos then return end

	local lvl = data.SoundLevel or 75
	local radius = math.min(audibleRadius(lvl), A.cfg.lod_dist)
	local predicted = GetPredictionPlayer()
	local clear, blocked = {}, {}
	-- audience by distance, not PAS: a sealed room is outside the PAS (the engine would not
	-- send the sound at all) but its sound still transmits through the walls
	for _, ply in ipairs(player.GetHumans()) do
		if ply ~= predicted then
			local eye = ply:EyePos()
			if eye:DistToSqr(pos) <= radius * radius then
				local walls = A.Paths.Walls(pos, eye, 1, data.Entity)
				if #walls == 0 then clear[#clear + 1] = ply else blocked[#blocked + 1] = ply end
			end
		end
	end
	if #blocked == 0 then
		A.stats.untouched = A.stats.untouched + 1
		return
	end

	-- suppress, then re-emit unchanged for clear listeners and relay for the others
	if #clear > 0 then
		local f = RecipientFilter()
		f:AddPlayers(clear)
		local e = data.Entity
		if IsValid(e) and not e:IsWorld() then
			A.Emit(A.orig.EntEmitSound, e, data.SoundName, lvl, data.Pitch, data.Volume, data.Channel, data.Flags, data.DSP, f)
		else
			A.Emit(A.orig.EmitSound, data.SoundName, pos, 0, data.Channel, data.Volume, lvl, data.Flags, data.Pitch, data.DSP, f)
		end
	end
	local id = nameId(data.SoundName)
	local full = false
	for _, ply in ipairs(blocked) do
		if not (ply.audioprop_known and ply.audioprop_known[id]) then full = true break end
	end
	net.Start(NET, true) -- unreliable: a lost sound is better than a late one
	writeSound(data, pos, id, full)
	A.stats.bytes = (A.stats.bytes or 0) + net.BytesWritten() * #blocked
	net.Send(blocked)
	A.stats.relayed = A.stats.relayed + 1
	return false
end)
