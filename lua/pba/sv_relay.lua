-- Server side: sounds born on the server are intercepted; for every player who would hear
-- them through a wall, the sound is relayed to that client (which computes the paths and
-- re-emits). Players with a clear line of sight get the original sound re-emitted
-- unchanged. If nobody is obstructed nothing is touched (vanilla).

local A = pba
local NET = "pba_snd"
local NET_ACK = "pba_snd_ack"
util.AddNetworkString(NET)
util.AddNetworkString(NET_ACK)
util.AddNetworkString("pba_snd_stop")
util.AddNetworkString("pba_caption")

-- The engine captions a sound script when it emits the ORIGINAL; suppressed (relayed, or the .wav
-- re-emitted for clear listeners, which has no caption token), its caption is sent on its own.
local function sendCaption(data, plys)
	local tok = data.OriginalSoundName
	if #plys == 0 or not tok or tok == "" or tok == data.SoundName or not sound.GetProperties(tok) then return end
	net.Start("pba_caption")
	net.WriteString(tok)
	net.WriteFloat(A.SoundDuration(data.SoundName) or 0)
	net.Send(plys)
end

-- who received relayed copies of an entity's sounds recently: they must hear its StopSound too
A.recentTo = A.recentTo or {} -- entindex -> { [ply] = time }

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
	ply.pba_known = ply.pba_known or {}
	for _ = 1, math.min(net.ReadUInt(8), 64) do ply.pba_known[net.ReadUInt(16)] = true end
end)

-- Lua callers passing an explicit recipient filter: leave those sounds alone (we cannot
-- see the filter from EntityEmitSound and must not widen their audience).
local ENT = FindMetaTable("Entity")
A.orig = A.orig or { EntEmitSound = ENT.EmitSound, EmitSound = EmitSound }
A.orig.EntStopSound = A.orig.EntStopSound or ENT.StopSound
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

-- StopSound never reaches EntityEmitSound: relay it to the players who got copies (transparent)
function ENT:StopSound(name)
	A.orig.EntStopSound(self, name)
	if A.RelayStop then pcall(A.RelayStop, self, name) end
	-- loops and long sounds followed by sv_loops: their client mirrors stop too
	if A.Loops and A.Loops.Stop and IsValid(self) and not self:IsWorld() then pcall(A.Loops.Stop, self:EntIndex(), name) end
end

local function audibleRadius(lvl)
	-- the engine sends to players within 100*(lvl-50) units (500 if lvl <= 50)
	return lvl > 50 and 100 * (lvl - 50) or 500
end

local function writeSound(data, pos, id, full, echoOnly)
	net.WriteUInt(id, 16)
	net.WriteBool(full)
	net.WriteBool(echoOnly or false)
	if full then net.WriteString(data.SoundName) end
	net.WriteVector(pos)
	net.WriteUInt(math.Clamp(math.floor(data.SoundLevel or 75), 0, 511), 9)
	net.WriteUInt(math.Clamp(math.floor(data.Pitch or 100), 0, 255), 8)
	net.WriteUInt(math.Clamp(math.Round((data.Volume or 1) * 255), 0, 255), 8)
	net.WriteInt(data.Channel or CHAN_AUTO, 10) -- CHAN_REPLACE (-1) to user channels (up to 255)
	net.WriteUInt(data.Flags or 0, 16)
	net.WriteUInt(math.Clamp(math.floor(data.DSP or 0), 0, 255), 8)
	local e = data.Entity
	net.WriteUInt(IsValid(e) and e:EntIndex() or 0, 16)
end

A.stats = A.stats or { seen = 0, relayed = 0, untouched = 0 }

