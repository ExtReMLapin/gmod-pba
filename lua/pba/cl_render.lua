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
-- (an NPC line, a weapon), and StopSound stops a sound by name. Copies re-emitted by pba are
-- tracked per (entity, channel): engine copies are played by small invisible anchors (one per
-- voice) on the original channel, so the engine applies those rules itself; native voices are
-- stopped explicitly. Unassigned channels (CHAN_AUTO / CHAN_STATIC) never replace.
A.copies = A.copies or {} -- "idx:chan" -> { idx, chan, anchors = { slot -> ent }, native = { { id, name } }, t }
local function replaces(chan) return chan and chan ~= CHAN_AUTO and chan ~= CHAN_STATIC and chan > 0 end

-- one-shots followed while they play (see below): records, anchors of the sounds on unassigned
-- channels (CHAN_AUTO / CHAN_STATIC: no copy set), native voice id -> followed voice
A.OneShots = A.OneShots or {}
local OS = A.OneShots
OS.recs = OS.recs or {}
OS.pool = OS.pool or {}   -- { ent, busy = time its sound ends, t = last use }
OS.native = OS.native or {}

--- Stops a native copy (a copy rule: new sound on the channel, StopSound): never driven again.
local function stopNative(id)
	if pba_native then pba_native.StopVoice(id) end
	local fv = OS.native[id]
	if fv then fv.dead = true OS.native[id] = nil end
end

local function anchorCount()
	local n = 0
	for _, cc in pairs(A.copies) do
		for _, x in pairs(cc.anchors) do if IsValid(x) then n = n + 1 end end
	end
	for _, p in ipairs(OS.pool) do if IsValid(p.ent) then n = n + 1 end end
	return n
end

local function sourceIndex(data)
	local idx = data.EntIndex
	if (not idx or idx == 0) and IsValid(data.Entity) and not data.Entity:IsWorld() then idx = data.Entity:EntIndex() end
	return (idx and idx > 0) and idx or nil
end

--- Copy set of a sound's source; a new sound on a replacing channel cuts the previous copies.
local function beginCopies(data)
	local idx = sourceIndex(data)
	local chan = data.Channel or CHAN_AUTO
	if not idx or not replaces(chan) then return nil end
	local key = idx .. ":" .. chan
	local c = A.copies[key]
	if not c then
		c = { idx = idx, chan = chan, anchors = {}, native = {} }
		A.copies[key] = c
	end
	c.t = RealTime()
	for _, n in ipairs(c.native) do stopNative(n[1]) end
	c.native = {}
	for _, a in pairs(c.anchors) do
		if IsValid(a) and a.pbaName then a:StopSound(a.pbaName) a.pbaName = nil end
	end
	return c
end

local function anchorFor(c, slot)
	local a = c.anchors[slot]
	if IsValid(a) then return a end
	-- cap on client entities: beyond it, the caller plays the copy at a position instead
	if anchorCount() >= (A.cfg.max_anchors or 48) then return nil end
	a = ClientsideModel("models/hunter/blocks/cube025x025x025.mdl", RENDERGROUP_OTHER)
	if not IsValid(a) then return nil end
	a:SetNoDraw(true)
	c.anchors[slot] = a
	return a
end

--- Stops the copies of `name` (all names if empty) re-emitted for entity idx.
function A.StopCopies(idx, name)
	name = name or ""
	for _, c in pairs(A.copies) do
		if c.idx == idx then
			for _, a in pairs(c.anchors) do
				if IsValid(a) and a.pbaName and (name == "" or a.pbaName == name) then a:StopSound(a.pbaName) a.pbaName = nil end
			end
			for i = #c.native, 1, -1 do
				if name == "" or c.native[i][2] == name then
					stopNative(c.native[i][1])
					table.remove(c.native, i)
				end
			end
		end
	end
end

-- idle copy sets: anchors removed after 30 s
timer.Create("pba_copies_gc", 5, 0, function()
	local now = RealTime()
	for key, c in pairs(A.copies) do
		if now - (c.t or 0) > 30 then
			for _, a in pairs(c.anchors) do if IsValid(a) then a:Remove() end end
			A.copies[key] = nil
		end
	end
	for i = #OS.pool, 1, -1 do
		local pa = OS.pool[i]
		if not IsValid(pa.ent) or (pa.busy < now and now - pa.t > 30) then
			if IsValid(pa.ent) then pa.ent:Remove() end
			table.remove(OS.pool, i)
		end
	end
end)

