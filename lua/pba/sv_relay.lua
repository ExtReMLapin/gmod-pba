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
util.AddNetworkString("pba_stopall")

-- Player:ConCommand("stopsound") from the server (a common way addons silence a player): it runs in his
-- engine, never in his Lua; he is told so his client stops pba's sounds as well
do
	local PLY = FindMetaTable("Player")
	A.origPlyCmd = A.origPlyCmd or (debug.getinfo(PLY.ConCommand, "S").what == "C" and PLY.ConCommand or nil)
	if A.origPlyCmd then
		function PLY:ConCommand(cmd, ...)
			A.origPlyCmd(self, cmd, ...)
			if A.StopsAllSounds(cmd) and IsValid(self) and not self:IsBot() then
				net.Start("pba_stopall")
				net.Send(self)
			end
		end
	end
end

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

-- EmitSentence(name, pos, ent...) of an addon on the world reaches EntityEmitSound without its position (Pos
-- nil, the entity the world): pba could not place it and the line crossed every wall. The position it was
-- given is kept for the hook it calls (synchronously). The original is kept as the engine's C function.
A.orig.EmitSentence = A.orig.EmitSentence or EmitSentence
function EmitSentence(name, pos, ...)
	A.sentencePos = pos
	local ok, err = pcall(A.orig.EmitSentence, name, pos, ...)
	A.sentencePos = nil
	if not ok then error(err, 2) end
end
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
	-- its own start time (SoundTime: the shots of a weapon fired between two network updates, each at
	-- its tick), in ms modulo 65.536 s: the client keeps their spacing (cl_render A.SoundTimeDelay)
	local st = (A.cfg.soundtime or 1) >= 0.5 and data.SoundTime or 0
	net.WriteBool(st ~= 0)
	if st ~= 0 then net.WriteUInt(math.floor(st * 1000 + 0.5) % 65536, 16) end
end

A.stats = A.stats or { seen = 0, relayed = 0, untouched = 0 }