--- The engine stopped `name` on entity e: clients that got relayed copies stop theirs.
function A.RelayStop(e, name)
	local idx = IsValid(e) and not e:IsWorld() and e:EntIndex() or 0
	local r = idx > 0 and A.recentTo[idx]
	if not r then return end
	local plys, now = {}, CurTime()
	for p, t in pairs(r) do
		if IsValid(p) and now - t < 30 then plys[#plys + 1] = p else r[p] = nil end
	end
	if #plys == 0 then return end
	net.Start("pba_snd_stop")
	net.WriteUInt(idx, 16)
	net.WriteString(name or "")
	net.Send(plys)
end

-- (fallback: a partial autorefresh may reload this file before sh_core)
--- Token bucket of one player: `rate` per second, burst one second. `key`: the player field holding
-- the bucket, so relays and echo-only relays have separate budgets (a battle's loud gunfire must not
-- eat the budget that keeps the gunfire behind a wall muffled). `stat`: counter of the misses.
local function takeToken(ply, key, rate, stat)
	local now = CurTime()
	local b = ply[key]
	if not b then
		b = { tok = rate, t = now }
		ply[key] = b
	end
	local t = math.min(rate, b.tok + (now - b.t) * rate)
	b.t = now
	if t < 1 then
		b.tok = t
		A.stats[stat] = (A.stats[stat] or 0) + 1
		return false
	end
	b.tok = t - 1
	return true
end

--- Relay budget of one player (pba_relay_rate per second), so a huge firefight cannot flood the
-- network. Out of tokens, a player behind a wall is NOT given the original (it would play at full
-- volume through the wall: near the cap, gunfire behind a wall flipped between muffled and 20-30 dB
-- louder shot to shot); he gets it re-emitted by the engine, muffled (see muffleFor).
local function relayToken(ply)
	return takeToken(ply, "pba_relayBucket", A.cfg.relay_rate or 80, "relayCapped")
end

--- Echo-only relay budget: its own bucket (same rate). Out of tokens the player only misses the
-- client-side echo tail, he still hears the direct sound: never louder, just drier.
local function echoToken(ply)
	return takeToken(ply, "pba_echoBucket", A.cfg.relay_rate or 80, "echoCapped")
end

-- Most a budget-miss fallback lowers a sound (dB). The walls found by the server trace give the loss
-- straight through them, which is the quietest the client could render: its paths may go round
-- (gunfire in the next room heard through an open door ~15 dB down, while the concrete between is
-- 46 dB). Taking the full wall loss would make that gunfire vanish on a budget miss; 24 dB keeps it
-- audible while removing most of the jump towards the relayed render.
local FALLBACK_MAX_DB = 24
-- Without a usable transmission estimate (no wall entry): a documented conservative cut.
local FALLBACK_DEFAULT_DB = 12

--- Engine muffling for a blocked player over budget: DSP preset and volume factor from the walls the
-- server's own trace found (A.Paths.EvalWalls: low-frequency transmission loss and the material's
-- low-pass level). Example: a pistol behind 16 u of concrete -> lp 4 (preset dsp_lp4) and -24 dB.
local function muffleFor(walls)
	local ok, loss, lp = pcall(A.Paths.EvalWalls, walls)
	if not ok or not loss then loss, lp = FALLBACK_DEFAULT_DB, 4 end
	-- the strongest preset when the model gives none (a grate is lp 0: its loss is ~0 dB too)
	local dsp = A.AC.DSPForLevel(lp or 4)
	return dsp, A.AC.DbToGain(-math.min(loss, FALLBACK_MAX_DB))
end

--- Re-emits the original sound, through the engine, to `plys` only (A.Emit: our hook lets it pass).
local function reemit(data, pos, lvl, plys, name, vol, dsp)
	local f = RecipientFilter()
	f:AddPlayers(plys)
	local e = data.Entity
	if IsValid(e) and not e:IsWorld() then
		A.Emit(A.orig.EntEmitSound, e, name, lvl, data.Pitch, vol, data.Channel, data.Flags, dsp, f)
	else
		A.Emit(A.orig.EmitSound, name, pos, 0, data.Channel, vol, lvl, data.Flags, data.Pitch, dsp, f)
	end
end