--- Anchor of a followed copy on an unassigned channel (no copy set): a sound played at a fixed
-- position cannot be moved, one played by an entity follows it. Busy until its sound ends.
local function poolAnchor(tEnd)
	local now = RealTime()
	for _, pa in ipairs(OS.pool) do
		if IsValid(pa.ent) and pa.busy < now then pa.busy, pa.t = tEnd, now return pa.ent end
	end
	if anchorCount() >= (A.cfg.max_anchors or 48) then return nil end
	local a = ClientsideModel("models/hunter/blocks/cube025x025x025.mdl", RENDERGROUP_OTHER)
	if not IsValid(a) then return nil end
	a:SetNoDraw(true)
	OS.pool[#OS.pool + 1] = { ent = a, busy = tEnd, t = now }
	return a
end

--- Emits one voice. play: seconds the sound plays when it is to be followed (nil otherwise).
-- Returns false when nothing was emitted, else a handle: { id = native voice } or { a = anchor,
-- seq = emission number on it, chan } (both followable), or {} (a copy at a fixed position).
local function emitVoice(data, v, L, src, copies, slot, play)
	-- native rendering: the module plays the voice itself (HRTF + EQ); no engine compensation
	-- (a sentence is a sequence of words played by the engine: never by the module)
	if A.Native and A.Native.render and not A.IsSentence(data.SoundName) then
		local g = (data.Volume or 1) * v.gain * A.Native.Directivity(src, L)
		if g < 0.001 then return false end
		local delay = voiceDelay(v, L)
		local id = A.Native.PlayVoice(data.SoundName, v.pos, g, v.lp, data.Pitch, { len = v.len, sh = v.sh, delay = delay })
		if id then
			v.vol, v.dsp, v.native = g, -1, true
			if copies then copies.native[#copies.native + 1] = { id, data.SoundName } end
			return { id = id, t0 = RealTime() + delay }
		end
	end
	local lvl = data.SoundLevel
	local d = v.pos:Distance(L)
	local vol = (data.Volume or 1) * v.gain / AC.EngineGain(math.max(d, 1), lvl)
	vol = math.min(vol, 1)
	if vol < 0.01 then return false end
	local dsp = AC.DSPForLevel(v.lp)
	if dsp == 0 then dsp = data.DSP or 0 end
	local flags = bit.band(data.Flags or 0, bit.bnot(SND_CHANGE_VOL + SND_CHANGE_PITCH + SND_STOP))
	local delay = voiceDelay(v, L)
	local name, pos, pitch = data.SoundName, v.pos, data.Pitch or 100
	local sentence = A.IsSentence(name)
	-- a sentence plays at a position (EmitSentence): no anchor, so not followed
	local anchor = not sentence and copies and anchorFor(copies, slot or 1)
	-- a followed copy on an unassigned channel gets an anchor of its own (CHAN_AUTO, as before)
	if not anchor and not sentence and not copies and play then anchor = poolAnchor(RealTime() + delay + play) end
	local chan = copies and copies.chan or CHAN_AUTO
	local h = {}
	if anchor then
		h.seq = (anchor.pbaSeqNext or 0) + 1
		anchor.pbaSeqNext = h.seq
		h.a, h.chan, h.dsp, h.pool = anchor, chan, dsp, not copies
	end
	h.t0 = RealTime() + (delay >= 0.02 and delay or 0)
	local function emit()
		if anchor then
			if not IsValid(anchor) then return end
			anchor:SetPos(pos)
			anchor.pbaName, anchor.pbaSeq = name, h.seq
			A.Emit(anchor.EmitSound, anchor, name, lvl, pitch, vol, chan, flags, dsp)
			h.started = true
		else
			A.EmitAt(name, pos, -1, CHAN_AUTO, vol, lvl, flags, pitch, dsp)
		end
	end
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
-- the same anchor, channel and name; the DSP preset of an engine sound cannot change mid-sound.
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

local function freePool(fv)
	if not fv.pool then return end
	for _, pa in ipairs(OS.pool) do if pa.ent == fv.a then pa.busy = 0 end end
end

local function stopAnchor(fv, name)
	if not anchorAlive(fv, name) then return end
	fv.a:StopSound(name)
	fv.a.pbaName = nil
	freePool(fv)
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
			stopAnchor(fv, rec.name)
		end
	end
end

--- Values a voice of rec is driven to for target t (P.FollowAssign): gain, 3 EQ bands, position,
-- pitch. Engine copies: the volume the engine needs at that position (its own distance law applies).
local function targetValues(rec, fv, t, L)
	if fv.id then
		local N = A.Native
		local el, em, eh = N.VoiceEQ(t.lp, t.len)
		-- Doppler of a moving source or listener, as loops and clear voices (N.UpdateFollowers) have it
		local k = N.Doppler and N.Doppler(rec.S, N.VelocityOf(rec.ent), L, N.ListenerVelocity()) or 1
		return rec.vol * t.gain * N.Directivity(rec.dirEnt, L) * A.cfg.native_gain, el, em, eh, t.pos, rec.pitch * k
	end
	local d = t.pos:Distance(L)
	return math.min(rec.vol * t.gain / AC.EngineGain(math.max(d, 1), rec.lvl), 1), 1, 1, 1, t.pos, rec.pitch
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
			P.RampTo(fv.ramp, now, dur, L, targetValues(rec, fv, t, L))
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
			A.Paths.Retarget(fv.ramp, targetValues(rec, fv, { pos = S, gain = AC.EngineGain(math.max(d, 1), rec.lvl), lp = 0, len = d }, L))
			return -- the dominant one; the others fade out
		end
	end
end

local function applyVoice(rec, fv, now, L)
	local g, e1, e2, e3, pos, pitch = A.Paths.RampAt(fv.ramp, now, L)
	fv.pos = pos
	if fv.id then
		if not pba_native.Update(fv.id, pos, g, e1, e2, e3, pitch) then fv.dead = true return end
	else
		local a = fv.a
		a:SetPos(pos)
		-- volume: steps of 0.5 dB at most along the ramp, exact at its end; never close to the end
		local s = fv.sent or g
		if rec.wav and now < fv.tEnd - MIN_LEFT and g > 0 and g ~= s
			and (not fv.ramp.pending or math.abs(g - s) > 0.06 * math.max(g, s)) then
			A.Emit(a.EmitSound, a, rec.name, rec.lvl, rec.pitch, g, fv.chan, SND_CHANGE_VOL, fv.dsp)
			fv.sent = g
		end
	end
	if fv.fading and not fv.ramp.pending then
		if fv.id then
			pba_native.StopVoice(fv.id)
			OS.native[fv.id] = nil
		else
			stopAnchor(fv, rec.name)
		end
		fv.dead = true
	end
end

--- Starts following a one-shot just emitted. list: { { h = handle from emitVoice, v = voice } } in
-- emission order (the dominant first); play: seconds it plays; r: the evaluation it was emitted with.
function OS.Add(data, src, S, L, r, list, play)
	local now = RealTime()
	local tEnd = 0
	for _, e in ipairs(list) do tEnd = math.max(tEnd, e.h.t0 + play) end
	local slot = A.Paths.FollowSlot(OS.recs, now, A.cfg.oneshot_follow_max or 16, tEnd, MIN_LEFT)
	if not slot then return nil end
	if OS.recs[slot] then dropRec(OS.recs[slot]) end
	OS.seq = (OS.seq or 0) + 1
	local ent = IsValid(src) and not src:IsWorld() and src or nil
	local name = data.SoundName
	local rec = { key = OS.seq, name = name, ent = ent, dirEnt = IsValid(src) and src or nil, S = S, lvl = data.SoundLevel or 75,
		vol = data.Volume or 1, pitch = data.Pitch or 100, tEnd = tEnd, tNext = now + followInterval(), hyst = {},
		clearPath = r.clear or not r.voices or #r.voices == 0,
		wav = string.lower(string.GetExtensionFromFilename(name) or "") == "wav", voices = {} }
	A.Paths.Stable(rec.hyst, r) -- the hysteresis starts from what was emitted
	local N = A.Native
	for _, e in ipairs(list) do
		local fv, v = e.h, e.v
		fv.tEnd, fv.pos, fv.ramp = fv.t0 + play, v.pos, {}
		if fv.id then
			local el, em, eh = N.VoiceEQ(v.lp, v.len)
			A.Paths.RampTo(fv.ramp, now, 0, L, v.vol * A.cfg.native_gain, el, em, eh, v.pos, rec.pitch)
			OS.native[fv.id] = fv
			-- a clear voice bound to its entity (N.follow): driven from here now
			if N.follow and N.follow[fv.id] then fv.nfollow, N.follow[fv.id] = N.follow[fv.id], nil end
		else
			fv.sent = v.vol
			A.Paths.RampTo(fv.ramp, now, 0, L, v.vol, 1, 1, 1, v.pos, rec.pitch)
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
			if not fv.dead and fv.a then
				-- an anchor whose copy was cut (new sound on its channel, StopSound) or never started
				if fv.started then
					if not anchorAlive(fv, rec.name) then fv.dead = true end
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
			local g = (data.Volume or 1) * AC.EngineGain(math.max(d, 1), lvl) * A.Native.Directivity(IsValid(src) and src or nil, L)
			-- PlayVoice only (no engine fallback here: the caller plays the original if this fails)
			local follow = IsValid(src) and not src:IsWorld() and { ent = src, vol = data.Volume or 1, lvl = lvl } or nil
			local delay = voiceDelay({ len = d, pos = S }, L)
			local id = A.Native.PlayVoice(data.SoundName, S, g, 0, data.Pitch, { len = d, delay = delay, follow = follow })
			if id then
				A.stats.nativeDirect = (A.stats.nativeDirect or 0) + 1
				-- followed while it plays: walking behind a wall must muffle it too
				local play = math.max(A.SoundDuration(data.SoundName) or 0.5, 0.1) * 100 / math.max(data.Pitch or 100, 1)
				if OS.Wanted(play) then
					OS.Add(data, src, S, L, r, { { h = { id = id, t0 = RealTime() + delay }, v = { pos = S, vol = g, lp = 0, len = d } } }, play)
				end
				return true
			end
		end
		A.stats.vanilla = A.stats.vanilla + 1
		return false
	end
	local now = RealTime()
	local dur = math.max(A.SoundDuration(data.SoundName) or 0.5, 0.1)
	local budget = A.cfg.max_active - activeCount(now)
	local copies = beginCopies(data)
	local emitted = 0
	-- seconds it plays (pitch included): followed while it plays when long enough
	local play = dur * 100 / math.max(data.Pitch or 100, 1)
	local follow = OS.Wanted(play) and {} or nil
	for i, v in ipairs(r.voices) do
		if i > 1 and emitted >= budget then A.stats.dropped = A.stats.dropped + 1 break end
		local h = emitVoice(data, v, L, IsValid(src) and src or nil, copies, i, follow and play)
		if h then
			emitted = emitted + 1
			A.active[#A.active + 1] = now + dur
			-- every voice must be drivable (a copy at a fixed position cannot move): else none is
			if follow then
				if h.id or h.a then follow[#follow + 1] = { h = h, v = v } else follow = nil end
			end
		end
	end
	if follow and #follow > 0 then OS.Add(data, src, S, L, r, follow, play) end
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
				guard_db = math.Round(p.guardDb or 0, 1), ratio = p.direct and math.Round(p.length / math.max(p.direct, 1), 2),
				bend = p.bendDeg and math.Round(p.bendDeg), az = math.Round(A.Azimuth(L, ang.y, p.pos), 1) }
		end
		A.Report("paths", { name = data.SoundName, relayed = relayed, aS = r.aS, aL = r.aL, voices = vs, paths = ps,
			trans = r.trans and { loss_db = math.Round(r.trans.lossDb, 1), raw_db = math.Round(r.trans.rawLossDb or r.trans.lossDb, 1),
				mid_db = math.Round(r.trans.midDb or 0, 1), walls = #r.trans.walls, lp = r.trans.lp },
			ms = math.Round(rec.ms, 3) })
	end
	return true
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
		Pitch = net.ReadUInt(8), Volume = net.ReadUInt(8) / 255, Channel = net.ReadInt(8),
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
