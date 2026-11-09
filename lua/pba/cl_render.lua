-- Client side: computes the paths from a sound to the local listener and re-emits one
-- voice per selected path at its apparent position, with compensated volume and DSP.
-- Handles both client-born sounds (EntityEmitSound on the client) and sounds relayed by
-- the server (net "pba_snd").

local A = pba
local AC = A.AC
local NET = "pba_snd"

A.active = A.active or {}      -- list of { t_end, gain } for the voice budget
A.perf = A.perf or { sum = 0, n = 0, maxCall = 0, maxFrame = 0, frames = 0, cur = 0 }
function A.ResetPerf() A.perf = { sum = 0, n = 0, maxCall = 0, maxFrame = 0, frames = 0, cur = 0 } A.perfTimers = {} end
A.stats = A.stats or { processed = 0, vanilla = 0, voices = 0, relayedIn = 0, dropped = 0 }

local function listenerPos()
	local ply = LocalPlayer()
	if not IsValid(ply) then return nil end
	return A.ListenerPos()
end

local function activeCount(now)
	local n = 0
	for i = #A.active, 1, -1 do
		if A.active[i] < now then table.remove(A.active, i) else n = n + 1 end
	end
	return n
end

--- True once this frame's path-search budget is spent (cheaper fallback for the rest).
function A.FrameBudgetExceeded()
	local pf = A.perf
	return pf.frame == FrameNumber() and pf.cur >= (A.cfg.frame_budget_ms or 1)
end

--- Azimuth of `pos` seen from L with view yaw, degrees, positive = to the RIGHT.
function A.Azimuth(L, viewYaw, pos)
	local d = pos - L
	return -math.AngleDifference(math.deg(math.atan2(d.y, d.x)), viewYaw)
end

local SPEED = 343 / 0.01905 -- speed of sound, units per second

--- Propagation delay of a voice (pba_delay), seconds.
local function voiceDelay(v, L)
	if (A.cfg.delay or 0) < 0.5 then return 0 end
	return (v.len or v.pos:Distance(L)) / SPEED
end

-- ------------------------------------------------------------------ copies of one source
-- The engine stops the previous sound of an entity on the same channel when a new one starts
-- (an NPC line, a weapon), and StopSound stops a sound by name. Copies re-emitted by pba must obey
-- the same rules, whatever carries them: an anchor of a copy set (replacing channel), an anchor of
-- the pool (CHAN_AUTO / CHAN_STATIC), a native voice, or a copy played at a fixed position (anchor
-- cap reached). One registry holds every copy of a source entity, per entity index: StopSound (client
-- or relayed by the server), the removal of the entity and a new sound on a replacing channel all stop
-- copies from it. Before it, only the copy sets were walked: a CHAN_AUTO line of an NPC re-emitted on
-- a pool anchor or natively played on after the server stopped it, and after the entity was removed.
A.copies = A.copies or {} -- "idx:chan" -> { idx, chan, anchors = { slot -> ent }, t }: anchors of a replacing channel
A.emitted = A.emitted or {} -- idx -> { handle, ... }: every copy re-emitted for that entity (handles: see emitVoice)
local function replaces(chan) return chan and chan ~= CHAN_AUTO and chan ~= CHAN_STATIC and chan > 0 end

-- one-shots followed while they play (see below): records, the pool of anchors of the copies that
-- have no copy set (unassigned channels), native voice id -> followed voice
A.OneShots = A.OneShots or {}
local OS = A.OneShots
OS.recs = OS.recs or {}
OS.pool = OS.pool or {}   -- { ent, t = last use }; ent.pbaEnd = time its sound ends (any anchor)
OS.native = OS.native or {}

-- A copy stays in the registry this long after its expected end: the length of a compressed file can
-- be slightly off, and a StopSound right after the expected end must still reach the copy.
local EXPIRE_MARGIN = 1
-- successive one-shots of one source hold their tunnel-preset choice this long (heldTunnel, below)
local TUNNEL_TTL = 2

--- Stops a native copy (a copy rule: new sound on the channel, StopSound): never driven again.
local function stopNative(id)
	if pba_native then pba_native.StopVoice(id) end
	local fv = OS.native[id]
	if fv then fv.dead = true OS.native[id] = nil end
end