A.AddHook("EntityEmitSound", (A.WithChannelRule or function(f) return f end)(function(data)
	if A.reemitting or A.explicitFilter then return end
	A.stats.seen = A.stats.seen + 1
	if A.Loops and A.Loops.Handle(data) then return false end
	if bit.band(data.Flags or 0, SND_STOP) ~= 0 then
		-- a stop event (some engine paths do send one): same relay as StopSound
		A.RelayStop(data.Entity, data.SoundName)
		return
	end
	-- a sentence: carried by its name, on a copy of the table (the engine's own is passed on to every
	-- later EntityEmitSound hook, and played as they leave it: they must still see "invalid.wav")
	local sentence = data.SoundName == "invalid.wav" and (A.cfg.sentences or 0) >= 0.5 and (data.OriginalSoundName or "") ~= ""
	if sentence then
		local d = {}
		for k, v in pairs(data) do d[k] = v end
		d.SoundName = "!" .. data.OriginalSoundName
		data = d
	end
	if not A.Eligible(data) then return end
	local pos = A.SoundPos(data)
	if not pos then return end

	local lvl = data.SoundLevel or 75
	-- the whole audible radius, not just lod_dist: once the original is suppressed for someone, every
	-- player the engine would have sent it to must get it back. A 140 dB explosion is heard to 9000 u;
	-- a player at 7000 u (beyond lod_dist 6000) lost it as soon as one player near it was behind a wall.
	local radius = audibleRadius(lvl)
	local lod = A.cfg.lod_dist
	local predicted = GetPredictionPlayer()
	-- clear: original re-emitted unchanged; blocked: relayed; muffled: blocked but over the relay
	-- budget, re-emitted muffled by the engine; far: beyond lod_dist, too far to process (unchanged)
	local clear, blocked, muffled, far = {}, {}, {}, {}
	-- audience by distance, not PAS: a sealed room is outside the PAS (the engine would not
	-- send the sound at all) but its sound still transmits through the walls
	-- clients rendering every sound natively (userinfo pba_native_all_want) get the relay
	-- even with a clear line: their module plays the sound instead of the engine
	for _, ply in ipairs(player.GetHumans()) do
		if ply ~= predicted then
			local eye = A.PlayerEar(ply)
			local d2 = eye:DistToSqr(pos)
			if d2 <= radius * radius then
				if d2 > lod * lod then
					far[#far + 1] = ply
				else
					local all = A.cfg.native_relay >= 0.5 and A.cfg.allow_native >= 0.5 and ply:GetInfoNum("pba_native_all_want", 0) >= 1
					local walls = not all and A.Paths.Walls(pos, eye, 1, data.Entity) or nil
					if (all or #walls > 0) and relayToken(ply) then
						blocked[#blocked + 1] = ply
					else
						-- over budget (or a clear line): the wall test decides, a native-all player
						-- over budget included (his relay was not conditioned on a wall)
						walls = walls or A.Paths.Walls(pos, eye, 1, data.Entity)
						if #walls > 0 then
							local dsp, gain = muffleFor(walls)
							muffled[#muffled + 1] = { ply = ply, dsp = dsp, gain = gain }
						else
							clear[#clear + 1] = ply
						end
					end
				end
			end
		end
	end
	-- clients rendering echoes natively also want the loud sounds they hear directly
	if A.cfg.echo_relay >= 0.5 and A.cfg.allow_native >= 0.5 and lvl >= A.cfg.echo_min_level and #clear > 0 then
		local want = {}
		for _, ply in ipairs(clear) do
			if ply:GetInfoNum("pba_echo_want", 0) >= 1 and echoToken(ply) then want[#want + 1] = ply end
		end
		if #want > 0 then
			local id = nameId(data.SoundName)
			local full = false
			for _, ply in ipairs(want) do
				if not (ply.pba_known and ply.pba_known[id]) then full = true break end
			end
			net.Start(NET, true)
			writeSound(data, pos, id, full, true)
			A.stats.echoBytes = (A.stats.echoBytes or 0) + net.BytesWritten() * #want
			net.Send(want)
		end
	end
	-- players beyond lod_dist hear the original as clear players do (vanilla when nobody is blocked)
	for _, p in ipairs(far) do clear[#clear + 1] = p end
	-- a sentence cannot be re-emitted to some players only (EmitSentence takes no filter): players
	-- over budget get the relay anyway (sentences are rare, a few per minute)
	if sentence then
		for _, m in ipairs(muffled) do blocked[#blocked + 1] = m.ply end
		muffled = {}
	end
	if #blocked == 0 and #muffled == 0 then
		A.stats.untouched = A.stats.untouched + 1
		return
	end
	-- a sentence: the clear listeners get the relay too, and their client plays it unchanged
	if sentence and #clear > 0 then
		for _, p in ipairs(clear) do blocked[#blocked + 1] = p end
		clear = {}
	end

	-- suppress, then re-emit unchanged for clear listeners, muffled for those over budget, and relay
	-- for the others
	if #clear > 0 then reemit(data, pos, lvl, clear, data.SoundName, data.Volume, data.DSP) end
	if #muffled > 0 then
		-- one engine emission per (preset, level): players behind the same kind of wall share it
		local groups, order = {}, {}
		for _, m in ipairs(muffled) do
			local k = m.dsp .. ":" .. math.Round(m.gain * 1000)
			local g = groups[k]
			if not g then
				g = { dsp = m.dsp, gain = m.gain, plys = {} }
				groups[k] = g
				order[#order + 1] = g
			end
			g.plys[#g.plys + 1] = m.ply
		end
		-- a "#" (dry mix) sound gets no DSP from the engine: the same file without it, or the preset
		-- would be ignored and the sound only quieter
		local name = A.WithoutDryMix(data.SoundName)
		for _, g in ipairs(order) do
			-- the sound's own preset (a scripted DSP) is kept when we have none to apply
			reemit(data, pos, lvl, g.plys, name, (data.Volume or 1) * g.gain, g.dsp > 0 and g.dsp or data.DSP)
		end
		A.stats.relayMuffled = (A.stats.relayMuffled or 0) + #muffled
	end
	local told = {}
	for _, p in ipairs(blocked) do told[#told + 1] = p end
	for _, p in ipairs(clear) do told[#told + 1] = p end
	for _, m in ipairs(muffled) do told[#told + 1] = m.ply end
	sendCaption(data, told)
	if #blocked == 0 then return false end
	local id = nameId(data.SoundName)
	local full = false
	for _, ply in ipairs(blocked) do
		if not (ply.pba_known and ply.pba_known[id]) then full = true break end
	end
	local e = data.Entity
	if IsValid(e) and not e:IsWorld() then
		local r = A.recentTo[e:EntIndex()] or {}
		A.recentTo[e:EntIndex()] = r
		local now = CurTime()
		for _, p in ipairs(blocked) do r[p] = now end
	end
	net.Start(NET, true) -- unreliable: a lost sound is better than a late one
	writeSound(data, pos, id, full)
	A.stats.bytes = (A.stats.bytes or 0) + net.BytesWritten() * #blocked
	net.Send(blocked)
	A.stats.relayed = A.stats.relayed + 1
	return false
end))

-- entity removed: the engine stops its sounds; clients that got relayed copies stop theirs
hook.Add("EntityRemoved", "pba_relay_removed", function(e)
	local idx = e:EntIndex()
	local r = idx > 0 and A.recentTo[idx]
	if not r then return end
	A.recentTo[idx] = nil
	local plys, now = {}, CurTime()
	for p, t in pairs(r) do if IsValid(p) and now - t < 30 then plys[#plys + 1] = p end end
	if #plys == 0 then return end
	net.Start("pba_snd_stop")
	net.WriteUInt(idx, 16)
	net.WriteString("")
	net.Send(plys)
end)
