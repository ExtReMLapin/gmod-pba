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

--- True once this frame's path-search budget is spent (cheaper fallback for the rest): the one budget of
-- every sound kind (cl_sched.lua).
function A.FrameBudgetExceeded() return A.Sched.BudgetExceeded() end

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
local replaces = A.ReplacingChannel

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
	-- a mouth copy (mouthCopy): the engine's own stop of its name on the speaker's index and channel
	if h.mouth then
		A.reemitting = true
		local e = Entity(h.idx)
		if IsValid(e) then (A.origCl and A.origCl.StopSound or e.StopSound)(e, h.name)
		else EmitSound(h.name, h.pos, h.idx, h.srcChan, 0, h.lvl, SND_STOP, h.pitch, 0) end
		A.reemitting = false
		return
	end
	-- a far one-shot held while its routes are computed (A.Process): never emitted, its evaluation dropped
	if h.job then
		if A.Slicer then A.Slicer.Cancel(h.job) end
		return
	end
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

--- Removes copy h of entity idx from the registry (a held one-shot's placeholder, once emitted).
local function unregister(idx, h)
	local list = idx and A.emitted[idx]
	if not list then return end
	for i = #list, 1, -1 do if list[i] == h then table.remove(list, i) end end
	if #list == 0 then A.emitted[idx] = nil end
end

--- Records a copy of entity idx (nothing for a source without an entity: no StopSound can name it).
-- data: the sound it plays; its `cutAfter` (beginCopies: a channel-rule cut of the server that was read before this relayed copy)
-- stops the copy that long after its own start.
local function register(idx, h, data)
	if not idx then return end
	if data and data.cutAfter and h.t0 then
		local at = h.t0 + data.cutAfter
		h.cutAt = at
		timer.Simple(A.RealDelay(math.max(at - RealTime(), 0)), function() stopCopy(h) end)
	end
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

--- The channel rule on the client (sh_core A.CutsChannel; called by A.WithChannelRule for the client's own
-- sounds, by beginCopies for relayed ones, by the client long sounds of cl_loops): what entity idx plays
-- on channel chan stops, every copy (anchors, native voices, those at a fixed position past the anchor
-- cap, mouth copies) and every client-side long sound mirror (whichever started it: a long line cut the
-- brief copies of its channel, a brief one the long mirror).
-- only: "copies" or "mirrors" restricts the cut to one kind (pba_channel_one_rule 0: each path cut its own).
-- `delay` (s, pba_cut_at_start): when the new sound STARTS after that long (the start time its stamp carries, its
-- propagation delay), the copies it replaces play on until then, as the engine's delayed channel does (the stop of the old
-- sound is scheduled at the new one's start). Cut on arrival, a burst of shots reaching the client together (each
-- delayed by its own stamp) stopped every shot but the last before it had begun.
function A.CutChannel(idx, chan, only, delay)
	if A.WatchCut then A.WatchCut(idx, chan) end -- (a watched line there is over: pba_handback_channel)
	local list = only ~= "mirrors" and A.emitted[idx]
	if list then
		local later = delay and delay >= 0.005 and (A.cfg.cut_at_start or 1) >= 0.5
		local held
		for i = #list, 1, -1 do
			local h = list[i]
			if h.srcChan == chan then
				if later then
					-- (it stays registered: StopSound, a removal, a later cut still reach it)
					local at = RealTime() + delay
					if not h.cutAt or at < h.cutAt then
						h.cutAt = at
						held = held or {}
						held[#held + 1] = h
					end
				else
					stopCopy(list[i]) table.remove(list, i)
				end
			end
		end
		if held then
			timer.Simple(A.RealDelay(delay), function()
				for _, h in ipairs(held) do stopCopy(h) end
			end)
		end
		if #list == 0 then A.emitted[idx] = nil end
	end
	if only ~= "copies" and A.Loops and A.Loops.StopClient then A.Loops.StopClient(idx, chan) end
end

-- Channel-rule cuts of the server read in this frame or just before (pba_snd_stop with the stamp of the sound that replaces):
-- key idx:chan -> { { ms = stamp of the replacing sound, t = RealTime() read } }. The reliable pba_snd_stop is read BEFORE the
-- unreliable relays of the same packet (measured 6/6), so a copy relayed in the packet of the cut that replaces it reaches the client
-- AFTER it: nothing to cut yet, it played on to its end (0.225 s more than the engine's, which stops it at the new sound's start).
local CUT_KEEP = 0.5 -- (s: the stamp window, ST_MAX of the relayed sounds)
A.cutPending = A.cutPending or {}

--- Notes a stamped cut of entity idx's channel chan (cl_render's pba_snd_stop receiver), for the copies still to come.
function A.NoteCut(idx, chan, ms)
	local key = idx .. ":" .. chan
	local now = RealTime()
	local list = A.cutPending[key]
	if not list then list = {} A.cutPending[key] = list end
	for i = #list, 1, -1 do if now - list[i].t > CUT_KEEP then table.remove(list, i) end end
	list[#list + 1] = { ms = ms, t = now }
	if #list > 16 then table.remove(list, 1) end
end

--- Seconds after its own start that a relayed copy stamped `stampMs` on entity idx's channel chan must stop, because a cut read
-- before it replaces it (the first cut stamped later than the copy within CUT_KEEP of it); nil: none.
local function cutAfter(idx, chan, stampMs)
	local list = stampMs and A.cutPending[idx .. ":" .. chan]
	if not list then return nil end
	local now, best = RealTime(), nil
	for i = #list, 1, -1 do
		local c = list[i]
		if now - c.t > CUT_KEEP then
			table.remove(list, i)
		else
			local d = (c.ms - stampMs) % 65536
			if d >= 32768 then d = d - 65536 end
			d = d / 1000
			if d >= 0.005 and d <= CUT_KEEP and (not best or d < best) then best = d end
		end
	end
	return best
end

--- The kind a path cuts under pba_channel_one_rule 0 (nil: everything, the one rule).
function A.ChannelCutOnly(kind)
	if (A.cfg.channel_one_rule or 1) >= 0.5 then return nil end
	return kind
end

--- Copy set of a sound's source on a replacing channel; a new sound there cuts every earlier copy of
-- that channel (A.CutChannel).
local function beginCopies(data, idx)
	local chan = data.Channel or CHAN_AUTO
	if not idx or not replaces(chan) then return nil end
	if A.CutsChannel(chan, data.Flags) then
		-- (the new sound's start: its stamp's delay, and the propagation delay when pba_delay is on)
		local d = data.Delay or 0
		if (A.cfg.delay or 0) >= 0.5 and data.Pos then
			local L = A.ListenerPos()
			if L then d = d + data.Pos:Distance(L) / SPEED end
		end
		A.CutChannel(idx, chan, A.ChannelCutOnly("copies"), d)
	end
	-- (a relayed copy the server's cut already read replaces: it stops at that sound's start, pba_cut_at_start)
	if (A.cfg.cut_at_start or 1) >= 0.5 then data.cutAfter = cutAfter(idx, chan, data.stampMs) end
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

--- Stops the copies of `name` (all names if empty) re-emitted for entity idx, on channel chan (any
-- channel when nil or CHAN_AUTO).
function A.StopCopies(idx, name, chan)
	name = name or ""
	local list = A.emitted[idx]
	if not list then return end
	if chan == CHAN_AUTO then chan = nil end
	-- the name asked, a wave or a sound script (each of its waves), by file: as given or as played (a
	-- muffled "#" sound is played without its "#")
	local files = A.StopFiles(name)
	for i = #list, 1, -1 do
		local h = list[i]
		if (not chan or h.srcChan == chan) and (A.StopReaches(files, h.orig) or A.StopReaches(files, h.name)) then
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
	h.tEnd = h.t0 + A.AtPitch(secs, h.pitch) -- (the end-of-file rule, sh_core)
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

--- Seconds `name` plays at `pitch` (A.PlaySeconds, the end-of-file rule of sh_core), and the key of its file
-- while its length is unknown (then the seconds are UNKNOWN_CAP and BASS reads its length once).
local function playLength(name, pitch)
	local secs = A.PlaySeconds(name, pitch)
	if secs then return secs end
	if A.IsSentence(name) then return UNKNOWN_CAP, "!" end -- not a file: no length to read
	local key = string.lower(A.SoundFile(name))
	if A.lengthProbe[key] == nil and sound and sound.PlayFile then
		A.lengthProbe[key] = true
		sound.PlayFile("sound/" .. key, "noplay", function(ch)
			local len = IsValid(ch) and ch:GetLength() or -1
			if IsValid(ch) then ch:Stop() end
			A.lengthProbe[key] = (len and len > 0) and len or false
			if len and len > 0 then onLength(key, len) end
		end)
		-- (a callback run at once: the length is already known)
		secs = A.PlaySeconds(name, pitch)
		if secs then return secs end
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
-- copy is registered for the stop rules); waited: seconds since the sound was made (a far one-shot held
-- while its routes were computed: its propagation delay counts from the sound, not from now). Returns
-- false when nothing was emitted, else a handle:
-- { id = native voice } or { a = anchor, seq = emission number on it, chan } (both followable), or
-- { pos } (a copy at a fixed position); each with t0 / tEnd (start, expected end), name (as played),
-- orig (as asked), srcChan (the sound's own channel).
--- True when a sound carries its own DSP preset that pba keeps (pba_keep_dsp): a radio or loudspeaker
-- effect (EmitSound's dsp argument, a scene's special DSP). The module has no DSP presets, a voice it
-- plays would lose the effect (parity plan P1-9): such a sound stays with the engine.
function A.OwnDSP(dsp)
	return (dsp or 0) ~= 0 and (A.cfg.keep_dsp or 1) >= 0.5
end

--- The speech floor's gain for a line of volume vol and level lvl from S heard at L (pba_speech_floor_db).
local function speechFloorAt(vol, S, L, lvl)
	return (vol or 1) * AC.EngineGain(math.max(S:Distance(L), 1), lvl or 75) * 10 ^ ((A.cfg.speech_floor_db or -20) / 20)
end

--- pba_speech_floor_db: a line on a face (a voice channel of an entity with flexes) is never rendered quieter than
-- this many dB under the engine's clear law for it: the gain floor (linear, absolute) of its loudest voice, or nil.
-- Alyx's lines behind the lab walls of d1_trainstation_05 (one transmission, -37 dB under the clear law, absolute
-- -50 dB) got no engine copy at all in Light mode (a copy below volume 0.01 is dropped; the engine plays nothing
-- below about -38 dB anyway): taken from the engine, captioned, never heard. Vanilla plays them at the clear law.
local function speechFloor(data, src, L)
	local fdb = A.cfg.speech_floor_db or -20
	if fdb <= -80 or not data.Pos or A.IsSentence(data.SoundName) then return nil end
	local ch = data.Channel
	local face = data.Face or ((ch == CHAN_VOICE or ch == CHAN_VOICE2) and IsValid(src) and not src:IsWorld()
		and (src.GetFlexNum and src:GetFlexNum() or 0) > 0)
	if not face then return nil end
	return speechFloorAt(data.Volume, data.Pos, L, data.SoundLevel)