--- Stops one copy, at once or before it starts (an emission still waiting for its propagation delay
-- is cancelled: a StopSound 0.1 s after a far gunshot must not let the copy start 0.2 s later).
local function stopCopy(h)
	if h.cancelled then return end
	h.cancelled = true
	if h.id then
		stopNative(h.id)
	elseif h.a then
		local a = h.a
		if IsValid(a) and a.pbaSeq == h.seq and a.pbaName == h.name then a:StopSound(h.name) a.pbaName = nil end
		if IsValid(a) and a.pbaSeqNext == h.seq then a.pbaEnd = 0 end -- free for the next copy
	elseif h.pos and h.started and not A.IsSentence(h.name) and RealTime() <= h.tEnd + EXPIRE_MARGIN then
		-- a copy at a fixed position: the engine's own stop of that name on the same source and channel
		-- (EmitSound's index -1). Every fixed-position copy shares that source: an expired one is skipped,
		-- its stop would cut another source's copy of the same name.
		A.EmitAt(h.name, h.pos, -1, CHAN_AUTO, 0, h.lvl, SND_STOP, h.pitch, 0)
	end
end

local function expired(h, now) return h.cancelled or now > h.tEnd + EXPIRE_MARGIN end

--- Records a copy of entity idx (nothing for a source without an entity: no StopSound can name it).
local function register(idx, h)
	if not idx then return end
	local list = A.emitted[idx]
	if not list then list = {} A.emitted[idx] = list end
	local now = RealTime()
	for i = #list, 1, -1 do if expired(list[i], now) then table.remove(list, i) end end
	list[#list + 1] = h
end

local function anchorCount()
	local n = 0
	for _, cc in pairs(A.copies) do
		for _, x in pairs(cc.anchors) do if IsValid(x) then n = n + 1 end end
	end
	for _, p in ipairs(OS.pool) do if IsValid(p.ent) then n = n + 1 end end
	return n
end

--- An anchor taken for a new copy: whatever it still plays is cut (its expected end has passed: a
-- length read too short must not leave a sound playing on, moved to the new copy's position).
local function quiet(a)
	if a.pbaName then a:StopSound(a.pbaName) a.pbaName = nil end
end

--- A new anchor; at the cap on client entities, one whose sound ended is taken from its owner (a copy
-- set idle for 20 s held its anchors while a battle's gunfire fell back to fixed positions, which the
-- channel rule and StopSound reach far less well). nil: none free, the caller plays at a position.
local function newAnchor(now)
	if anchorCount() < (A.cfg.max_anchors or 48) then
		local a = ClientsideModel("models/hunter/blocks/cube025x025x025.mdl", RENDERGROUP_OTHER)
		if not IsValid(a) then return nil end
		a:SetNoDraw(true)
		return a
	end
	for _, c in pairs(A.copies) do
		for slot, x in pairs(c.anchors) do
			if IsValid(x) and (x.pbaEnd or 0) < now then c.anchors[slot] = nil quiet(x) return x end
		end
	end
	for i, pa in ipairs(OS.pool) do
		if IsValid(pa.ent) and (pa.ent.pbaEnd or 0) < now then table.remove(OS.pool, i) quiet(pa.ent) return pa.ent end
	end
	return nil
end

local function sourceIndex(data)
	local idx = data.EntIndex
	if (not idx or idx == 0) and IsValid(data.Entity) and not data.Entity:IsWorld() then idx = data.Entity:EntIndex() end
	return (idx and idx > 0) and idx or nil
end

--- Copy set of a sound's source on a replacing channel: a new sound there cuts every earlier copy of
-- that channel (anchors, native voices, and those at a fixed position past the anchor cap).
local function beginCopies(data, idx)
	local chan = data.Channel or CHAN_AUTO
	if not idx or not replaces(chan) then return nil end
	local list = A.emitted[idx]
	if list then
		for i = #list, 1, -1 do
			if list[i].srcChan == chan then stopCopy(list[i]) table.remove(list, i) end
		end
	end
	local key = idx .. ":" .. chan
	local c = A.copies[key]
	if not c then
		c = { idx = idx, chan = chan, anchors = {} }
		A.copies[key] = c
	end
	c.t = RealTime()
	return c
end

local function anchorFor(c, slot)
	local a = c.anchors[slot]
	if IsValid(a) then return a end
	-- cap on client entities: beyond it, the caller plays the copy at a position instead
	a = newAnchor(RealTime())
	if not a then return nil end
	c.anchors[slot] = a
	return a
end

--- Stops the copies of `name` (all names if empty) re-emitted for entity idx, whatever their channel.
function A.StopCopies(idx, name)
	name = name or ""
	local list = A.emitted[idx]
	if not list then return end
	local bare = name ~= "" and A.WithoutDryMix(name)
	for i = #list, 1, -1 do
		local h = list[i]
		-- the name asked, as given or as played (a muffled "#" sound is played without its "#")
		if name == "" or h.orig == name or h.name == name or h.name == bare then
			stopCopy(h)
			table.remove(list, i)
		end
	end
	if #list == 0 then A.emitted[idx] = nil end
end

local function anchorBusy(a, now) return IsValid(a) and (a.pbaEnd or 0) >= now end

-- idle copy sets: anchors removed after 30 s without a new sound and once their sounds ended (a
-- 3-minute song on a replacing channel was cut after 30 s); expired registry entries dropped
timer.Create("pba_copies_gc", 5, 0, function()
	local now = RealTime()
	for key, c in pairs(A.copies) do
		local busy = false
		for _, a in pairs(c.anchors) do if anchorBusy(a, now) then busy = true end end
		if not busy and now - (c.t or 0) > 30 then
			for _, a in pairs(c.anchors) do if IsValid(a) then a:Remove() end end
			A.copies[key] = nil
		end
	end
	for i = #OS.pool, 1, -1 do
		local pa = OS.pool[i]
		if not IsValid(pa.ent) or (not anchorBusy(pa.ent, now) and now - pa.t > 30) then
			if IsValid(pa.ent) then pa.ent:Remove() end
			table.remove(OS.pool, i)
		end
	end
	for idx, list in pairs(A.emitted) do
		for i = #list, 1, -1 do if expired(list[i], now) then table.remove(list, i) end end
		if #list == 0 then A.emitted[idx] = nil end
	end
	for key, e in pairs(A.tunnelHeld or {}) do
		if now - e.t > TUNNEL_TTL then A.tunnelHeld[key] = nil end
	end
end)

--- Anchor of a copy without a copy set (unassigned channel), busy until its sound ends: a sound played
-- at a fixed position cannot be moved nor stopped by name, one played by an entity can.
local function poolAnchor(tEnd)
	local now = RealTime()
	for _, pa in ipairs(OS.pool) do
		if IsValid(pa.ent) and not anchorBusy(pa.ent, now) then
			quiet(pa.ent)
			pa.ent.pbaEnd, pa.t = tEnd, now
			return pa.ent
		end
	end
	local a = newAnchor(now)
	if not a then return nil end
	a.pbaEnd = tEnd
	OS.pool[#OS.pool + 1] = { ent = a, t = now }
	return a
end

-- ------------------------------------------------------------------ sounds of unknown length
-- SoundDuration gives 0 for a VBR mp3 (and nil or 0 for a missing file, some sentences). Taken as
-- 0.1 s, a 3-minute song of a radio entity was computed once, never followed, and its anchor counted
-- as free at once. Unknown is taken as possibly long: followed (native voices until the module reports
-- them ended) up to UNKNOWN_CAP, while the file's real length is read once by BASS (sound.PlayFile,
-- "noplay"); the copies and records of that file then get their real end.
local UNKNOWN_CAP = 600
A.lengthProbe = A.lengthProbe or {} -- file -> seconds; false = unreadable; true = being read

local function setLength(h, secs)
	h.ukey = nil
	h.tEnd = h.t0 + secs * 100 / math.max(h.pitch or 100, 1)
	if IsValid(h.a) and h.a.pbaSeqNext == h.seq then h.a.pbaEnd = h.tEnd end
end

local function onLength(key, secs)
	for _, list in pairs(A.emitted) do
		for _, h in ipairs(list) do if h.ukey == key then setLength(h, secs) end end
	end
	for _, rec in ipairs(OS.recs) do
		if rec.ukey == key then
			rec.ukey = nil
			local tEnd = 0
			for _, fv in ipairs(rec.voices) do
				if fv.ukey == key then setLength(fv, secs) end
				tEnd = math.max(tEnd, fv.tEnd)
			end
			rec.tEnd = tEnd
		end
	end
end

--- Seconds `name` plays at `pitch`, and the key of its file while its length is unknown (then the
-- seconds are UNKNOWN_CAP).
local function playLength(name, pitch)
	local secs = A.SoundDuration(name)
	if secs and secs > 0 then return math.max(secs, 0.1) * 100 / math.max(pitch or 100, 1) end
	if A.IsSentence(name) then return UNKNOWN_CAP, "!" end -- not a file: no length to read
	local key = string.lower(A.SoundFile(name))
	local p = A.lengthProbe[key]
	if type(p) == "number" then return math.max(p, 0.1) * 100 / math.max(pitch or 100, 1) end
	if p == nil and sound and sound.PlayFile then
		A.lengthProbe[key] = true
		sound.PlayFile("sound/" .. key, "noplay", function(ch)
			local len = IsValid(ch) and ch:GetLength() or -1
			if IsValid(ch) then ch:Stop() end
			A.lengthProbe[key] = (len and len > 0) and len or false
			if len and len > 0 then onLength(key, len) end
		end)
		-- (a callback run at once: the length is already known)
		p = A.lengthProbe[key]
		if type(p) == "number" then return math.max(p, 0.1) * 100 / math.max(pitch or 100, 1) end
	end
	return UNKNOWN_CAP, key
end

--- "^" (distance variant) stereo waves: the engine picks the near or far channel by the copy's OWN
-- distance (crossfade 240 -> 1320 u). A copy at an opening 192 u away played the near wave of NPC
-- gunfire 2400 u away. The copy is pushed out along its direction to the real source distance (at
-- most 1320 u); its level is kept by the engine-gain compensation.
function A.DistVariantPos(name, pos, L, S)
	if not S or not L then return pos end
	local pre = string.sub(name or "", 1, #(name or "") - #A.SoundFile(name))
	if not string.find(pre, "^", 1, true) then return pos end
	local d, want = pos:Distance(L), math.min(S:Distance(L), 1320)
	if want <= d or d < 1 then return pos end
	return L + (pos - L) * (want / d)
end

-- ------------------------------------------------------------------ engine preset of a copy
-- The diffuse "tunnel" preset (AC.DSPForVoice) switches at diffuse_dsp_at. A share moving 0.39 <-> 0.41 as
-- the listener steps flipped the preset of successive sounds of one source (footsteps, gunfire down a
-- corridor) and the preset a followed copy would need. The choice is held near the threshold
-- (AC.DiffuseHold, diffuse_dsp_hyst): per followed copy (fv.tunnel, see evaluate) and, for successive
-- one-shots of one source, per source entity and voice slot for TUNNEL_TTL seconds.
A.tunnelHeld = A.tunnelHeld or {} -- "idx:slot" -> { on, t }

local function hystMargin() return A.cfg.diffuse_dsp_hyst or 0.05 end

--- Engine preset of low-pass level `level` with the tunnel choice `tunnel` already decided (held).
local function presetFor(level, tunnel)
	level = level or 0
	-- a share of 1 is above any diffuse_dsp_at: AC.DSPForVoice keeps its own rule (diffuse model off: plain)
	if tunnel then return AC.DSPForVoice(level, 1) end
	return AC.DSPForLevel(level)
end

--- Tunnel choice of a new one-shot voice: held from the previous sound of the same source and slot when
-- that one is recent (key nil: a source without an entity, no hold).
local function heldTunnel(key, share, now)
	local e = key and A.tunnelHeld[key]
	local prev = nil
	if e and now - e.t <= TUNNEL_TTL then prev = e.on end
	local on = AC.DiffuseHold(share or 0, prev, hystMargin())
	if key then
		if e then e.on, e.t = on, now else A.tunnelHeld[key] = { on = on, t = now } end
	end
	return on
end

--- True when the loaded module's Play takes a start offset (arg 13: seconds of playback already heard,
-- at the voice's pitch; faded in over one block). Version() is Steam Audio's version, not the module's,
-- so it cannot tell: the module exports pba_native.caps.playOffset. An older module (no caps) ignores a
-- 13th argument and would play the sound from its start, heard twice: never switch then.
local function playOffsetOK()
	local caps = pba_native and pba_native.caps
	return type(caps) == "table" and caps.playOffset and true or false
end

--- Emits one voice. life: seconds the sound plays (pitch included; UNKNOWN_CAP while its length is
-- unknown, ukey then the key of its file); follow: it is to be followed; idx: its source entity (the
-- copy is registered for the stop rules). Returns false when nothing was emitted, else a handle:
-- { id = native voice } or { a = anchor, seq = emission number on it, chan } (both followable), or
-- { pos } (a copy at a fixed position); each with t0 / tEnd (start, expected end), name (as played),
-- orig (as asked), srcChan (the sound's own channel).
local function emitVoice(data, v, L, src, copies, slot, life, ukey, follow, idx)
	local srcChan, orig, pitch = data.Channel or CHAN_AUTO, data.SoundName, data.Pitch or 100
	-- native rendering: the module plays the voice itself (HRTF + EQ); no engine compensation
	-- (a sentence is a sequence of words played by the engine: never by the module)
	if A.Native and A.Native.render and not A.IsSentence(data.SoundName) then
		-- the full version's distance law (N.PhysPath): real spreading instead of the engine's law
		-- a weapon's dipole: the aim taken now, at emission (N.Directivity)
		local dirK = A.Native.Directivity(src, L, data.Channel)
		local g = (data.Volume or 1) * A.Native.PhysPath(v.gain, v.len, data.SoundLevel or 75, v.rawLossDb) * dirK
		if g < 0.001 then return false end
		local delay = voiceDelay(v, L)
		local spk = bit.band(data.Flags or 0, SND_SPEAKER or 64) ~= 0 and A.Native.SPEAKER_EQ or nil
		-- the dominant voice carries the source's air-borne reverb (its slot); a transmission voice feeds
		-- the listener's room; the other voices no reverb of their own (no double count)
		local S = data.Pos
		-- a loud sound already echoed by the echo slots (not "all native") takes no source slot too
		local echoed = (A.cfg.native_all or 0) < 0.5 and (data.SoundLevel or 75) >= (A.cfg.native_echo_lvl or 95)
		local dominant = slot == 1 and not echoed and S
		local srcSend = dominant and (data.Volume or 1) * A.Native.PhysSrcSend(data.SoundLevel or 75, S:Distance(L)) * dirK
		local id = A.Native.PlayVoice(data.SoundName, v.pos, g, v.lp, data.Pitch, { len = v.len, sh = v.sh, delay = delay, eq = spk, lpDb = v.lpDb,
			diffuse = v.diffuse, srcPos = dominant or nil, srcSend = srcSend, trans = v.kind == "transmission", noRoom = true })
		if id then
			v.vol, v.dsp, v.native = g, -1, true
			local t0 = RealTime() + delay
			local h = { id = id, t0 = t0, tEnd = t0 + life, ukey = ukey, pitch = pitch, name = data.SoundName, orig = orig, srcChan = srcChan }
			register(idx, h)
			return h
		end
	end
	local lvl = data.SoundLevel
	v.epos = A.DistVariantPos(data.SoundName, v.pos, L, data.Pos)
	local d = v.epos:Distance(L)
	local vol = (data.Volume or 1) * v.gain / AC.EngineGain(math.max(d, 1), lvl)
	vol = math.min(vol, 1)
	if vol < 0.01 then return false end
	local tunnel = heldTunnel(idx and (idx .. ":" .. (slot or 1)), v.diffuse, RealTime())
	local dsp = presetFor(v.lp, tunnel)
	-- the sound's own preset (a radio or speaker effect) is part of the sound: kept, muffled by volume
	local own = (A.cfg.keep_dsp or 1) >= 0.5 and (data.DSP or 0) ~= 0
	if dsp == 0 or own then dsp = data.DSP or 0 end
	local flags = bit.band(data.Flags or 0, bit.bnot(SND_CHANGE_VOL + SND_CHANGE_PITCH + SND_STOP))
	local delay = voiceDelay(v, L)
	local name, pos = data.SoundName, v.epos
	-- a muffled "#" (dry mix) sound: the engine would skip the preset, the sound would stay clear
	if dsp ~= 0 then name = A.WithoutDryMix(name) end
	local sentence = A.IsSentence(name)
	local t0 = RealTime() + (delay >= 0.02 and delay or 0)
	local tEnd = t0 + life
	-- a sentence plays at a position (EmitSentence): no anchor, so not followed nor stopped by name
	local anchor = not sentence and copies and anchorFor(copies, slot or 1)
	-- a copy without a copy set (unassigned channel) gets an anchor of the pool (CHAN_AUTO, as before)
	-- when it is followed or has an entity whose StopSound or removal must reach it
	if not anchor and not sentence and not copies and (follow or idx) then anchor = poolAnchor(tEnd) end
	local chan = copies and copies.chan or CHAN_AUTO
	local h = { t0 = t0, tEnd = tEnd, ukey = ukey, pitch = pitch, name = name, orig = orig, srcChan = srcChan }
	-- what its preset was chosen from (frozen for the whole sound): a followed copy compares its new
	-- target with it (see the native switch below); its own preset (own) is never replaced
	h.lp0, h.tunnel0, h.tunnel, h.ownDsp = v.lp or 0, tunnel, tunnel, own or nil
	if anchor then
		h.seq = (anchor.pbaSeqNext or 0) + 1
		anchor.pbaSeqNext, anchor.pbaEnd = h.seq, tEnd
		h.a, h.chan, h.dsp = anchor, chan, dsp
		-- (h.name: the name it plays, a muffled "#" sound without its "#": its later SND_CHANGE_VOL use it)
	else
		h.pos, h.lvl = pos, lvl
	end
	local function emit()
		-- stopped during its propagation delay (StopSound, new sound on the channel): never starts
		if h.cancelled then return end
		if anchor then
			-- the anchor was given to another copy meanwhile
			if not IsValid(anchor) or anchor.pbaSeqNext ~= h.seq then return end
			anchor:SetPos(pos)
			anchor.pbaName, anchor.pbaSeq = name, h.seq
			A.Emit(anchor.EmitSound, anchor, name, lvl, pitch, vol, chan, flags, dsp)
		else
			A.EmitAt(name, pos, -1, CHAN_AUTO, vol, lvl, flags, pitch, dsp)
		end
		h.started = true
	end
	register(idx, h)
	if delay >= 0.02 then timer.Simple(delay, emit) else emit() end
	v.vol, v.dsp = vol, dsp
	return h
end

-- ------------------------------------------------------------------ one-shots followed while they play
-- A one-shot (shorter than max_duration) was computed once, at emission: walking round an obstacle
-- during a 3 s line, its voice kept coming from beside the obstacle. Those still playing
-- (oneshot_follow, at most oneshot_follow_max) are re-evaluated every update_interval like loops, on
-- the client only (no network): P.Compute + P.Stable, then each voice already playing glides
-- (P.RampTo / RampAt, continuous_ramp) to its new target. A playing voice can move and change level,
-- not split nor start midway: P.FollowAssign maps the new voices onto the ones heard (extra voices
-- fade out, extra paths add their power). Native voices: pba_native.Update. Engine copies: their
-- anchor moves (the engine places a sound at its entity) and the volume changes by SND_CHANGE_VOL on
-- the same anchor, channel and name. The DSP preset of an engine sound cannot change mid-sound, and
-- EmitSound starts a sound from its first sample: emitted again with another preset, a line muffled at
-- its start and clear 1.5 s later would be heard twice. Without native rendering a copy keeps its
-- preset, only its level follows (a copy emitted muffled that becomes clear stays low-passed). With
-- native rendering on and a module whose Play takes a start offset (playOffsetOK), a copy whose
-- preset no longer fits (its target's low-pass level 1 or more away from the one it was emitted with,
-- or the held tunnel choice changed) is handed to the module at the same point of the sound and its
-- engine copy stopped (switchNative); its own preset (keep_dsp) is never replaced.
-- Not followed in their last MIN_LEFT seconds, and no volume change then: a SND_CHANGE_VOL that no
-- longer finds its sound starts it again (engine rule), so the margin covers a duration slightly off;
-- only .wav durations are trusted for it (SoundDuration of compressed files can be off).
local MIN_LEFT = 0.5

local function followInterval() return math.max(A.cfg.update_interval or 0.25, 0.05) end

--- True when a one-shot playing `play` seconds is worth following.
function OS.Wanted(play)
	return (A.cfg.oneshot_follow or 0) >= 0.5 and A.Paths.FollowWorth(play, followInterval(), MIN_LEFT)
end

local function anchorAlive(fv, name)
	local a = fv.a
	return IsValid(a) and a.pbaSeq == fv.seq and a.pbaName == name
end

--- Ends the following of rec: its voices play on as they are, except those fading out (stopped).
local function dropRec(rec)
	for _, fv in ipairs(rec.voices) do
		if fv.id then
			OS.native[fv.id] = nil
			if fv.dead then
				fv.nfollow = nil
			elseif fv.fading then
				pba_native.StopVoice(fv.id)
			elseif fv.nfollow and rec.clearPath and A.Native and A.Native.follow then
				A.Native.follow[fv.id] = fv.nfollow -- clear sight of an entity: back to the per-frame follower
			end
		elseif fv.fading then
			stopCopy(fv) -- its anchor freed, its registry entry ended
		end
	end
end

--- Values a voice of rec is driven to for target t (P.FollowAssign): gain, 3 EQ bands, position,
-- pitch. Engine copies: the volume the engine needs at that position (its own distance law applies).
local function targetValues(rec, fv, t, L)
	if fv.id then
		local N = A.Native
		local el, em, eh = N.VoiceEQ(t.lp, t.len, t.lpDb)
		-- Doppler of a moving source or listener, as loops and clear voices (N.UpdateFollowers) have it
		local k = N.Doppler and N.Doppler(rec.S, N.VelocityOf(rec.ent), L, N.ListenerVelocity()) or 1
		return rec.vol * N.PhysPath(t.gain, t.len, rec.lvl, t.rawLossDb) * N.Directivity(rec.dirEnt, L, rec.chan, rec.aim) * A.cfg.native_gain, el, em, eh, t.pos, rec.pitch * k
	end
	local pos = A.DistVariantPos(rec.name, t.pos, L, rec.S)
	local d = pos:Distance(L)
	return math.min(rec.vol * t.gain / AC.EngineGain(math.max(d, 1), rec.lvl), 1), 1, 1, 1, pos, rec.pitch
end

--- The voice of the new selection that target t was built from (P.FollowAssign keeps its pos): the
-- target gets its continuous loss, raw loss, diffuse share and kind, which FollowAssign leaves out
-- (targetValues read t.lpDb / t.rawLossDb and always got nil: the native EQ stepped between levels and a
-- loud source's loss was recovered from a gain that the headroom had absorbed, see N.PhysPath).
local function enrich(t, vs)
	local sv
	for _, v in ipairs(vs) do if rawequal(v.pos, t.pos) then sv = v break end end
	if not sv then return nil end
	t.lpDb, t.diffuse, t.kind = sv.lpDb, sv.diffuse, sv.kind
	-- the merged paths' extra power (t.gain is the group's) taken off the dominant member's raw loss
	if sv.rawLossDb and (sv.gain or 0) > 0 and (t.gain or 0) > 0 then
		t.rawLossDb = sv.rawLossDb - 20 * math.log10(t.gain / sv.gain)
	end
	return sv
end

--- True when the engine copy fv should be handed to the module now (see the comment above MIN_LEFT).
local function wantsNative(rec, fv, t, now)
	-- (lp0 nil: a copy emitted before this code was loaded, autorefresh: left as it is)
	if not fv.a or not fv.started or fv.ownDsp or fv.lp0 == nil or rec.ukey or (fv.switchFails or 0) >= 3 then return false end
	if (A.cfg.oneshot_native_switch or 1) < 0.5 then return false end
	local N = A.Native
	if not (N and N.render and pba_native and pba_native.Play) or A.IsSentence(rec.name) then return false end
	-- a switch near the end is not worth a second voice (the end of a compressed file can be off)
	if now > fv.tEnd - MIN_LEFT - followInterval() then return false end
	if not playOffsetOK() then return false end
	return math.abs((t.lp or 0) - fv.lp0) >= 1 or (fv.tunnel0 ~= nil and fv.tunnel ~= fv.tunnel0)
end

local NATIVE_FV = { id = true } -- targetValues of a voice about to become native

--- Hands the engine copy fv over to the module: played from where the copy is now (seconds since it
-- started), then the engine copy stopped. fv (the copy's handle, in the registry) becomes a
-- native voice in place: the copy rules (StopSound, channel, removal) reach it by its id. dominant: the
-- record's first voice (it takes the source reverb slot, as at emission). Returns true when switched.
local function switchNative(rec, fv, t, L, now, dominant)
	local N = A.Native
	local ok, n = N.EnsureSound(rec.name)
	if not ok then return false end -- not decoded yet (a large file): tried again at the next evaluation
	local g, el, em, eh, pos, pitch = targetValues(rec, NATIVE_FV, t, L)
	-- what has been heard of it so far (the module's offset is playback time at the voice's pitch)
	local offset = math.max(now - fv.t0, 0)
	local sh = (A.cfg.native_path_fx or 0) >= 0.5 and t.sh or nil
	local trans = t.kind == "transmission"
	local id = pba_native.Play(n, pos, g, el, em, eh, pitch, false, 0, sh, t.diffuse or 0, trans and N.RoomSend(g, pos, L) or 0, offset)
	if not id or id <= 0 then
		fv.switchFails = (fv.switchFails or 0) + 1
		return false
	end
	-- reverb as at emission (emitVoice / N.PlayVoice): the dominant voice feeds its source slot unless a
	-- loud sound is already echoed; without a slot, a voice that is not a transmission feeds the room
	local echoed = (A.cfg.native_all or 0) < 0.5 and rec.lvl >= (A.cfg.native_echo_lvl or 95)
	local bound = false
	if dominant and not echoed and rec.S then
		local srcSend = rec.vol * N.PhysSrcSend(rec.lvl, rec.S:Distance(L)) * N.Directivity(rec.dirEnt, L, rec.chan, rec.aim) * A.cfg.native_gain
		bound = N.BindSource(id, rec.S, srcSend)
	end
	if not bound and not trans then pba_native.Update(id, pos, g, el, em, eh, pitch, nil, g) end
	-- the engine copy stops once the module has it (stopCopy without cancelling the handle)
	local a, name = fv.a, fv.name or rec.name
	if anchorAlive(fv, name) then a:StopSound(name) a.pbaName = nil end
	if IsValid(a) and a.pbaSeqNext == fv.seq then a.pbaEnd = 0 end -- free for the next copy
	fv.a, fv.seq, fv.chan, fv.dsp, fv.sent = nil, nil, nil, nil, nil
	fv.id, fv.switched = id, true
	OS.native[id] = fv
	fv.sh = t.sh or false
	fv.shSent = sh and fv.sh or false
	A.Paths.RampTo(fv.ramp, now, 0, L, g, el, em, eh, pos, pitch)
	fv.ramp.pending = false -- played with these values
	A.stats.nativeSwitch = (A.stats.nativeSwitch or 0) + 1
	return true
end

local function evaluate(rec, now, L)
	local P = A.Paths
	local ent = IsValid(rec.ent) and rec.ent or nil
	if ent then rec.S = A.SoundPos({ Entity = ent }) end
	local S = rec.S
	local r = P.Stable(rec.hyst, P.Compute(S, L, rec.lvl, nil, ent))
	A.DebugNote("os:" .. rec.key, S, L, r, rec.name, "oneshot")
	local vs
	rec.clearPath = r.clear or not r.voices or #r.voices == 0
	if rec.clearPath then
		local d = S:Distance(L)
		vs = { { pos = S, gain = AC.EngineGain(math.max(d, 1), rec.lvl), lp = 0, len = d } }
	else
		vs = r.voices
	end
	local live, olds = {}, {}
	for _, fv in ipairs(rec.voices) do
		if not fv.fading and not fv.dead then live[#live + 1], olds[#olds + 1] = fv, fv.pos end
	end
	local targets = P.FollowAssign(L, olds, vs)
	local dur = (A.cfg.continuous_ramp or 0) >= 0.5 and followInterval() or 0
	for i, fv in ipairs(live) do
		local t = targets[i]
		if t then
			enrich(t, vs)
			-- the tunnel choice this copy would need now, held near diffuse_dsp_at (clear sight: none)
			if fv.a then fv.tunnel = AC.DiffuseHold(t.diffuse or 0, fv.tunnel, hystMargin()) end
			fv.sh = t.sh or false -- its new path's baked field (none: straight line to its position)
			if not (wantsNative(rec, fv, t, now) and switchNative(rec, fv, t, L, now, i == 1)) then
				P.RampTo(fv.ramp, now, dur, L, targetValues(rec, fv, t, L))
			end
		else
			-- no path left for this voice: it fades out over the interval, then stops
			fv.fading = true
			local b = fv.ramp.to
			P.RampTo(fv.ramp, now, dur, L, 0, b[2], b[3], b[4], fv.ramp.pos1, b[5])
		end
	end
end

--- Clear sight of a moving entity: the voice heard from it follows it every frame (as the engine
-- and N.UpdateFollowers do), the running ramp ending on it.
local function followClear(rec, L)
	if not rec.clearPath or not IsValid(rec.ent) then return end
	local S = A.SoundPos({ Entity = rec.ent })
	if S:DistToSqr(rec.S) < 1 then return end
	rec.S = S
	local d = S:Distance(L)
	for _, fv in ipairs(rec.voices) do
		if not fv.fading and not fv.dead and fv.ramp.to then
			fv.sh = false -- clear sight: straight from the source
			A.Paths.Retarget(fv.ramp, targetValues(rec, fv, { pos = S, gain = AC.EngineGain(math.max(d, 1), rec.lvl), lp = 0, len = d }, L))
			return -- the dominant one; the others fade out
		end
	end
end

local function applyVoice(rec, fv, now, L)
	local g, e1, e2, e3, pos, pitch = A.Paths.RampAt(fv.ramp, now, L)
	fv.pos = pos
	if fv.id then
		-- baked path field (native_path_fx): a voice played along its path kept its Play-time arrival
		-- direction while the listener walked round the corner. Sent when it changes (a table: along the
		-- new path; false: straight line at pos; nil: kept); diffuse and send (args 8, 9) nil: kept.
		local want = (A.cfg.native_path_fx or 0) >= 0.5 and fv.sh or false
		local sh = nil
		if want ~= fv.shSent then sh, fv.shSent = want, want end
		if not pba_native.Update(fv.id, pos, g, e1, e2, e3, pitch, nil, nil, sh) then fv.dead = true return end
	else
		local a = fv.a
		a:SetPos(pos)
		-- volume: steps of 0.5 dB at most along the ramp, exact at its end; never close to the end
		local s = fv.sent or g
		if rec.wav and now < fv.tEnd - MIN_LEFT and g > 0 and g ~= s
			and (not fv.ramp.pending or math.abs(g - s) > 0.06 * math.max(g, s)) then
			A.Emit(a.EmitSound, a, fv.name or rec.name, rec.lvl, rec.pitch, g, fv.chan, SND_CHANGE_VOL, fv.dsp)
			fv.sent = g
		end
	end
	if fv.fading and not fv.ramp.pending then
		if fv.id then
			pba_native.StopVoice(fv.id)
			OS.native[fv.id] = nil
		else
			stopCopy(fv) -- its anchor freed, its registry entry ended
		end
		fv.dead = true
	end
end

--- Starts following a one-shot just emitted. list: { { h = handle from emitVoice, v = voice } } in
-- emission order (the dominant first); play: seconds it plays; r: the evaluation it was emitted with;
-- ukey: key of its file while its length is unknown (play is then UNKNOWN_CAP, see playLength).
function OS.Add(data, src, S, L, r, list, play, ukey)
	local now = RealTime()
	local tEnd = 0
	for _, e in ipairs(list) do tEnd = math.max(tEnd, e.h.t0 + play) end
	local slot = A.Paths.FollowSlot(OS.recs, now, A.cfg.oneshot_follow_max or 16, tEnd, MIN_LEFT)
	if not slot then return nil end
	if OS.recs[slot] then dropRec(OS.recs[slot]) end
	OS.seq = (OS.seq or 0) + 1
	local ent = IsValid(src) and not src:IsWorld() and src or nil
	local name = data.SoundName
	-- chan / aim: a weapon's dipole keeps the aim it was fired with (N.Directivity)
	local _, aim0 = A.Native and A.Native.WeaponAim and A.Native.WeaponAim(IsValid(src) and src or nil, data.Channel)
	local rec = { key = OS.seq, name = name, ent = ent, dirEnt = IsValid(src) and src or nil, S = S, lvl = data.SoundLevel or 75,
		chan = data.Channel, aim = aim0,
		vol = data.Volume or 1, pitch = data.Pitch or 100, tEnd = tEnd, tNext = now + followInterval(), hyst = {},
		clearPath = r.clear or not r.voices or #r.voices == 0, ukey = ukey,
		-- volume changes need a trusted end (see MIN_LEFT): never for a sound of unknown length
		wav = not ukey and string.lower(string.GetExtensionFromFilename(name) or "") == "wav", voices = {} }
	A.Paths.Stable(rec.hyst, r) -- the hysteresis starts from what was emitted
	local N = A.Native
	for _, e in ipairs(list) do
		local fv, v = e.h, e.v
		fv.tEnd, fv.pos, fv.ramp = fv.t0 + play, v.epos or v.pos, {}
		if fv.id then
			local el, em, eh = N.VoiceEQ(v.lp, v.len, v.lpDb)
			A.Paths.RampTo(fv.ramp, now, 0, L, v.vol * A.cfg.native_gain, el, em, eh, v.pos, rec.pitch)
			OS.native[fv.id] = fv
			-- the path field it was played with (PlayVoice passes it only with native_path_fx)
			fv.sh = v.sh or false
			fv.shSent = (A.cfg.native_path_fx or 0) >= 0.5 and fv.sh or false
			-- a clear voice bound to its entity (N.follow): driven from here now
			if N.follow and N.follow[fv.id] then fv.nfollow, N.follow[fv.id] = N.follow[fv.id], nil end
		else
			fv.sent = v.vol
			A.Paths.RampTo(fv.ramp, now, 0, L, v.vol, 1, 1, 1, v.epos or v.pos, rec.pitch)
		end
		fv.ramp.pending = false -- emitted with these values: nothing to send until the first update
		rec.voices[#rec.voices + 1] = fv
	end
	OS.recs[slot] = rec
	return rec
end

--- Every frame: re-evaluates each followed one-shot once per update_interval (each on its own
-- clock, from its emission: spread over the frames), glides its voices, drops it when it ends.
hook.Add("Think", "pba_oneshots", A.PerfTimed("oneshots", function()
	local recs = OS.recs
	if #recs == 0 then return false end
	local now = RealTime()
	local L = A.ListenerPos()
	if not L then return false end
	local on = (A.cfg.oneshot_follow or 0) >= 0.5 and A.Enabled()
	for i = #recs, 1, -1 do
		local rec = recs[i]
		local alive = 0
		for j = #rec.voices, 1, -1 do
			local fv = rec.voices[j]
			-- stopped by a copy rule (StopSound, new sound on its channel, entity removed): never driven again
			if fv.cancelled then fv.dead = true end
			if not fv.dead and fv.a then
				-- an anchor whose copy was cut (new sound on its channel, StopSound) or never started
				if fv.started then
					if not anchorAlive(fv, fv.name or rec.name) then fv.dead = true end
				elseif now > fv.t0 + 1 then
					fv.dead = true
				end
			end
			if fv.dead then
				if fv.id then OS.native[fv.id] = nil end
				table.remove(rec.voices, j)
			elseif not fv.fading then
				alive = alive + 1
			end
		end
		if not on or alive == 0 or rec.tEnd - now < MIN_LEFT then
			dropRec(rec)
			table.remove(recs, i)
		else
			if now >= rec.tNext and not A.FrameBudgetExceeded() then
				rec.tNext = now + followInterval()
				evaluate(rec, now, L)
			end
			followClear(rec, L)
			for _, fv in ipairs(rec.voices) do
				-- an engine copy is driven once really started (a SND_CHANGE_VOL before would start it)
				if not fv.dead and fv.ramp.pending and now >= fv.t0 and (fv.id or fv.started) then applyVoice(rec, fv, now, L) end
			end
		end
	end
end))

--- Processes one sound. Returns true when pba took charge of it (the original must
-- not be played), even if every voice ended up inaudible; false = play it as vanilla.
function A.Process(data, relayed)
	local L, ang = listenerPos()
	local S = data.Pos
	if not L or not S then return false end
	-- a new sound on a replacing channel cuts the earlier copies of that channel, even when this one
	-- is left to the engine (clear sight, too far): an NPC's new line heard in clear sight played over
	-- its previous line still coming through the doorway
	local idx = sourceIndex(data)
	local copies = beginCopies(data, idx)
	local lvl = data.SoundLevel or 75
	if S:Distance(L) > A.cfg.lod_dist then return false end
	local t0 = SysTime()
	local src = data.Entity
	if not IsValid(src) and data.EntIndex and data.EntIndex > 0 then src = Entity(data.EntIndex) end
	local r = A.Paths.Compute(S, L, lvl, nil, IsValid(src) and src or nil)
	A.DebugNote(nil, S, L, r, data.SoundName, A.Native and A.Native.render and "native" or "sound")
	if r.clear or not r.voices or #r.voices == 0 then
		-- "everything native": a clear sound is played by the module at its real position
		if A.Native and A.Native.render and (A.cfg.native_all or 0) >= 0.5 and not A.IsSentence(data.SoundName) then
			local d = S:Distance(L)
			local dir = A.Native.Directivity(IsValid(src) and src or nil, L, data.Channel)
			local g = (data.Volume or 1) * A.Native.PhysClear(lvl, d) * dir
			-- PlayVoice only (no engine fallback here: the caller plays the original if this fails)
			local follow = IsValid(src) and not src:IsWorld() and { ent = src, vol = data.Volume or 1, lvl = lvl, chan = data.Channel } or nil
			local delay = voiceDelay({ len = d, pos = S }, L)
			local spk = bit.band(data.Flags or 0, SND_SPEAKER or 64) ~= 0 and A.Native.SPEAKER_EQ or nil
			local id = A.Native.PlayVoice(data.SoundName, S, g, 0, data.Pitch, { len = d, delay = delay, follow = follow, eq = spk, srcPos = S,
				srcSend = (data.Volume or 1) * A.Native.PhysSrcSend(lvl, d) * dir })
			if id then
				A.stats.nativeDirect = (A.stats.nativeDirect or 0) + 1
				local play, ukey = playLength(data.SoundName, data.Pitch)
				local t0 = RealTime() + delay
				local h = { id = id, t0 = t0, tEnd = t0 + play, ukey = ukey, pitch = data.Pitch or 100, name = data.SoundName,
					orig = data.SoundName, srcChan = data.Channel or CHAN_AUTO }
				register(idx, h)
				-- followed while it plays: walking behind a wall must muffle it too
				if OS.Wanted(play) then
					OS.Add(data, src, S, L, r, { { h = h, v = { pos = S, vol = g, lp = 0, len = d } } }, play, ukey)
				end
				return true
			end
		end
		A.stats.vanilla = A.stats.vanilla + 1
		return false
	end
	local now = RealTime()
	local budget = A.cfg.max_active - activeCount(now)
	local emitted = 0
	-- seconds it plays (pitch included): followed while it plays when long enough
	local play, ukey = playLength(data.SoundName, data.Pitch)
	-- voice budget: a sound of unknown length counts as one of max_duration (it may be a short VBR mp3)
	local busy = ukey and math.min(play, A.cfg.max_duration or 10) or play
	local follow = OS.Wanted(play) and {} or nil
	for i, v in ipairs(r.voices) do
		if i > 1 and emitted >= budget then A.stats.dropped = A.stats.dropped + 1 break end
		local h = emitVoice(data, v, L, IsValid(src) and src or nil, copies, i, play, ukey, follow ~= nil, idx)
		if h then
			emitted = emitted + 1
			A.active[#A.active + 1] = now + busy
			-- every voice must be drivable (a copy at a fixed position cannot move): else none is
			if follow then
				if h.id or h.a then follow[#follow + 1] = { h = h, v = v } else follow = nil end
			end
		end
	end
	if follow and #follow > 0 then OS.Add(data, src, S, L, r, follow, play, ukey) end
	A.stats.processed = A.stats.processed + 1
	-- per-frame cost accounting (dev / perf campaign)
	local ms = (SysTime() - t0) * 1000
	local fr = FrameNumber()
	local pf = A.perf
	if pf.frame ~= fr then
		if pf.frame then
			pf.frames = pf.frames + 1
			pf.maxFrame = math.max(pf.maxFrame, pf.cur)
		end
		pf.frame, pf.cur = fr, 0
	end
	pf.cur = pf.cur + ms
	pf.sum = pf.sum + ms
	pf.n = pf.n + 1
	pf.maxCall = math.max(pf.maxCall, ms)
	A.stats.voices = A.stats.voices + emitted

	local rec = { t = now, S = S, L = L, r = r, name = data.SoundName, relayed = relayed, ms = (SysTime() - t0) * 1000 }
	if A.cfg.report >= 0.5 then
		local vs = {}
		for _, v in ipairs(r.voices) do
			vs[#vs + 1] = { kind = v.kind, pos = { v.pos.x, v.pos.y, v.pos.z }, level_db = math.Round(v.level, 1),
				az = math.Round(A.Azimuth(L, ang.y, v.pos), 1), lp = v.lp, dsp = v.dsp, vol = v.vol and math.Round(v.vol, 3) }
		end
		local ps = {}
		for _, p in ipairs(r.paths or {}) do
			local keys = {}
			for _, c in ipairs(p.chain) do keys[#keys + 1] = c.key end
			ps[#ps + 1] = { portals = keys, length = math.Round(p.length), diff_db = math.Round(p.diffDb, 1),
				door_db = math.Round(p.doorDb, 1), level_db = math.Round(p.level or 0, 1),
				absorb_db = math.Round(p.absorbDb or 0, 1), diffuse = math.Round(p.diffuse or 0, 2), ratio = p.direct and math.Round(p.length / math.max(p.direct, 1), 2),
				bend = p.bendDeg and math.Round(p.bendDeg), az = math.Round(A.Azimuth(L, ang.y, p.pos), 1) }
		end
		A.Report("paths", { name = data.SoundName, relayed = relayed, aS = r.aS, aL = r.aL, voices = vs, paths = ps,
			trans = r.trans and { loss_db = math.Round(r.trans.lossDb, 1), raw_db = math.Round(r.trans.rawLossDb or r.trans.lossDb, 1),
				mid_db = math.Round(r.trans.midDb or 0, 1), walls = #r.trans.walls, lp = r.trans.lp },
			ms = math.Round(rec.ms, 3) })
	end
	return true
end

-- Soundscape ambience (C_SoundscapeSystem "playrandom", "position random"): emitted on the world,
-- CHAN_STATIC, usually SNDLVL_140db, 36 u around the ear. Not a source in the room: left to the engine
-- (else muffled behind a wall the random point landed behind: 5 of 16 directions near a wall on
-- d1_town_01, and echoed as a "140 dB" source). Fixed-position soundscape sounds (far) stay pba's.
local SCAPE_RADIUS = 64
local scapeWaves, scapeMap
local function soundscapeWave(name)
	if scapeMap ~= game.GetMap() then
		scapeMap, scapeWaves = game.GetMap(), {}
		local files = { "scripts/soundscapes_" .. scapeMap .. ".txt" }
		for f in string.gmatch(file.Read("scripts/soundscapes_manifest.txt", "GAME") or "", '"file"%s+"([^"]+)"') do files[#files + 1] = f end
		for _, f in ipairs(files) do
			for w in string.gmatch(file.Read(f, "GAME") or "", '"wave"%s+"([^"]+)"') do
				scapeWaves[string.lower((string.gsub(A.SoundFile(w), "\\", "/")))] = true
			end
		end
	end
	return scapeWaves[string.lower((string.gsub(A.SoundFile(name), "\\", "/")))] or false
end
function A.IsSoundscapeRandom(data, pos)
	if data.Channel ~= CHAN_STATIC or (A.cfg.soundscape_engine or 1) < 0.5 then return false end
	local e = data.Entity
	if not (e and e.IsWorld and e:IsWorld()) then return false end
	local L = A.ListenerPos()
	return L ~= nil and pos:DistToSqr(L) <= SCAPE_RADIUS * SCAPE_RADIUS and soundscapeWave(data.SoundName)
end

-- (fallback: a partial autorefresh may reload this file before sh_core)
A.AddHook("EntityEmitSound", (A.WithChannelRule or function(f) return f end)(function(data)
	if A.reemitting then return end
	if bit.band(data.Flags or 0, SND_STOP) ~= 0 then
		-- a client-side StopSound: our copies of that sound stop too (the engine stops its own)
		local idx = sourceIndex(data)
		if idx then A.StopCopies(idx, data.SoundName) end
		if idx and A.Loops and A.Loops.StopClient then A.Loops.StopClient(idx, nil, data.SoundName) end
		return
	end
	-- long client-side sounds (music of client-side radios): followed like a loop
	if A.Loops and A.Loops.HandleClient and A.Loops.HandleClient(data) then return false end
	if not A.Eligible(data) then return end
	local pos = A.SoundPos(data)
	if not pos then return end
	-- soundscape ambience around the ear: the engine's own (before the echoes)
	if A.IsSoundscapeRandom(data, pos) then return end
	-- echoes (native reflections) for loud sounds, whoever plays the direct sound
	if A.Native and A.Native.render and A.Enabled() then A.Native.Echo(data, pos) end
	local ply = LocalPlayer()
	if IsValid(ply) and data.Entity == ply then return end -- own sounds: always clear
	data.Pos = pos
	if A.Process(data, false) then return false end
end))

-- relayed server sounds: always played by us (the server suppressed the original)
A.dict = A.dict or {}
local pendingAcks = {}
timer.Create("pba_ack", 0.2, 0, function()
	if #pendingAcks == 0 then return end
	net.Start("pba_snd_ack")
	local n = math.min(#pendingAcks, 64)
	net.WriteUInt(n, 8)
	for i = 1, n do net.WriteUInt(table.remove(pendingAcks, 1), 16) end
	net.SendToServer()
end)

net.Receive(NET, function()
	local id, full, echoOnly = net.ReadUInt(16), net.ReadBool(), net.ReadBool()
	local name
	if full then
		name = net.ReadString()
		if A.dict[id] ~= name then
			A.dict[id] = name
			pendingAcks[#pendingAcks + 1] = id
		end
	else
		name = A.dict[id]
	end
	local data = {
		SoundName = name, Pos = net.ReadVector(), SoundLevel = net.ReadUInt(9),
		Pitch = net.ReadUInt(8), Volume = net.ReadUInt(8) / 255, Channel = net.ReadInt(10),
		Flags = net.ReadUInt(16), DSP = net.ReadUInt(8), EntIndex = net.ReadUInt(16),
	}
	if not name then return end -- id never received (lost first packets): drop
	if A.Native and A.Native.render and A.Enabled() then A.Native.Echo(data, data.Pos) end
	-- the engine already plays this one for us (clear line of sight): only the echoes were wanted
	if echoOnly then return end
	A.stats.relayedIn = A.stats.relayedIn + 1
	if A.Enabled() and A.Process(data, true) then return end
	-- not processed (disabled client, clear path...): play it as the engine would have
	local e = Entity(data.EntIndex)
	if IsValid(e) and not e:IsWorld() and data.Channel ~= CHAN_AUTO and not A.IsSentence(data.SoundName) then
		A.Emit(e.EmitSound, e, data.SoundName, data.SoundLevel, data.Pitch, data.Volume, data.Channel, data.Flags, data.DSP)
	else
		A.EmitAt(data.SoundName, data.Pos, IsValid(e) and data.EntIndex or 0, data.Channel, data.Volume,
			data.SoundLevel, data.Flags, data.Pitch, data.DSP)
	end
end)

-- caption of a suppressed server sound (sv_relay sendCaption); nothing shown with closecaption 0
net.Receive("pba_caption", function()
	local tok, dur = net.ReadString(), net.ReadFloat()
	local txt = language.GetPhrase(tok)
	if txt and txt ~= tok then gui.AddCaption(txt, dur > 0 and dur or 2, false) end
end)

-- client-side StopSound (predicted weapons...): our copies of that entity's sound stop too
do
	local ENT = FindMetaTable("Entity")
	A.origCl = A.origCl or { StopSound = ENT.StopSound }
	function ENT:StopSound(name)
		A.origCl.StopSound(self, name)
		local idx = self:EntIndex()
		if idx > 0 and A.StopCopies then pcall(A.StopCopies, idx, name or "") end
		if idx > 0 and A.Loops and A.Loops.StopClient then pcall(A.Loops.StopClient, idx, nil, name or "") end
	end
end

-- server-side StopSound on a relayed sound: stop our copies
net.Receive("pba_snd_stop", function()
	local idx, name = net.ReadUInt(16), net.ReadString()
	A.StopCopies(idx, name)
end)

-- entity removed on the client (not a full network update): its copies stop with it
hook.Add("EntityRemoved", "pba_copies_removed", function(e, fullUpdate)
	if fullUpdate then return end
	local idx = e:EntIndex()
	if idx > 0 then A.StopCopies(idx, "") end
end)