--- The engine stopped `name` on entity e (chan: only that channel's copies; nil, any): clients that got
-- relayed copies stop theirs. except: players left out (set).
function A.RelayStop(e, name, chan, except)
	local idx = IsValid(e) and not e:IsWorld() and e:EntIndex() or 0
	local r = idx > 0 and A.recentTo[idx]
	if not r then return end
	local plys, now = {}, CurTime()
	for p, t in pairs(r) do
		if IsValid(p) and now - t < 30 then
			if not (except and except[p]) then plys[#plys + 1] = p end
		else
			r[p] = nil
		end
	end
	if #plys == 0 then return end
	net.Start("pba_snd_stop")
	net.WriteUInt(idx, 16)
	net.WriteInt(chan or CHAN_AUTO, 10) -- CHAN_AUTO (0): any channel
	-- the waves it stops (a sound script resolved here: the client may not know the script); none: all
	if not name or name == "" then
		net.WriteUInt(0, 8)
	else
		local waves = A.StopWaves(name)
		local n = math.min(#waves, 32)
		net.WriteUInt(n, 8)
		for i = 1, n do net.WriteString(waves[i]) end
	end
	net.Send(plys)
end

local function replacing(chan) return chan and chan ~= CHAN_AUTO and chan ~= CHAN_STATIC and chan > 0 end
local NEW_ONLY = SND_STOP + SND_CHANGE_VOL + SND_CHANGE_PITCH

--- Engine channel rule for the relayed copies (audit A-P1-1, D7): a new sound on an entity's replacing
-- channel cuts what that channel played, and the engine does it for its own sounds only. When the new
-- sound is not relayed to a player (left untouched once nobody is blocked any more, re-emitted to the
-- clear or muffled players, taken by sv_loops, refused), his client never sees it: the copies of an
-- earlier line relayed to him play on over it (an NPC's line through a wall over its death cry, after
-- the player walked round the corner). The players it is relayed to apply the rule themselves
-- (cl_render beginCopies), in order with the new copy: they are left out.
-- Only players holding a copy on that channel are told (A.recentChan, filled by the relay; once told,
-- they hold none): an NPC firing CHAN_WEAPON at a player in plain sight sends nothing per shot.
A.recentChan = A.recentChan or {} -- entindex -> { [chan] = { [ply] = time relayed } }
local function relayChannelCut(data, relayedTo)
	local chan = data.Channel
	if not replacing(chan) or bit.band(data.Flags or 0, NEW_ONLY) ~= 0 then return end
	local e = data.Entity
	if not IsValid(e) or e:IsWorld() then return end
	local idx = e:EntIndex()
	local rc = A.recentChan[idx]
	local held = rc and rc[chan]
	local plys, now = {}, CurTime()
	if held then
		if relayedTo then
			for _, p in ipairs(relayedTo) do held[p] = nil end
		end
		-- (a copy is never longer than max_duration; 30 s as for recentTo)
		for p, t in pairs(held) do
			if IsValid(p) and now - t < 30 then plys[#plys + 1] = p end
		end
		rc[chan] = nil
	end
	if relayedTo and #relayedTo > 0 then
		if not rc then rc = {} A.recentChan[idx] = rc end
		local h = {}
		for _, p in ipairs(relayedTo) do h[p] = now end
		rc[chan] = h
	end
	if #plys == 0 then return end
	net.Start("pba_snd_stop")
	net.WriteUInt(idx, 16)
	net.WriteInt(chan, 10)
	net.WriteUInt(0, 8) -- every name
	net.Send(plys)
	A.stats.chanCuts = (A.stats.chanCuts or 0) + 1
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
-- Its own start time (SoundTime) goes with it: EmitSound takes none, our hook puts it back on the
-- re-emission (A.reemitTime), so the engine spaces two shots of one update as it would the original.
local function reemit(data, pos, lvl, plys, name, vol, dsp)
	local f = RecipientFilter()
	f:AddPlayers(plys)
	local e = data.Entity
	local st = (A.cfg.soundtime or 1) >= 0.5 and data.SoundTime or 0
	A.reemitTime = st ~= 0 and st or nil
	if IsValid(e) and not e:IsWorld() then
		A.Emit(A.orig.EntEmitSound, e, name, lvl, data.Pitch, vol, data.Channel, data.Flags, dsp, f)
	else
		A.Emit(A.orig.EmitSound, name, pos, 0, data.Channel, vol, lvl, data.Flags, data.Pitch, dsp, f)
	end
	A.reemitTime = nil
end

-- Footsteps of other players: the engine sends the server's footstep only to the players of the PAS
-- outside the stepping player's PVS (CBasePlayer::PlayStepSound: RemoveRecipientsByPVS); the players
-- who see him generate the footstep on their own client. PlayerFootstep runs right before that
-- emission: the stepping player is noted for this tick, and the players whose PVS holds him are left
-- out (relaying to them too doubled every step).
hook.Add("PlayerFootstep", "pba_step", function(ply)
	A.stepPly, A.stepTick = ply, engine.TickCount()
end)
local function stepper(data)
	local e = data.Entity
	if IsValid(e) and e:IsPlayer() and A.stepPly == e and A.stepTick == engine.TickCount() then return e end
end

local relayedTo -- the players the current sound was relayed to (relay, below)
local function relay(data)
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
		-- (on the world: where EmitSentence was told to play it)
		local e = d.Entity
		if not d.Pos and isvector(A.sentencePos) and not (IsValid(e) and not e:IsWorld()) then d.Pos = A.sentencePos end
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
	-- singleplayer has no prediction: the engine sends the player his own sounds from here, and his
	-- client never sees them (no echoes on his own gunfire). They are his own: clear, as on the client
	local sp = game.SinglePlayer()
	local step = not sp and stepper(data)
	-- clear: original re-emitted unchanged; blocked: relayed; muffled: blocked but over the relay
	-- budget, re-emitted muffled by the engine; far: beyond lod_dist, too far to process (unchanged)
	local clear, blocked, muffled, far = {}, {}, {}, {}
	-- audience by distance, not PAS: a sealed room is outside the PAS (the engine would not
	-- send the sound at all) but its sound still transmits through the walls
	-- clients rendering every sound natively (userinfo pba_native_all_want) get the relay
	-- even with a clear line: their module plays the sound instead of the engine
	for _, ply in ipairs(player.GetHumans()) do
		if sp and ply == predicted and data.Entity == ply then
			clear[#clear + 1] = ply
		elseif (sp or ply ~= predicted) and not (step and ply ~= step and ply:TestPVS(step)) then
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
	relayedTo = blocked
	A.stats.relayed = A.stats.relayed + 1
	return false
end

A.AddHook("EntityEmitSound", (A.WithChannelRule or function(f) return f end)(function(data)
	if A.reemitting then
		-- pba's re-emission: the original's start time put back (reemit)
		if A.reemitTime then data.SoundTime = A.reemitTime return true end
		return
	end
	if A.explicitFilter then return end
	relayedTo = nil
	local ret = relay(data)
	relayChannelCut(data, relayedTo)
	return ret
end))

-- Cancelled choreographed scenes (audit D3). A scene's line plays on its actor's CHAN_VOICE
-- (CSceneEntity::DispatchStartSpeak); when the scene is cancelled (a map's Cancel input, the actor's
-- death or interruption, a new scene: all through CSceneEntity::CancelPlayback) the engine stops the
-- line with a C++ StopSound Lua never sees (CBaseFlex::ClearSceneEvent): the relayed copy played on to
-- its end. CancelPlayback fires the scene's OnCanceled output: every scene gets one to a point entity
-- of ours, its input caught in AcceptInput, and the actor's relayed voice copies stop as the engine's.
-- The parameter is the actor (instanced scenes: NPC responses, PlayScene; their entity is gone by the
-- time the output fires) or 0 (a map's logic_choreographed_scene: its targets, read then).
-- Expression scenes (scenes/expressions/...: faces only, no line) are left out: replaced as an NPC's
-- mood changes, they would cut a line it is saying meanwhile.
local SCENE_TARGET, SCENE_INPUT = "pba_scene_events", "PbaSceneCanceled"
local SCENE_CLASSES = { logic_choreographed_scene = true, instanced_scripted_scene = true, scripted_scene = true }

local function sceneTarget()
	local t = A.sceneTarget
	if IsValid(t) then return t end
	t = ents.Create("info_target")
	if not IsValid(t) then return nil end
	t:SetName(SCENE_TARGET)
	t:Spawn()
	A.sceneTarget = t
	return t
end

local function wireScene(e)
	if not IsValid(e) then return end
	local file = string.lower(e:GetInternalVariable("m_iszSceneFile") or "")
	if string.find(file, "expressions/", 1, true) then return end
	if not sceneTarget() then return end
	local o = e:GetInternalVariable("m_hOwner")
	local actor = IsValid(o) and o:EntIndex() or 0
	e:Fire("AddOutput", "OnCanceled " .. SCENE_TARGET .. ":" .. SCENE_INPUT .. ":" .. actor .. ":0:-1")
end

--- The actor's relayed voice copies stop (and a long line followed by sv_loops).
local function stopActorVoice(actor)
	if not IsValid(actor) then return end
	A.RelayStop(actor, "", CHAN_VOICE)
	local LP = A.Loops
	if LP and LP.active then
		local idx = actor:EntIndex()
		for _, x in pairs(LP.active) do
			if x.idx == idx and x.chan == CHAN_VOICE then LP.Stop(idx, x.name) end
		end
	end
	A.stats.sceneCancels = (A.stats.sceneCancels or 0) + 1
end

hook.Add("OnEntityCreated", "pba_scenes", function(e)
	if SCENE_CLASSES[e:GetClass()] then timer.Simple(0, function() wireScene(e) end) end
end)

hook.Add("AcceptInput", "pba_scenes", function(ent, input, activator, caller, value)
	if input ~= SCENE_INPUT or ent ~= A.sceneTarget then return end
	local idx = tonumber(value) or 0
	if idx > 0 then
		stopActorVoice(Entity(idx))
	elseif IsValid(caller) then
		for i = 1, 8 do
			local name = caller:GetInternalVariable("m_iszTarget" .. i)
			if isstring(name) and name ~= "" and string.byte(name, 1) ~= 33 then
				for _, a in ipairs(ents.FindByName(name)) do stopActorVoice(a) end
			end
		end
	end
	return true
end)

-- entity removed: the engine lets its one-shots play to their end where they were (measured with
-- snd_dumpclientsounds: a line on CHAN_AUTO, VOICE, WEAPON or STATIC still plays 1.5 s after the
-- removal, on entity NULL); the relayed copies do the same. Loops are stopped by pba.Loops.
hook.Add("EntityRemoved", "pba_relay_removed", function(e)
	local idx = e:EntIndex()
	if idx > 0 then A.recentTo[idx] = nil A.recentChan[idx] = nil end
end)