end

--- True when sound data is a spoken line (a voice channel, or a loudspeaker's copy): decoded on its first play
-- (pba_native_line_decode, N.EnsureSound) so the module renders it as the lines around it.
local function isLine(data)
	local ch = data.Channel
	return ch == CHAN_VOICE or ch == CHAN_VOICE2 or bit.band(data.Flags or 0, SND_SPEAKER or 64) ~= 0
end

-- keep (finish: a cheap result too quiet to emit): the voice at the quietest level emitted, 1 dB over the
-- emission thresholds below (native gain 0.001, engine volume 0.01)
local KEEP_GAIN = 10 ^ (1 / 20)
-- (pba_native_late_handover) True when the module is still decoding the file `name` and could take over an
-- engine copy of it later: the option, a module whose Play takes a start offset, a decode in progress.
local function lateWanted(name)
	local N = A.Native
	return (A.cfg.native_late_handover or 1) >= 0.5 and playOffsetOK() and N ~= nil and N.DecodePending ~= nil and N.DecodePending(name)
end

-- (pba_loops_start_sync) The copies of one emission of a line (a speaker line: the Breencast's two jumbotrons, one
-- emission) start together. A.Process names the emission (data.pbaEmKey: file + start stamp, or the frame a stampless
-- one arrived in); each copy is evaluated on its own, and the one the frame's budget did not leave time for is held in
-- the slicer (pba_burst_hold_ms) or just comes later in the frame: 5-95 ms behind its twin, the same level behind a
-- door = a comb filter (output autocorrelation 0.43-0.48 at the lag, warbly speech; 0.1 in step). A copy that starts
-- after another one of its emission plays from where that one is (A.CopySync, as the long-line mirrors). The moment
-- its file's second 0 falls is its start less its propagation delay (physical, kept) and its stamp delay.
-- (a copy of the same emission later than COPY_MAX_S is not made to catch up: the frames of a machine at 10 fps are 0.1 s)
local COPY_MAX_S = 1
local function copyStart(data, delay, prop)
	local key = data.pbaEmKey
	if not key or not playOffsetOK() then return nil, nil end
	-- (the file decoded first, as PlayVoice does: a cold decode is 10-20 ms that belong to the voice, not to its start)
	A.Native.EnsureSound(data.SoundName, isLine(data) and (A.cfg.native_line_decode or 1) >= 0.5)
	local z = SysTime() + delay - prop - (data.Delay or 0)
	return A.CopySync.Offset(key, z, data.SoundName, data.Pitch, COPY_MAX_S), z
end

local function emitVoice(data, v, L, src, copies, slot, life, ukey, follow, idx, waited, keep)
	local floor = slot == 1 and speechFloor(data, src, L) or nil
	local srcChan, orig, pitch = data.Channel or CHAN_AUTO, data.SoundName, data.Pitch or 100
	-- native rendering: the module plays the voice itself (HRTF + EQ); no engine compensation
	-- (a sentence: by the module when its words are rendered into one sound, cl_sentences; else by the
	-- engine, PlayVoice failing below)
	-- (a sound with its own DSP preset, pba_keep_dsp: the engine's, the module has no presets: A.OwnDSP)
	local nativeOK = A.Render.NativeOK(data.SoundName, data.DSP)
	if not nativeOK and A.IsSentence(data.SoundName) then A.Sentences.Note(data.SoundName, false, A.Sentences.WhyNot(data.DSP)) end
	if nativeOK then
		-- the full version's distance law (N.PhysPath): real spreading instead of the engine's law
		-- a weapon's dipole: the aim taken now, at emission (N.Directivity)
		local dirK = A.Native.Directivity(src, L, data.Channel)
		local g = (data.Volume or 1) * A.Native.PhysPath(v.gain, v.len, data.SoundLevel or 75, v.rawLossDb) * dirK
		if floor then g = math.max(g, floor) end
		if keep then g = math.max(g, 0.001 * KEEP_GAIN) end
		if g < 0.001 then
			if A.IsSentence(data.SoundName) then A.Sentences.Note(data.SoundName, false, "inaudible") end
			return false
		end
		local delay = math.max(voiceDelay(v, L) - (waited or 0), 0)
		local spk = bit.band(data.Flags or 0, SND_SPEAKER or 64) ~= 0 and A.Native.SPEAKER_EQ or nil
		-- the dominant voice carries the source's air-borne reverb (its slot); a transmission voice feeds
		-- the listener's room; the other voices no reverb of their own (no double count)
		local S = data.Pos
		-- a loud sound already echoed by the echo slots (not "all native") takes no source slot too
		local echoed = (A.cfg.native_all or 0) < 0.5 and (data.SoundLevel or 75) >= (A.cfg.native_echo_lvl or 95)
		local dominant = slot == 1 and not echoed and S
		local srcSend = dominant and (data.Volume or 1) * A.Native.PhysSrcSend(data.SoundLevel or 75, S:Distance(L)) * dirK
		-- the listener's room: what this path brings to where it enters the listener's space (one rule for
		-- every sound: N.EntrySend with the sound's law)
		local lvl0 = data.SoundLevel or 75
		local wet = A.Native.LoudWet(lvl0)
		local roomSend = (data.Volume or 1) * dirK * A.Native.EntrySend(A.Native.Law(lvl0), v, L, A.Native.LossLin(v, lvl0)) * wet
		local offset, z = copyStart(data, delay, voiceDelay(v, L))
		local id = A.Native.PlayVoice(data.SoundName, v.pos, g, v.lp, data.Pitch, { len = v.len, sh = v.sh, delay = delay, offset = offset, eq = spk, lpDb = v.lpDb,
			diffuse = v.diffuse, srcPos = dominant or nil, srcSend = srcSend, roomSend = roomSend, noRoom = true, wet = wet, line = isLine(data), protect = A.Native.ProtectLine(data.Channel), pausable = A.Native.PauseFlag(data.Flags),
			own = A.Native.OwnDirect(src, data.Channel),
			mix = A.Mix and A.Mix.GroupsOf(data.SoundName, src or data.EntIndex, data.Channel, lvl0) })
		if id then
			v.vol, v.dsp, v.native = g, -1, true
			if z then A.CopySync.Note(data.pbaEmKey, z, offset) end
			local t0 = RealTime() + delay - (offset or 0) -- (where its file's second 0 falls)
			local h = { id = id, t0 = t0, tEnd = t0 + life, ukey = ukey, pitch = pitch, name = data.SoundName, orig = orig, srcChan = srcChan }
			register(idx, h, data)
			return h
		end
	end
	local lvl = data.SoundLevel
	v.epos = A.DistVariantPos(data.SoundName, v.pos, L, data.Pos)
	local d = v.epos:Distance(L)
	local vol = (data.Volume or 1) * v.gain / AC.EngineGain(math.max(d, 1), lvl)
	if floor then vol = math.max(vol, floor / AC.EngineGain(math.max(d, 1), lvl)) end
	if keep then vol = math.max(vol, 0.01 * KEEP_GAIN) end
	vol = math.min(vol, 1)
	if vol < 0.01 then return false end
	local tunnel = heldTunnel(idx and (idx .. ":" .. (slot or 1)), v.diffuse, RealTime())
	local dsp = presetFor(v.lp, tunnel)
	-- the sound's own preset (a radio or speaker effect) is part of the sound: kept, muffled by volume
	local own = (A.cfg.keep_dsp or 1) >= 0.5 and (data.DSP or 0) ~= 0
	if dsp == 0 or own then dsp = data.DSP or 0 end
	local flags = bit.band(data.Flags or 0, bit.bnot(SND_CHANGE_VOL + SND_CHANGE_PITCH + SND_STOP))
	local delay = math.max(voiceDelay(v, L) - (waited or 0), 0)
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
	-- (pba_native_late_handover) the module refused the voice only because its file is still decoding: a
	-- followed copy (long enough to be followed, drivable by its anchor) is handed over when the decode ends
	if anchor and follow and nativeOK and not ukey and lateWanted(data.SoundName) then h.late = true end
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
	register(idx, h, data)
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
-- (one margin and one interval for every followed sound: cl_sched.lua)
local MIN_LEFT = A.Sched.MIN_LEFT
local KEEP_RAMP_S = 0.1 -- (a sound kept alive from a cheap result: the glide to its first full result, finish)

local followInterval = A.Sched.Interval

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
	if A.Slicer then A.Slicer.Drop(rec) end -- (its evaluation still running in slices, if any)
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
		-- Doppler of a moving source or listener, as loops and clear voices (N.UpdateFollowers) have it
		local el, em, eh = N.VoiceEQ(t.lp, t.len, t.lpDb)
		local pitch
		-- a speaker's EQ, as at emission (pba_native_speaker_follow)
		local spk = rec.speaker and (A.cfg.native_speaker_follow or 1) >= 0.5
		el, em, eh, pitch = A.Render.Tail(el, em, eh, rec.pitch, spk, rec.S, rec.ent, L)
		local g = rec.vol * N.PhysPath(t.gain, t.len, rec.lvl, t.rawLossDb) * N.Directivity(rec.dirEnt, L, rec.chan, rec.aim)
		-- a speaking face's loudest voice keeps its floor while followed (pba_speech_floor_db)
		if rec.speech and fv == rec.voices[1] then g = math.max(g, speechFloorAt(rec.vol, rec.S, L, rec.lvl)) end
		return g * A.cfg.native_gain, el, em, eh, t.pos, pitch
	end
	local pos = A.DistVariantPos(rec.name, t.pos, L, rec.S)
	local d = pos:Distance(L)
	local vol = rec.vol * t.gain / AC.EngineGain(math.max(d, 1), rec.lvl)
	if rec.speech and fv == rec.voices[1] then vol = math.max(vol, speechFloorAt(rec.vol, rec.S, L, rec.lvl) / AC.EngineGain(math.max(d, 1), rec.lvl)) end
	return math.min(vol, 1), 1, 1, 1, pos, rec.pitch
end

--- The voice of the new selection that target t was built from (P.FollowAssign keeps its pos): the
-- target gets its continuous loss, raw loss, diffuse share and kind, which FollowAssign leaves out
-- (targetValues read t.lpDb / t.rawLossDb and always got nil: the native EQ stepped between levels and a
-- loud source's loss was recovered from a gain that the headroom had absorbed, see N.PhysPath).
local function enrich(t, vs)
	local sv = t.src
	if not sv then for _, v in ipairs(vs) do if rawequal(v.pos, t.pos) then sv = v break end end end
	if not sv then return nil end
	-- (a group's spectrum mixed by energy, P.FollowAssign, is kept)
	t.lpDb, t.diffuse, t.kind = t.lpDb or sv.lpDb, sv.diffuse, sv.kind
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
	-- (pba_native_late_handover: lateCheck found its file decoded: handed over whatever its muffling)
	local late = fv.late and fv.lateReady
	if not late and (A.cfg.oneshot_native_switch or 1) < 0.5 then return false end
	local N = A.Native
	if not (pba_native and pba_native.Play and A.Render.NativeOK(rec.name, nil, false)) then return false end
	-- a switch near the end is not worth a second voice (the end of a compressed file can be off)
	if now > fv.tEnd - MIN_LEFT - followInterval() then return false end
	if not playOffsetOK() then return false end
	return late or math.abs((t.lp or 0) - fv.lp0) >= 1 or (fv.tunnel0 ~= nil and fv.tunnel ~= fv.tunnel0)
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
	-- the listener's room: what the path brings to its entry point (N.EntrySend), clear sight: none
	local roomSend = t.len and t.pos and t.pos:DistToSqr(rec.S) > 1 and rec.vol * N.EntrySend(N.Law(rec.lvl), t, L, N.LossLin(t, rec.lvl))
		* N.Directivity(rec.dirEnt, L, rec.chan, rec.aim) * A.cfg.native_gain * N.LoudWet(rec.lvl) or 0
	-- the engine's mix value and ducking (cl_mix): the record's groups, found once
	if A.Mix and not rec.mixG then rec.mixG = A.Mix.GroupsOf(rec.name, rec.ent, rec.chan, rec.lvl) end
	local protect = N.ProtectLine(rec.chan)
	local pausable = N.PauseFlag(rec.flags)
	local id = A.Mix and A.Mix.Play(rec.mixG, n, pos, g, el, em, eh, pitch, false, 0, sh, t.diffuse or 0, roomSend, offset, protect, pausable)
		or pba_native.Play(n, pos, g, el, em, eh, pitch, false, 0, sh, t.diffuse or 0, roomSend, offset, protect, pausable)
	if not id or id <= 0 then
		fv.switchFails = (fv.switchFails or 0) + 1
		return false
	end
	A.NoteRendered(rec.name, g)
	-- reverb as at emission (emitVoice / N.PlayVoice): the dominant voice feeds its source slot unless a
	-- loud sound is already echoed; without a slot, a voice that is not a transmission feeds the room
	local echoed = (A.cfg.native_all or 0) < 0.5 and rec.lvl >= (A.cfg.native_echo_lvl or 95)
	local bound = false
	if dominant and not echoed and rec.S then
		local srcSend = rec.vol * N.PhysSrcSend(rec.lvl, rec.S:Distance(L)) * N.Directivity(rec.dirEnt, L, rec.chan, rec.aim) * A.cfg.native_gain
		bound = N.BindSource(id, rec.S, srcSend)
	end
	if not bound and roomSend <= 0 then pba_native.Update(id, pos, g, el, em, eh, pitch, nil, g * N.LoudWet(rec.lvl)) end
	fv.stSel, fv.stW = nil, nil
	if rec.S then N.ApplyStereo(id, rec.name, t.len or rec.S:Distance(L), rec.dirEnt, rec.S, L, fv) end
	-- the engine copy stops once the module has it (stopCopy without cancelling the handle)
	local a, name = fv.a, fv.name or rec.name
	if anchorAlive(fv, name) then a:StopSound(name) a.pbaName = nil end
	if IsValid(a) and a.pbaSeqNext == fv.seq then a.pbaEnd = 0 end -- free for the next copy
	fv.a, fv.seq, fv.chan, fv.dsp, fv.sent = nil, nil, nil, nil, nil
	fv.id, fv.switched = id, true
	fv.late, fv.lateReady = nil, nil
	OS.native[id] = fv
	fv.sh = t.sh or false
	fv.shSent = sh and fv.sh or false
	A.Paths.RampTo(fv.ramp, now, 0, L, g, el, em, eh, pos, pitch)
	fv.ramp.pending = false -- played with these values
	A.stats.nativeSwitch = (A.stats.nativeSwitch or 0) + 1
	return true
end

-- A followed one-shot's voice rendered as one of two strategies (refactor step 11, A.Render.Strategy): an
-- engine copy (fv.a, an anchor's EmitSound) or a module voice (fv.id). update sends the ramp's values of now
-- (false: the voice is gone), stop ends it; start of the module's is the switch from an engine copy at the
-- same point of the sound (switchNative), the one change of strategy a voice makes (A.Render.Switch).
local VOICE = A.Render.Strategy("oneshot")
VOICE.native = {
	start = switchNative,
	update = function(rec, fv, now, L, g, e1, e2, e3, pos, pitch)
		-- baked path field (native_path_fx): a voice played along its path kept its Play-time arrival
		-- direction while the listener walked round the corner. Sent when it changes (a table: along the
		-- new path; false: straight line at pos; nil: kept); diffuse and send (args 8, 9) nil: kept.
		local want = (A.cfg.native_path_fx or 0) >= 0.5 and fv.sh or false
		local sh = nil
		if want ~= fv.shSent then sh, fv.shSent = want, want end
		if not pba_native.Update(fv.id, pos, g, e1, e2, e3, pitch, nil, nil, sh) then return false end
		if rec.S and A.Native then A.Native.ApplyStereo(fv.id, rec.name, rec.S:Distance(L), rec.dirEnt, rec.S, L, fv) end
		return true
	end,
	stop = function(fv)
		pba_native.StopVoice(fv.id)
		OS.native[fv.id] = nil
	end,
}
VOICE.engine = {
	update = function(rec, fv, now, L, g, e1, e2, e3, pos, pitch)
		local a = fv.a
		a:SetPos(pos)
		-- volume: steps of 0.5 dB at most along the ramp, exact at its end; never close to the end
		local s = fv.sent or g
		if rec.wav and now < fv.tEnd - MIN_LEFT and g > 0 and g ~= s
			and (not fv.ramp.pending or math.abs(g - s) > 0.06 * math.max(g, s)) then
			A.Emit(a.EmitSound, a, fv.name or rec.name, rec.lvl, rec.pitch, g, fv.chan, SND_CHANGE_VOL, fv.dsp)
			fv.sent = g
		end
		return true
	end,
	stop = function(fv)
		stopCopy(fv) -- its anchor freed, its registry entry ended
	end,
}
local function VOICE_OF(fv) return fv.id and VOICE.native or VOICE.engine end

local evaluate
-- a followed one-shot's far evaluation is ready (cl_slicer): applied at once, if it still plays
local function followReady(rec)
	local L = A.ListenerPos()
	for _, x in ipairs(OS.recs) do
		if x == rec then
			if L then evaluate(rec, RealTime(), L) end
			return
		end
	end
end

function evaluate(rec, now, L)
	local P = A.Paths
	local ent = IsValid(rec.ent) and rec.ent or nil
	if ent then rec.S = A.SoundPos({ Entity = ent, Channel = rec.chan }) end
	local S = rec.S
	-- a far sound's evaluation may run in slices (cl_slicer): its voices keep their course until it is ready
	-- a file already muffled by water (a deep explosion's): no water surface wall on top (P.WaterWall)
	local r = P.Evaluate(rec, S, L, rec.lvl, ent, A.Render.WaterDry(rec, rec.name), followReady)
	if not r then return end
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
	-- (kept alive from a cheap result too quiet to emit, finish: its first full result reached quickly)
	if rec.keptCheap then dur, rec.keptCheap = math.min(dur, KEEP_RAMP_S), nil end
	for i, fv in ipairs(live) do
		local t = targets[i]
		if t then
			enrich(t, vs)
			-- the tunnel choice this copy would need now, held near diffuse_dsp_at (clear sight: none)
			if fv.a then fv.tunnel = AC.DiffuseHold(t.diffuse or 0, fv.tunnel, hystMargin()) end
			fv.sh = t.sh or false -- its new path's baked field (none: straight line to its position)
			if not (wantsNative(rec, fv, t, now) and A.Render.Switch(VOICE, "native", rec, fv, t, L, now, i == 1)) then
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
	local S = A.SoundPos({ Entity = rec.ent, Channel = rec.chan })
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
	local st = VOICE_OF(fv)
	if not st.update(rec, fv, now, L, g, e1, e2, e3, pos, pitch) then fv.dead = true return end
	if fv.fading and not fv.ramp.pending then
		st.stop(fv)
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
		chan = data.Channel, aim = aim0, flags = data.Flags,
		vol = data.Volume or 1, pitch = data.Pitch or 100, tEnd = tEnd, tNext = now + followInterval(), hyst = {},
		clearPath = r.clear or not r.voices or #r.voices == 0, ukey = ukey,
		-- volume changes need a trusted end (see MIN_LEFT): never for a sound of unknown length
		wav = not ukey and string.lower(string.GetExtensionFromFilename(name) or "") == "wav", voices = {},
		speech = speechFloor(data, src, L) ~= nil or nil, -- (pba_speech_floor_db: its loudest voice kept above the floor)
		speaker = bit.band(data.Flags or 0, SND_SPEAKER or 64) ~= 0 or nil } -- (N.SPEAKER_EQ kept while followed)
	A.Paths.Stable(rec.hyst, r) -- the hysteresis starts from what was emitted
	local N = A.Native
	for _, e in ipairs(list) do
		local fv, v = e.h, e.v
		fv.tEnd, fv.pos, fv.ramp = fv.t0 + play, v.epos or v.pos, {}
		if fv.id then
			local el, em, eh = N.VoiceEQ(v.lp, v.len, v.lpDb)
			-- the ramp starts from what was played: a speaker's EQ included (pba_native_speaker_follow)
			if rec.speaker and (A.cfg.native_speaker_follow or 1) >= 0.5 then
				el, em, eh = el * N.SPEAKER_EQ[1], em * N.SPEAKER_EQ[2], eh * N.SPEAKER_EQ[3]
			end
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

-- (pba_native_late_handover) A followed engine copy emitted while its file was still decoding (fv.late, emitVoice)
-- is looked at every frame (N.LateVerdict): the frame the decode has ended, its record is evaluated now (that
-- gives the voice its target) and wantsNative hands the copy over (fv.lateReady) at the point of the sound
-- reached, through A.Render.Switch like every change of rendering. Stopped, ended, refused or without a
-- module that takes a start offset: the copy stays with the engine, and is looked at no more.
local LATE_TRIES = 12 -- evaluations that found nothing to hand over (a far evaluation held by the slicer...)
local function lateCheck(rec, fv, now, L)
	local N = A.Native
	if not (N and N.LateVerdict) then fv.late = nil return end
	local on = (A.cfg.native_late_handover or 1) >= 0.5 and N.render and pba_native ~= nil and pba_native.Play ~= nil
		and (fv.switchFails or 0) < 3 and not rec.ukey and A.Render.NativeOK(rec.name, nil, false)
	local decode = "pending"
	if on then
		local ok, _, why = N.EnsureSound(rec.name)
		decode = ok and "ready" or why == "pending" and "pending" or "failed"
	end
	local gone = fv.cancelled or fv.dead or fv.fading or not fv.a
		or (fv.started and not anchorAlive(fv, fv.name or rec.name))
	local verdict, why = N.LateVerdict(on and true or false, playOffsetOK(), decode, fv.started and true or false, gone and true or false,
		now, fv.t0, fv.tEnd, MIN_LEFT + followInterval())
	if verdict == "wait" then return end
	if verdict == "drop" then
		fv.late, fv.lateReady = nil, nil
		A.stats["lateDrop_" .. why] = (A.stats["lateDrop_" .. why] or 0) + 1
		return
	end
	fv.lateReady = true
	if now < (fv.lateNext or 0) then return end
	fv.lateNext, fv.lateTries = now + followInterval(), (fv.lateTries or 0) + 1
	if fv.lateTries > LATE_TRIES then fv.late, fv.lateReady = nil, nil return end
	rec.tNext = now + followInterval() -- (this evaluation stands for the next scheduled one)
	evaluate(rec, now, L)
end

--- Every frame (the scheduler's tick, cl_sched.lua): re-evaluates each followed one-shot by the cadence
-- rule of every sound (A.Sched.Due: at most once per update_interval, each on its own clock from its
-- emission, and only when it, the listener or the world moved: reeval_adaptive), glides its voices, drops it
-- when it ends.
function OS.Tick()
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
			for _, fv in ipairs(rec.voices) do
				if fv.late and not fv.dead then lateCheck(rec, fv, now, L) end
			end
			if now >= rec.tNext then
				local S = IsValid(rec.ent) and A.SoundPos({ Entity = rec.ent, Channel = rec.chan }) or rec.S
				if A.Sched.Due(rec, S, L, now, rec.tEnd) then
					rec.tNext = now + followInterval()
					evaluate(rec, now, L)
				end
			end
			followClear(rec, L)
			for _, fv in ipairs(rec.voices) do
				-- an engine copy is driven once really started (a SND_CHANGE_VOL before would start it)
				if not fv.dead and fv.ramp.pending and now >= fv.t0 and (fv.id or fv.started) then applyVoice(rec, fv, now, L) end
			end
		end
	end
end

--- Plays a sound as the engine would have (pba does not take it: relayed and not processed, or a held one
-- whose evaluation found nothing to play).
local function vanilla(data)
	local e = IsValid(data.Entity) and data.Entity or Entity(data.EntIndex or 0)
	if IsValid(e) and not e:IsWorld() and data.Channel ~= CHAN_AUTO and not A.IsSentence(data.SoundName) then
		A.Emit(e.EmitSound, e, data.SoundName, data.SoundLevel, data.Pitch, data.Volume, data.Channel, data.Flags, data.DSP)
	else
		A.EmitAt(data.SoundName, data.Pos, IsValid(e) and e:EntIndex() or 0, data.Channel, data.Volume,
			data.SoundLevel, data.Flags, data.Pitch, data.DSP)
	end
end

local finish

--- pba_quiet_db: true when the engine would play a sound of level lvl and volume vol at distance d
-- below that level (dB re full scale, clear line). Such a sound is left to the engine without any
-- path search (a soundscape's water lapping 50 m away, -42 dB, searched routes over 2600 u).
function A.TooQuiet(lvl, vol, d)
	local q = A.cfg.quiet_db or -40
	if q <= -100 then return false end
	return (vol or 1) * AC.EngineGain(math.max(d, 1), lvl) < 10 ^ (q / 20)
end

--- Processes one sound. Returns true when pba took charge of it (the original must
-- not be played), even if every voice ended up inaudible; false = play it as vanilla.
-- Lip sync: the client moves a face from the voices the ENGINE plays on that entity (C_BaseFlex::ProcessVisemes
-- reads MouthInfo's voice sources, attached by the engine's mixer with the line's phonemes). A voice pba plays
-- itself (native module, a copy elsewhere) leaves the mouth still: the same line plays on the speaker at a
-- volume nobody hears (-60 dB; 0 could be culled by the mixer), on the same voice channel (a later line cuts it
-- as it cuts the original).
-- A speaker this client does not have (never in its view since it joined: out of the PVS, behind a closed
-- areaportal) gets its copy all the same, by entity index, when the server says the line is on a face
-- (data.Face): the engine keeps the channel under that index as it keeps the original's in vanilla, and the
-- face that comes into view during the line moves its mouth (pba_lipsync_unseen).
local MOUTH_VOL = A.MOUTH_VOL

--- Tells the server this player's lip sync choice: it also picks the long lines' mouth copy, which the
-- server plays (sv_loops MouthStart), as pba_lipsync picks the short lines' one below.
function A.SendLipsyncPref()
	if not IsValid(LocalPlayer()) then return end
	net.Start("pba_lipsync_pref")
	net.WriteBool((A.cfg.lipsync or 1) >= 0.5)
	net.SendToServer()
end
A.OnInitPostEntity("pba_lipsync_pref", A.SendLipsyncPref)
timer.Simple(0, A.SendLipsyncPref) -- (a reload after InitPostEntity)

local function mouthCopy(data, src)
	if (A.cfg.lipsync or 1) < 0.5 then return end
	local ch = data.Channel
	if ch ~= CHAN_VOICE and ch ~= CHAN_VOICE2 then return end
	local idx, pos
	if IsValid(src) then
		if src:IsWorld() or (src.GetFlexNum and src:GetFlexNum() or 0) == 0 then return end
		idx, pos = src:EntIndex(), src:GetPos()
	else
		if not data.Face or (A.cfg.lipsync_unseen or 1) < 0.5 or (data.EntIndex or 0) <= 0 or not data.Pos then return end
		idx, pos = data.EntIndex, data.Pos
	end
	local name = data.SoundName or ""
	if name == "" then return end
	A.reemitting = true
	if A.IsSentence(name) then
		-- a sentence: the engine's sentence mixer drives the mouth word by word (played on the speaker)
		EmitSentence(string.sub(name, 2), pos, idx, ch, MOUTH_VOL, data.SoundLevel or 75, 0, data.Pitch or 100)
	elseif IsValid(src) then
		src:EmitSound(name, data.SoundLevel or 75, data.Pitch or 100, MOUTH_VOL, ch)
	else
		EmitSound(name, pos, idx, ch, MOUTH_VOL, data.SoundLevel or 75, 0, data.Pitch or 100)
	end
	A.reemitting = false
	-- registered as a copy of the speaker: the stop path (StopSound, scene cancel, stopsound) and the channel
	-- rule reach it as they reach the line's other copies (pba_lipsync_stop; a sentence's words play on)
	if (A.cfg.lipsync_stop or 1) >= 0.5 and not A.IsSentence(name) then
		register(idx, { mouth = true, idx = idx, name = name, orig = name, srcChan = ch, pos = pos,
			lvl = data.SoundLevel or 75, pitch = data.Pitch or 100,
			tEnd = A.PlayEnd(name, data.Pitch or 100) or RealTime() + (A.cfg.max_duration or 8) })
	end
	A.stats.mouthCopies = (A.stats.mouthCopies or 0) + 1
	if A.OnMouthCopy then A.OnMouthCopy(idx) end -- (test watchdog: copies by index, the entity may be NULL here)
end

--- A client-side sound beyond lod_dist (no path search) behind a wall (pba_far_muffle): the cheap muffle in
-- its own data (DSP preset, the walls' loss; P.MuffleFor) for the hook to return true. It was heard through
-- the wall as in plain sight. True when it changed the data.
function A.FarMuffle(data, pos)
	local L = listenerPos()
	if not L then return false end
	local dsp, gain = A.Render.Far(pos, L, data.Entity) -- (the one far rule of copies and mirrors, cl_renders.lua)
	if not dsp then return false end
	-- a "#" (dry mix) sound gets no DSP from the engine: the same file without it
	if dsp > 0 then data.SoundName, data.DSP = A.WithoutDryMix(data.SoundName), dsp end
	data.Volume = (data.Volume or 1) * gain
	A.stats.farMuffled = (A.stats.farMuffled or 0) + 1
	return true
end

-- ------------------------------------------------------------------ bursts (pba_burst_budget_ms, pba_burst_mask_db)
-- A burst (barrels, an explosion's debris) is dozens of new sounds in one frame, each evaluated at once:
-- 16 ms per frame behind a wall on gm_construct, up to 125 ms on d1_canals_01 (PERF bench S1, S11).
-- burst_budget_ms bounds the time new sounds' full evaluations take in a frame; past it a new sound gets, in
-- this order: its emitter's recent result (same entity, both ends within BURST_REUSE_U, world unchanged, at
-- most reeval_max_s old), the far slicer when its distance leaves a frame (SL.Defer), else the cheap model
-- (P.Cheap: the walls' transmission, never vanilla through a wall). burst_mask_db: within BURST_MASK_S of a
-- loud sound, a sound more than that many dB quieter at the ear (its level in plain sight, no trace)
-- gets the cheap model at once. A followed degraded sound gets its full evaluation at its next update.
-- pba_burst_fair (the cheap model ignores the routes round the walls: an 80 dB impact behind a wall with an
-- open doorway came out 29 dB under its full result, then jumped up at its first update 0.1-0.26 s later,
-- +18..+49 dB in the 2026-11-14 sweep): before the cheap model, a new sound takes the recent full result of a
-- nearby source of its level whatever its emitter (bullet impacts, debris: the world or new entities, never
-- the same emitter twice); a new sound louder at the ear than the loudest of the window (an explosion) is
-- never degraded (the budget goes to what is heard).
local BURST_REUSE_U = 64
local BURST_NEAR_U, BURST_NEAR_N, BURST_LOUDER_DB = 128, 32, 6
local BURST_MASK_S = 0.1
local BURST_REF_U = 36
A.burst = A.burst or { frame = -1, spent = 0, loudT = -1, loudDb = -math.huge,
	byEmitter = setmetatable({}, { __mode = "k" }) }
A.burst.loudT, A.burst.loudDb = A.burst.loudT or -1, A.burst.loudDb or -math.huge -- (a reload over the budget's version)
A.burst.near = A.burst.near or {} -- (pba_burst_fair) the last BURST_NEAR_N full results, a ring
A.burst.nearI = A.burst.nearI or 0
function A.ResetBurstStats() A.burstStats = { full = 0, reused = 0, deferred = 0, cheap = 0, masked = 0 } end
if not A.burstStats then A.ResetBurstStats() end

-- the masking verdict for a new sound at ear level db (dB re full scale), and the loudest of the window
local function masked(db, now, maskDb)
	local B = A.burst
	local live = B.loudT >= 0 and now - B.loudT <= BURST_MASK_S
	local m = live and db < B.loudDb - maskDb
	if not live or db >= B.loudDb then B.loudT, B.loudDb = now, db end
	return m
end

-- (pba_burst_fair) the recent full result of the nearest source within BURST_NEAR_U of S, of level lvl, heard
-- from within BURST_REUSE_U of L, the world unchanged: whatever its emitter
local function nearResult(S, L, lvl, now, dry)
	local B, P = A.burst, A.Paths
	local best, bd = nil, BURST_NEAR_U * BURST_NEAR_U
	local r2, maxAge = BURST_REUSE_U * BURST_REUSE_U, A.cfg.reeval_max_s or 1
	for _, m in pairs(B.near) do
		if m.gen == P.cacheGen and m.lvl == lvl and m.dry == dry and now - m.t <= maxAge and m.L:DistToSqr(L) <= r2 then
			local d = m.S:DistToSqr(S)
			if d <= bd then best, bd = m, d end
		end
	end
	return best and best.r
end

-- (pba_burst_hold_ms) a degraded sound that will be followed (it plays long enough: OS.Wanted) would start at the
-- cheap model's level, a lower bound, and glide up to its full result at its first update: instead its full
-- evaluation is queued in the slicer (SL.Defer) and the sound held until it is there, within the longer of its
-- propagation delay and the hold. Returns the job, or nil (hold off, not followed, slicer off).
-- (pba_burst_hold_short) a short sound (not followed: OS.Wanted false) would keep the cheap model its whole life,
-- 26-36 dB under its full result behind a doorway (a lower bound, no routes round the walls, never corrected by an
-- update): it is held too, its start a few tens of ms late being the lesser evil.
local function holdJob(data, S, L, lvl, src, cfg)
	local hold = (A.cfg.burst_hold_ms or 50) / 1000
	if hold <= 0 or not A.Slicer then return nil end
	if (A.cfg.burst_hold_short or 1) < 0.5 and not OS.Wanted((playLength(data.SoundName, data.Pitch))) then return nil end
	return A.Slicer.Defer(S, L, lvl, src, cfg, hold)
end

-- the ring of recent full results (pba_burst_fair, pba_impact_group): r evaluated for a source at S heard from L
local function noteNear(r, S, L, lvl, dry, now)
	local B = A.burst
	B.nearI = B.nearI % BURST_NEAR_N + 1
	local m = B.near[B.nearI] or {}
	m.r, m.t, m.gen, m.lvl, m.dry = r, now, A.Paths.cacheGen, lvl, dry
	if m.S then m.S:Set(S) m.L:Set(L) else m.S, m.L = Vector(S), Vector(L) end
	B.near[B.nearI] = m
end

local function burstEvaluate(data, S, L, lvl, src)
	local P, B, st = A.Paths, A.burst, A.burstStats
	local dry = A.Render.WaterDry(nil, data.SoundName)
	local cfg = dry and P.DRY_SOURCE_CFG or nil
	local now = RealTime()
	-- (pba_impact_group) a dense family of world sounds (a chopper's impacts): a nearby full result serves, whatever the budget
	if data.pbaDense then
		local n = nearResult(S, L, lvl, now, dry)
		if n then st.grouped = (st.grouped or 0) + 1 return n end
	end
	local maskDb = A.cfg.burst_mask_db or 25
	local fair = (A.cfg.burst_fair or 1) >= 0.5
	-- its level at the ear, in plain sight: SNDLVL at 36 u (about 1 m), spherical spreading beyond (the
	-- engine's gain, clamped to full scale, put a 140 dB explosion 9 dB over an 80 dB impact at 20 m)
	local db = lvl + 20 * math.log10(math.max(data.Volume or 1, 1e-4)) - 20 * math.log10(math.max(S:Distance(L), BURST_REF_U) / BURST_REF_U)
	-- (pba_burst_fair) louder than everything of the window by BURST_LOUDER_DB: the one heard, never degraded
	local loudest = fair and not (B.loudT >= 0 and now - B.loudT <= BURST_MASK_S and db < B.loudDb + BURST_LOUDER_DB)
	if maskDb > 0 then
		if masked(db, now, maskDb) then
			st.masked = st.masked + 1
			local n = fair and nearResult(S, L, lvl, now, dry)
			if n then st.reused = st.reused + 1 return n end
			local job = holdJob(data, S, L, lvl, src, cfg)
			if job then
				st.deferred = st.deferred + 1
				return nil, job
			end
			return P.Cheap(S, L, lvl, cfg, src)
		end
	elseif fair and (B.loudT < 0 or now - B.loudT > BURST_MASK_S or db >= B.loudDb) then
		B.loudT, B.loudDb = now, db -- (the window is kept for the loudest rule with masking off)
	end
	local budget = (A.cfg.burst_budget_ms or 2) / 1000
	local fr = FrameNumber()
	if B.frame ~= fr then B.frame, B.spent = fr, 0 end
	if budget > 0 and B.spent >= budget and not loudest then
		local m = src and B.byEmitter[src]
		local r2 = BURST_REUSE_U * BURST_REUSE_U
		if m and m.gen == P.cacheGen and m.lvl == lvl and now - m.t <= (A.cfg.reeval_max_s or 1)
			and m.S:DistToSqr(S) <= r2 and m.L:DistToSqr(L) <= r2 then
			st.reused = st.reused + 1
			return m.r
		end
		local n = fair and nearResult(S, L, lvl, now, dry)
		if n then st.reused = st.reused + 1 return n end
		local job = holdJob(data, S, L, lvl, src, cfg) or (A.Slicer and A.Slicer.Defer(S, L, lvl, src, cfg))
		if job then
			st.deferred = st.deferred + 1
			return nil, job
		end
		st.cheap = st.cheap + 1
		local t0 = SysTime()
		local r = P.Cheap(S, L, lvl, cfg, src)
		B.spent = B.spent + (SysTime() - t0)
		return r
	end
	local t0 = SysTime()
	local r, job = P.Evaluate(nil, S, L, lvl, src, dry)
	B.spent = B.spent + (SysTime() - t0)
	st.full = st.full + 1
	if r and src and budget > 0 then
		local m = B.byEmitter[src] or {}
		m.r, m.t, m.gen, m.lvl, m.S, m.L = r, now, P.cacheGen, lvl, Vector(S), Vector(L)
		B.byEmitter[src] = m
	end
	if r and (fair or data.pbaWorld) and not r.cheap then noteNear(r, S, L, lvl, dry, now) end
	return r, job
end
A.BurstNote = noteNear -- (a held sound's evaluation finished in the slicer: Process)
A.BurstEvaluate = burstEvaluate -- (tests: test/burst_fair.lua)

function A.Process(data, relayed)
	local L, ang = listenerPos()
	local S = data.Pos
	if A.Sched then A.Sched.NoteSound(data.SoundLevel) end -- a fight heard: background builds slow down (O6)
	if not L or not S then return false end
	if A.Mix then A.Mix.NoteSound(data, L) end -- heard: the mixer's ducker (cl_mix)
	-- a sentence with virtual words (V_...): its words picked now for this sound (cl_sentences_virtual)
	if A.SentenceVirtual and A.IsSentence(data.SoundName) then A.SentenceVirtual.Begin(data, S, L) end
	if A.IsSentence(data.SoundName) then A.Sentences.stats.emitted = A.Sentences.stats.emitted + 1 end -- (pba_sentences_report)
	-- a new sound on a replacing channel cuts the earlier copies of that channel, even when this one
	-- is left to the engine (clear sight, too far): an NPC's new line heard in clear sight played over
	-- its previous line still coming through the doorway
	local idx = sourceIndex(data)
	local copies = beginCopies(data, idx)
	local lvl = data.SoundLevel or 75
	if S:Distance(L) > A.cfg.lod_dist then
		if A.IsSentence(data.SoundName) then A.Sentences.Note(data.SoundName, false, "far") end
		return false
	end
	if A.TooQuiet(lvl, data.Volume, S:Distance(L)) then
		A.stats.quiet = (A.stats.quiet or 0) + 1
		if A.IsSentence(data.SoundName) then A.Sentences.Note(data.SoundName, false, "quiet") end
		return false
	end
	local t0 = SysTime()
	local src = data.Entity
	if not IsValid(src) and data.EntIndex and data.EntIndex > 0 then src = Entity(data.EntIndex) end
	local tReq = RealTime()
	local r, job
	-- a file already muffled by water (a deep explosion's): no water surface wall on top (P.WaterWall)
	-- the listener's own sound (pba_native_own, centered on him): nothing to save on, never degraded or held
	local ownSound = IsValid(src) and src == LocalPlayer() and A.NativeOwn and A.NativeOwn() and A.HearsFromSelf(src)
	-- (pba_loops_start_sync) the emission this copy belongs to: its file and start stamp (a stampless one: the frame it arrived in)
	if (A.cfg.loops_start_sync or 1) >= 0.5 and isLine(data) then
		data.pbaEmKey = "s|" .. data.SoundName .. "|" .. (data.stampMs and ("t" .. data.stampMs) or ("f" .. FrameNumber()))
	end
	if not ownSound and ((A.cfg.burst_budget_ms or 2) > 0 or (A.cfg.burst_mask_db or 25) > 0 or data.pbaDense) then
		r, job = burstEvaluate(data, S, L, lvl, IsValid(src) and src or nil)
	else
		r, job = A.Paths.Evaluate(nil, S, L, lvl, IsValid(src) and src or nil, A.Render.WaterDry(nil, data.SoundName))
	end
	if not r and job then
		-- a far sound whose routes are computed in slices (cl_slicer): taken now (the original is not
		-- played), emitted once they are ready, by the time the sound would reach the listener at the
		-- latest, its propagation delay counted from now (emitVoice's `waited`). A placeholder copy stands
		-- in the registry meanwhile: the stop rules (StopSound, a new sound on its channel, its entity
		-- removed) cancel it, and a cancelled sound never starts.
		local d = {}
		for k, v in pairs(data) do d[k] = v end
		local h = { job = job, t0 = tReq, tEnd = job.deadline + 1, name = d.SoundName, orig = d.SoundName, srcChan = d.Channel or CHAN_AUTO }
		register(idx, h)
		data.heldUntil = job.deadline -- (pba_silent_handback waits for it)
		A.stats.held = (A.stats.held or 0) + 1
		local feeds = data.pbaWorld
		job.onDone = function(res)
			unregister(idx, h)
			if h.cancelled then return end
			h.cancelled = true -- (the placeholder's part is over)
			-- (a world sound of a family counted by pba_impact_group: its full result serves the next ones near it, burstEvaluate)
			if feeds and res and not res.cheap then A.BurstNote(res, S, L, lvl, A.Render.WaterDry(nil, d.SoundName), RealTime()) end
			if not res or not finish(d, relayed, idx, copies, S, L, ang, src, res, RealTime() - tReq - (d.Delay or 0), SysTime()) then vanilla(d)
			else mouthCopy(d, src) end
		end
		return true
	end
	-- (a relayed sound's own start time, A.SoundTimeDelay: a negative "waited", it starts that much later)
	local taken = finish(data, relayed, idx, copies, S, L, ang, src, r, -(data.Delay or 0), t0)
	if taken then mouthCopy(data, src) end
	return taken
end

--- The rest of A.Process once the sound's evaluation r is there: its voices emitted (waited: seconds since
-- the sound was made, see emitVoice), followed, counted. Returns as A.Process.
function finish(data, relayed, idx, copies, S, L, ang, src, r, waited, t0)
	local lvl = data.SoundLevel or 75
	A.DebugNote(nil, S, L, r, data.SoundName, A.Native and A.Native.render and "native" or "sound")
	if r.clear or not r.voices or #r.voices == 0 then
		-- "everything native": a clear sound is played by the module at its real position
		if A.Native and A.Native.render and (A.cfg.native_all or 0) >= 0.5 and (not A.IsSentence(data.SoundName) or A.Sentences.On())
			and not A.OwnDSP(data.DSP) then
			local d = S:Distance(L)
			local dir = A.Native.Directivity(IsValid(src) and src or nil, L, data.Channel)
			local g = (data.Volume or 1) * A.Native.PhysClear(lvl, d) * dir
			-- PlayVoice only (no engine fallback here: the caller plays the original if this fails)
			local follow = IsValid(src) and not src:IsWorld() and { ent = src, vol = data.Volume or 1, lvl = lvl, chan = data.Channel } or nil
			local prop = voiceDelay({ len = d, pos = S }, L)
			local delay = math.max(prop - waited, 0)
			local spk = bit.band(data.Flags or 0, SND_SPEAKER or 64) ~= 0 and A.Native.SPEAKER_EQ or nil
			local offset, z = copyStart(data, delay, prop)
			local id = A.Native.PlayVoice(data.SoundName, S, g, 0, data.Pitch, { len = d, delay = delay, offset = offset, follow = follow, eq = spk, srcPos = S,
				srcSend = (data.Volume or 1) * A.Native.PhysSrcSend(lvl, d) * dir, wet = A.Native.LoudWet(lvl), line = isLine(data), protect = A.Native.ProtectLine(data.Channel), pausable = A.Native.PauseFlag(data.Flags),
				own = A.Native.OwnDirect(src, data.Channel),
				mix = A.Mix and A.Mix.GroupsOf(data.SoundName, IsValid(src) and src or data.EntIndex, data.Channel, lvl) })
			if id then
				A.stats.nativeDirect = (A.stats.nativeDirect or 0) + 1
				if z then A.CopySync.Note(data.pbaEmKey, z, offset) end
				local play, ukey = playLength(data.SoundName, data.Pitch)
				local t0 = RealTime() + delay - (offset or 0) -- (where its file's second 0 falls)
				local h = { id = id, t0 = t0, tEnd = t0 + play, ukey = ukey, pitch = data.Pitch or 100, name = data.SoundName,
					orig = data.SoundName, srcChan = data.Channel or CHAN_AUTO }
				register(idx, h, data)
				-- followed while it plays: walking behind a wall must muffle it too
				if OS.Wanted(play) then
					OS.Add(data, src, S, L, r, { { h = h, v = { pos = S, vol = g, lp = 0, len = d } } }, play, ukey)
				end
				return true
			end
		end
		if A.IsSentence(data.SoundName) and not (A.Native and A.Native.render and (A.cfg.native_all or 0) >= 0.5 and A.Sentences.On() and not A.OwnDSP(data.DSP)) then
			A.Sentences.Note(data.SoundName, false, A.Sentences.WhyNot(data.DSP, true)) -- (a clear sentence the module was not asked for)
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
		local h = emitVoice(data, v, L, IsValid(src) and src or nil, copies, i, play, ukey, follow ~= nil, idx, waited)
		if h then
			emitted = emitted + 1
			A.active[#A.active + 1] = now + busy
			-- every voice must be drivable (a copy at a fixed position cannot move): else none is
			if follow then
				if h.id or h.a then follow[#follow + 1] = { h = h, v = v } else follow = nil end
			end
		end
	end
	-- a cheap result (r.cheap: pba_burst_budget_ms / pba_burst_mask_db / pba_far_force_ms, the walls' transmission
	-- alone) is a lower bound: the routes round the walls it ignores can only add. Too quiet to emit, it would have
	-- dropped a sound the full model plays (an 80 dB impact behind an open doorway: full -30.8 dB, cheap -60 dB,
	-- never heard): its dominant voice is kept at the quietest level emitted, and when followed, its full
	-- evaluation comes at the next tick and it glides there quickly (OS.Tick, rec.keptCheap)
	local kept = false
	if emitted == 0 and r.cheap and r.voices[1] then
		local v = r.voices[1]
		local h = emitVoice(data, v, L, IsValid(src) and src or nil, copies, 1, play, ukey, follow ~= nil, idx, waited, true)
		if h then
			emitted, kept = 1, true
			A.active[#A.active + 1] = now + busy
			A.stats.cheapKept = (A.stats.cheapKept or 0) + 1
			if follow then
				if h.id or h.a then follow[#follow + 1] = { h = h, v = v } else follow = nil end
			end
		end
	end
	if follow and #follow > 0 then
		local rec = OS.Add(data, src, S, L, r, follow, play, ukey)
		if rec and kept then rec.tNext, rec.keptCheap = now, true end
	end
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

	-- pba_gc_lean: the record below only feeds the report
	if A.cfg.report < 0.5 and (A.cfg.gc_lean or 0) >= 0.5 then return true end
	local rec = { t = now, S = S, L = L, r = r, name = data.SoundName, relayed = relayed, ms = (SysTime() - t0) * 1000 }
	if A.cfg.report >= 0.5 then
		local vs = {}
		for _, v in ipairs(r.voices) do
			vs[#vs + 1] = { kind = v.kind, pos = { v.pos.x, v.pos.y, v.pos.z }, level_db = math.Round(v.level, 1),
				az = math.Round(A.Azimuth(L, ang.y, v.pos), 1), lp = v.lp, dsp = v.dsp, vol = v.vol and math.Round(v.vol, 3) }
		end
		local ps = {}
		for _, p in ipairs(r.paths or {}) do
			ps[#ps + 1] = { length = math.Round(p.length), diff_db = math.Round(p.diffDb, 1),
				door_db = math.Round(p.doorDb, 1), level_db = math.Round(p.level or 0, 1),
				absorb_db = math.Round(p.absorbDb or 0, 1), diffuse = math.Round(p.diffuse or 0, 2), ratio = p.direct and math.Round(p.length / math.max(p.direct, 1), 2),
				bend = p.bendDeg and math.Round(p.bendDeg), az = math.Round(A.Azimuth(L, ang.y, p.pos), 1) }
		end
		A.Report("paths", { name = data.SoundName, relayed = relayed, voices = vs, paths = ps,
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

-- pba_impact_cap: a burst of one family of short world sounds (a chopper's gun: bullet impacts at 120 a second,
-- "physics/concrete/concrete_impact_bullet1..4.wav", each 1-2 s long) costs a path search, a native voice, a decode check
-- and a wait on the audio thread's lock EACH (7-25 ms frames, PERF bench S13). Past the cap the rest of the burst is
-- dropped (the hook returns false: the engine does not play it either): the ear hears one texture at that density.
-- Only sounds played on the world (impacts, ricochets: no entity, so no voice, no loop, no line is ever caught).
local CAP_WINDOW = 0.25
local capFamily = {}   -- sound name -> family key (the name without its number: a finite set, computed once)
local capCount = {}    -- family key -> { t0 = window start, n = taken in it }
local capKeys = 0
local function worldEmitter(data)
	local e = data.Entity
	if e == nil then return true end
	if not IsValid(e) then return (data.EntIndex or 0) <= 0 end
	return e:IsWorld()
end
--- True when this sound is past its family's cap for the current quarter second (and counts it as dropped).
-- Past pba_impact_group of them in the window it is marked dense (data.pbaDense): burstEvaluate gives it a nearby result.
function A.ImpactCapped(data)
	local cap, group = A.cfg.impact_cap or 16, A.cfg.impact_group or 4
	if (cap <= 0 and group <= 0) or not worldEmitter(data) then return false end
	local name = data.SoundName
	local fam = capFamily[name]
	if not fam then
		fam = string.gsub(string.lower(name), "%d+(%.%w+)$", "%1")
		capFamily[name] = fam
	end
	local now = RealTime()
	local c = capCount[fam]
	if not c then
		if capKeys > 512 then capCount, capKeys = {}, 0 end
		c = { t0 = now, n = 0 }
		capCount[fam] = c
		capKeys = capKeys + 1
	elseif now - c.t0 >= CAP_WINDOW then
		c.t0, c.n = now, 0
	end
	c.n = c.n + 1
	if group > 0 then
		data.pbaWorld = true -- (its full result feeds the ring of nearby results, burstEvaluate / Process)
		if c.n > group then data.pbaDense = true end
	end
	if cap <= 0 or c.n <= cap then return false end
	A.stats.capped = (A.stats.capped or 0) + 1
	return true
end

-- (fallback: a partial autorefresh may reload this file before sh_core)
A.AddHook("EntityEmitSound", (A.WithChannelRule or function(f) return f end)(function(data)
	if A.reemitting then
		-- pba's own engine emission (a copy, its vanilla fallback, a mirror's patch): the line is heard. Not a
		-- mouth copy (volume 0.001, mouthCopy: lip sync only, nobody hears it; it hid silent lines from the net)
		local v = data.Volume or 1
		if bit.band(data.Flags or 0, SND_STOP) == 0 and A.NoteRendered and v > 0.01 then A.NoteRendered(data.SoundName, v) end
		return
	end
	if bit.band(data.Flags or 0, SND_STOP) ~= 0 then
		-- a client-side StopSound: our copies of that sound stop too (the engine stops its own)
		local idx = sourceIndex(data)
		if idx then A.StopSource(idx, data.SoundName) end
		return
	end
	-- long client-side sounds (music of client-side radios): followed like a loop
	if A.Loops and A.Loops.HandleClient and A.Loops.HandleClient(data) then return false end
	if not A.Eligible(data) then return end
	if A.ImpactCapped(data) then return false end -- (pba_impact_cap: past the burst cap of its family)
	-- (a sound stamped away from now waits for its stamp, as the engine would make it: A.ClientSoundDelay)
	local stDelay = A.ClientSoundDelay(data)
	if stDelay > 0 then data.Delay = stDelay end
	local pos = A.SoundPos(data)
	if not pos then return end
	-- soundscape ambience around the ear: the engine's own (before the echoes)
	if A.IsSoundscapeRandom(data, pos) then return end
	-- echoes (native reflections) for loud sounds, whoever plays the direct sound
	local ply = LocalPlayer()
	-- (his own as the engine hears it: not through a camera, where his sounds are spatialised like anybody's)
	local own = IsValid(ply) and data.Entity == ply and A.HearsFromSelf(ply)
	-- (pba_native_own: the module plays it like any other sound, its source slot reflects it)
	local engineOwn = own and not (A.NativeOwn and A.NativeOwn())
	-- (a predicted sound carries the engine's position, his origin: centered on him instead, A.SoundPos)
	if own and not engineOwn then pos = A.SoundPos({ Entity = ply }) or pos end
	if A.Native and A.Native.render and A.Enabled() then A.Native.Echo(data, pos, engineOwn, own) end
	if engineOwn then
		if A.Mix then A.Mix.NoteSound({ SoundName = data.SoundName, Pos = pos, SoundLevel = data.SoundLevel, Volume = data.Volume,
			Channel = data.Channel, Entity = data.Entity }, (A.ListenerPos())) end -- the mixer's ducker (cl_mix)
		return -- own sounds: always clear (the engine plays them)
	end
	data.Pos = pos
	if A.Process(data, false) then return false end
	if A.FarMuffle(data, pos) then return true end
end))

-- Start times of relayed sounds (SoundTime, sv_relay writeSound). A weapon fires at its own tick: the
-- server runs several ticks between two network updates, so two shots 75 ms apart reach the client in
-- one packet. The engine keeps their spacing: it anchors a stamped server sound's time to its mixer
-- clock and delays each later one by how much its stamp is ahead of the clock since the anchor; a
-- delay below 0 or above 0.5 s re-anchors. The same rule here, on RealTime(), for the relayed copies.
local ST_MAX = 0.5
--- Delay (s) before relayed sound with stamp `ms` (ms modulo 65536) starts, at client time `now`.
local function stLead(ms, now)
	local s = A.stSync
	if s and now - s.now < 30 then
		local d = (ms - s.ms) % 65536
		if d >= 32768 then d = d - 65536 end
		local delay = d / 1000 - (now - s.now)
		if delay >= 0 and delay <= ST_MAX then return delay end
	end
end
function A.SoundTimeDelay(ms, now)
	local delay = stLead(ms, now)
	if delay then return delay end
	A.stSync = { ms = ms, now = now }
	return 0
end

--- The same delay for a stamp that is only READ (the sound it stamps is the engine's: the anchor stays): 0 when the
-- stamp is outside the window (the engine starts such a sound at once).
function A.SoundTimeLead(ms, now) return stLead(ms, now) or 0 end

-- relayed server sounds: always played by us (the server suppressed the original)
A.dict = A.dict or {}
local pendingAcks = {}
-- the server relays sounds to this player only once his pba client runs (sv_relay clientReady): told now
-- (this file loads after the player entity exists: on join, and again on a Lua refresh)
-- (with whether pba is off on this client, pba_cl_enable 0: the server then leaves his sounds to the engine)
local function sayReady()
	net.Start("pba_ready")
	net.WriteBool(not A.Enabled())
	net.SendToServer()
end
A.SayReady = sayReady
if IsValid(LocalPlayer()) then sayReady() end
A.OnInitPostEntity("pba_ready", sayReady)
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
		-- (id 0: the server's dictionary is full, the name always comes in full and is not kept)
		if id ~= 0 and A.dict[id] ~= name then
			A.dict[id] = name
			pendingAcks[#pendingAcks + 1] = id
		end
	else
		name = A.dict[id]
	end
	local data = A.ReadSound() -- (the common body, sh_core; Face: a line on a face, mouthCopy)
	data.SoundName = name
	if data.stMs then
		local d = A.SoundTimeDelay(data.stMs, RealTime())
		if d > 0 then data.Delay = d end
		data.stampMs = data.stMs -- (kept: a cut stamped later stops it at that start, A.NoteCut)
		data.stMs = nil
	end
	if not name then return end -- id never received (lost first packets): drop
	if A.LineKey then A.lineSeen[A.LineKey(name)] = RealTime() end -- (its caption's safety net, pba_caption_net)
	if A.Native and A.Native.render and A.Enabled() then
		local lp = LocalPlayer()
		A.Native.Echo(data, data.Pos, echoOnly, IsValid(lp) and data.EntIndex == lp:EntIndex() and A.HearsFromSelf(lp))
	end
	-- the engine already plays this one for us (clear line of sight): only the echoes were wanted
	if echoOnly then return end
	-- a sound of my own the server relayed all the same (a sentence: EmitSentence takes no
	-- filter, every listener gets the relay when one is blocked) is played by the engine on me, attached
	if (A.cfg.mp_own or 1) >= 0.5 then
		local lp = LocalPlayer()
		if IsValid(lp) and data.EntIndex == lp:EntIndex() and A.HearsFromSelf(lp) and not (A.NativeOwn and A.NativeOwn()) then vanilla(data) return end
	end
	-- my own sound the server relayed for my module (pba_native_own): centered on me, not where my eyes were
	-- on the server (A.SoundPos)
	do
		local lp = LocalPlayer()
		if IsValid(lp) and data.EntIndex == lp:EntIndex() and A.HearsFromSelf(lp) and A.NativeOwn and A.NativeOwn() then
			data.Entity = lp
			data.Pos = A.SoundPos({ Entity = lp })
		end
	end
	A.stats.relayedIn = A.stats.relayedIn + 1
	if A.Enabled() and A.Process(data, true) then
		-- a line on a face taken from the engine: heard within 0.2 s (+ its delays), else the engine plays it
		-- (pba_silent_handback)
		if A.WatchLine and (data.Face or data.Channel == CHAN_VOICE or data.Channel == CHAN_VOICE2) and not A.IsSentence(name) then
			local L = A.ListenerPos()
			local lag = (data.Delay or 0) + ((A.cfg.delay or 0) >= 0.5 and L and data.Pos and data.Pos:Distance(L) * 0.01905 / 343 or 0)
			if data.heldUntil then lag = math.max(lag, data.heldUntil - RealTime()) end -- (routes computed in slices)
			A.WatchLine(name, lag, "relayed line", function() vanilla(data) end, data.EntIndex, data.Channel)
		end
		return
	end
	-- not processed (disabled client, clear path...): play it as the engine would have
	if data.Delay then timer.Simple(data.Delay, function() vanilla(data) end) else vanilla(data) end
end)

-- caption of a suppressed server sound (sv_relay sendCaption); nothing shown with closecaption 0
-- One caption per line (pba_caption_once): one line reaching the player as several sounds (a microphone's
-- line through two monitors: d1_trainstation_05's two eli_mic, one copy left to the engine, which captions
-- it, the other relayed) was captioned once per copy, where the engine shows it once. A caption whose text
-- was shown less than CAPTION_ONCE_S ago is dropped: pba's when any caption showed it, the engine's when pba
-- showed it (GM:OnCloseCaptionEmit sees both, ours as gui.AddCaption text).
local CAPTION_ONCE_S = 1
A.capShown = A.capShown or {} -- caption text without tags -> { t = CurTime(), ours = true|nil }
local function captionKey(text) return string.Trim((string.gsub(text or "", "<[^>]*>", ""))) end
local function captionRecent(key)
	local c = A.capShown[key]
	return c and A.SoundNow() - c.t < CAPTION_ONCE_S and c or nil
end
hook.Add("OnCloseCaptionEmit", "pba_caption_once", function(tok, dur, fromPlayer, text)
	if (A.cfg.caption_once or 1) < 0.5 or A.addingCaption then return end
	local key = captionKey(text or tok)
	if key == "" then return end
	local c = captionRecent(key)
	if c and c.ours then return true end -- the engine's copy of a line pba captioned already
	A.capShown[key] = { t = A.SoundNow() }
end)
-- Caption-armed safety net (pba_caption_net): a relayed line's caption (reliable) came, but no relay of its
-- file (pba_snd, unreliable: lost in a full snapshot, a teleport's) within CAPTION_NET_S: subtitle without a
-- voice nor a mouth (bug 59, d1_trainstation_05 Breen). The line is then played by the engine on its speaker,
-- with the level, pitch, volume and channel the caption carries (the mouth moves with it).
local CAPTION_NET_S = 0.3
A.lineSeen = A.lineSeen or {} -- line key -> RealTime() of the last relay of that file
local function captionNet(file, idx, chan, lvl, pitch, vol, spos)
	if (A.cfg.caption_net or 1) < 0.5 or file == "" or not A.LineKey or A.IsSentence(file) then return end
	local key, t = A.LineKey(file), RealTime()
	timer.Simple(A.RealDelay(CAPTION_NET_S), function()
		local seen = A.lineSeen[key]
		if seen and seen >= t - 1 then return end -- its relay came (before or after the caption)
		-- a speaker out of this client's PVS (a closed areaportal, just teleported) has no entity here: the engine
		-- keeps the channel under its index all the same (as for vanilla's own), at the position sent
		local e = Entity(idx)
		local pos = IsValid(e) and e:GetPos() or spos
		A.stats.captionNet = (A.stats.captionNet or 0) + 1
		MsgN("[PBA] line without its sound: played by the engine (", file, ")")
		vanilla({ SoundName = file, Entity = e, EntIndex = idx, Channel = chan, SoundLevel = lvl, Pitch = pitch, Volume = vol,
			Flags = 0, DSP = 0, Pos = pos })
	end)
end
A.CaptionNet = captionNet
net.Receive("pba_caption", function()
	local tok, dur = net.ReadString(), net.ReadFloat()
	local file = net.ReadString()
	-- (a relayed line: the safety net's data, pba_caption_net; a server without it sends none)
	if net.ReadBool() then
		local idx, chan = net.ReadUInt(16), net.ReadInt(16)
		local lvl, pitch, vol = net.ReadUInt(9), net.ReadUInt(8), net.ReadFloat()
		captionNet(file, idx, chan, lvl, pitch, vol, net.ReadVector())
	end
	local txt = language.GetPhrase(tok)
	if not txt or txt == tok then return end
	-- a spoken line (not an <sfx> caption): watched by the silent line safety net (pba_handback_speech)
	if file ~= "" and A.LineKey and not string.find(string.lower(txt), "<sfx>", 1, true) then A.speechT[A.LineKey(file)] = RealTime() end
	if (A.cfg.caption_once or 1) >= 0.5 then
		local key = captionKey(txt)
		if captionRecent(key) then return end
		A.capShown[key] = { t = A.SoundNow(), ours = true }
	end
	A.addingCaption = true
	gui.AddCaption(txt, dur > 0 and dur or 2, false)
	A.addingCaption = false
end)

-- client-side StopSound (predicted weapons...): our copies of that entity's sound stop too
do
	local ENT = FindMetaTable("Entity")
	A.origCl = A.origCl or { StopSound = ENT.StopSound }
	function ENT:StopSound(name)
		A.origCl.StopSound(self, name)
		local idx = self:EntIndex()
		if idx > 0 and A.StopSource then pcall(A.StopSource, idx, name or "") end
	end
end

--- THE stop path of the client: the engine stopped `name` (every name when ""/nil) of entity idx on channel
-- chan (any when nil / CHAN_AUTO): a client StopSound, the server's StopSound or scene cancel (pba_snd_stop),
-- an EmitSound with SND_STOP. Every copy of it stops (anchors, native voices, fixed-position copies, mouth
-- copies, followed one-shots through their copies) and every client-side long sound mirror.
function A.StopSource(idx, name, chan)
	if A.WatchCut then A.WatchCut(idx, chan, name) end
	A.StopCopies(idx, name or "", chan)
	if A.Loops and A.Loops.StopClient then
		A.Loops.StopClient(idx, chan ~= CHAN_AUTO and chan or nil, name ~= "" and name or nil)
	end
end

--- stopsound / snd_restart: the engine stops every channel; pba's copies, mirrors and native voices
-- stop with them, and so does the following of every one-shot (pba_stop_followers: a copy of a source
-- without an entity is in no registry, its follower kept sending volume changes to a stopped sound).
function A.StopAllSounds()
	for idx in pairs(A.emitted) do A.StopCopies(idx, "") end
	for _, fv in pairs(OS.native) do fv.dead = true end
	table.Empty(OS.native)
	if (A.cfg.stop_followers or 1) >= 0.5 then
		for _, rec in pairs(OS.recs) do
			for _, fv in ipairs(rec.voices) do fv.dead = true end
		end
	end
	if A.Loops and A.Loops.StopAll then A.Loops.StopAll() end
	if A.Native and A.Native.StopAllVoices then A.Native.StopAllVoices() end
	A.stats.stopAll = (A.stats.stopAll or 0) + 1
end

-- seen from Lua: RunConsoleCommand / Player:ConCommand on the client (also what SendLua and
-- BroadcastLua run), and Player:ConCommand on the server (pba_stopall). Typed in the console or bound
-- to a key, the command never reaches Lua.
do
	local PLY = FindMetaTable("Player")
	A.origCmd = A.origCmd or {}
	if not A.origCmd.run and debug.getinfo(RunConsoleCommand, "S").what == "C" then A.origCmd.run = RunConsoleCommand end
	if not A.origCmd.ply and debug.getinfo(PLY.ConCommand, "S").what == "C" then A.origCmd.ply = PLY.ConCommand end
	if A.origCmd.run then
		-- every other command is a tail call: its errors (a command blocked in multiplayer, a bad argument)
		-- are the caller's, as without pba (they blamed cl_render.lua and a function 'run')
		function RunConsoleCommand(cmd, ...)
			if not A.StopsAllSounds(cmd) then return A.origCmd.run(cmd, ...) end
			A.origCmd.run(cmd, ...)
			A.StopAllSounds()
		end
	end
	if A.origCmd.ply then
		function PLY:ConCommand(cmd, ...)
			if not A.StopsAllSounds(cmd) then return A.origCmd.ply(self, cmd, ...) end
			A.origCmd.ply(self, cmd, ...)
			A.StopAllSounds()
		end
	end
end
net.Receive("pba_stopall", function() A.StopAllSounds() end)

-- Typed in the console or bound to a key, stopsound (and snd_restart) never reaches Lua. Measured
-- (2026-11-13): a client sound patch (CreateSound) reads IsPlaying() false right after the engine
-- stopped every sound, and true otherwise, even long after its file ended (StopSound on its entity, 80
-- sounds at once: unchanged). A patch on a silent file is the sentinel, checked every 0.1 s and played
-- again after each stop-all.
do
	local watch = A.stopWatch or { nextT = 0 }
	A.stopWatch = watch
	hook.Add("Think", "pba_stopsound_watch", function()
		local now = RealTime()
		-- (a clock that went back, e.g. RealTime stubbed by a test while Think ran: nextT far ahead would
		-- stall the watch for as long)
		if now < watch.nextT and watch.nextT - now <= 0.1 then return end
		watch.nextT = now + 0.1
		local p = watch.patch
		if (A.cfg.stopsound_watch or 1) < 0.5 then
			if p then p:Stop() watch.patch = nil end
			return
		end
		if not p then
			-- (pba's own patch: the original CreateSound, never tracked as a client loop)
			p = (A.Loops and A.Loops.origCreateSound or CreateSound)(game.GetWorld(), "common/null.wav")
			if not p then return end
			p:PlayEx(0, 100)
			watch.patch = p
		elseif not p:IsPlaying() then
			A.StopAllSounds()
			p:PlayEx(0, 100)
		end
	end)
end

-- server-side StopSound on a relayed sound, or a new sound on its channel the engine played without
-- us (sv_relay relayChannelCut): stop our copies
net.Receive("pba_snd_stop", function()
	local idx, chan = net.ReadUInt(16), net.ReadInt(10)
	local n = net.ReadUInt(8)
	local names = {}
	for i = 1, n do names[i] = net.ReadString() end
	-- (the channel rule's cut carries the start time of the sound that replaces: the old copies play on until then,
	-- pba_cut_at_start; a server without the field reads false)
	local stMs = net.ReadBool() and net.ReadUInt(16) or nil
	if n == 0 then
		if stMs and chan ~= CHAN_AUTO and (A.cfg.cut_at_start or 1) >= 0.5 then
			A.CutChannel(idx, chan, nil, A.SoundTimeLead(stMs, RealTime()))
			A.NoteCut(idx, chan, stMs) -- (the relayed copies read after it in the same packet)
		else
			A.StopSource(idx, "", chan)
		end
		return
	end
	for i = 1, n do A.StopSource(idx, names[i], chan) end
end)

-- entity removed: its copies play on to their end where they were, as the engine's own sounds do
-- (sv_relay "pba_relay_removed"). They stay registered under the index: a new entity taking it over
-- replaces them on their channel, as the engine's channels (keyed by the index) would.
