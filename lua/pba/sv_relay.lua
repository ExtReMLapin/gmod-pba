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
util.AddNetworkString("pba_ready")

-- A player whose pba client runs says so (cl_render, "pba_ready"). One who has not (still joining, or
-- pba's client Lua broken on his side) would lose every relayed sound: nothing would play it. He is
-- treated as a player too far for a path search (the engine plays the original for him, muffled by one
-- trace behind a wall). pba_relay_ready 0: every player gets relays (before).
-- With it, whether he switched pba off on his side (pba_cl_enable 0): he then hears the engine's own
-- sounds, nothing relayed nor muffled for him (pba_relay_cl_enable). (An older client sends no flag: on.)
net.Receive("pba_ready", function(_, ply)
	local st = A.PState(ply)
	st.ready = true
	st.off = net.BytesLeft() and net.BytesLeft() > 0 and net.ReadBool() or false
end)
function A.ClientReady(ply) -- (the audience rule, sv_sound)
	return A.PState(ply).ready == true or (A.cfg.relay_ready or 1) < 0.5
end
function A.ClientOff(ply) -- (the audience rule, sv_sound)
	return A.PState(ply).off == true and (A.cfg.relay_cl_enable or 1) >= 0.5
end

-- (pba_early_line_takeover) Lines a joining player hears before his client can render them. On a map load the
-- scenes start before his pba client runs (d1_trainstation_05: Alyx's first line 1.25 s after PlayerInitialSpawn,
-- his pba Lua loaded 0.04 s after it, native rendering 0.5 s later still): such a line is left to the engine for
-- him (not ready: treated as a far player; ready but his module not on yet: a clear line is the engine's), and his
-- client never knew of it, so the engine played the whole line, dry, through the walls. Each player has an early
-- window, open from the start of this Lua state until his client says its rendering is settled (net "pba_early":
-- native rendering on and its wishes sent, or no module); the spoken lines left to the engine for him meanwhile are
-- kept (A.NoteEarly), then sent to him with how long they have played: his client hands each one still far enough
-- from its end to the module, from that point, and mutes the engine copy (cl_loops LP.TakeEarly).
util.AddNetworkString("pba_early")
local EARLY_MAX = 16      -- lines kept per player (the oldest dropped)
local EARLY_MIN_S = 1     -- a shorter line is not worth a second voice (the margin of the hand-over is 0.75 s)
local EARLY_OPEN_S = 60   -- a client that never asks (an older pba) closes its window after this long
--- True while ply's early window is open (pba_early_line_takeover).
function A.EarlyOpen(ply)
	if (A.cfg.early_line_takeover or 1) < 0.5 then return false end
	local st = A.PState(ply)
	if st.earlyDone then return false end
	local now = RealTime()
	st.earlyT0 = st.earlyT0 or now
	if now - st.earlyT0 > EARLY_OPEN_S then st.earlyDone, st.early = true, nil return false end
	return true
end
--- Seconds the spoken line `data` plays, when it is one an early window keeps: a voice channel or a speaker's copy,
-- on an entity (not a player's own, not a sentence), a new sound, at least EARLY_MIN_S long. nil otherwise.
function A.EarlyLine(data)
	local flags = data.Flags or 0
	if bit.band(flags, SND_STOP + SND_CHANGE_VOL + SND_CHANGE_PITCH) ~= 0 then return nil end
	local ch = data.Channel
	if not (ch == CHAN_VOICE or ch == CHAN_VOICE2 or bit.band(flags, SND_SPEAKER or 64) ~= 0) then return nil end
	local e = data.Entity
	if not IsValid(e) or e:IsWorld() or e:IsPlayer() or not isstring(data.SoundName) or A.IsSentence(data.SoundName) then return nil end
	local secs = A.PlaySeconds(data.SoundName, data.Pitch)
	if not secs or secs < EARLY_MIN_S then return nil end
	return secs
end
--- Keeps line `data` (secs: A.EarlyLine) for player ply, whose engine plays it at volume `ev`. blocked: he got it
-- because he is not ready (else: a clear line his module may want, pba_native_all).
function A.NoteEarly(data, secs, ply, ev, blocked)
	local st = A.PState(ply)
	local now = RealTime()
	local list = st.early or {}
	st.early = list
	for i = #list, 1, -1 do if list[i].t + list[i].secs < now then table.remove(list, i) end end
	if #list >= EARLY_MAX then table.remove(list, 1) end
	local e = data.Entity
	list[#list + 1] = { name = data.SoundName, idx = e:EntIndex(), chan = data.Channel, lvl = data.SoundLevel or 75,
		pitch = data.Pitch or 100, vol = data.Volume or 1, ev = ev, flags = data.Flags or 0, dsp = data.DSP or 0,
		pos = A.SoundPos(data) or e:WorldSpaceCenter(), face = A.OnFace(e, data.Channel) or false, t = now, secs = secs, tick = engine.TickCount(),
		blocked = blocked and true or false }
	A.stats.earlyNoted = (A.stats.earlyNoted or 0) + 1
end
--- (pba_early_purge) The kept lines the engine no longer plays: entity idx's `name` (every name when nil / "") on chan
-- (any when nil) stopped, or replaced on its channel. keep: the replacing sound (its own entry, noted in this tick,
-- stays). A line left in the list after its stop was handed to the player's module once he was ready (a ghost line;
-- replaced on its channel: two lines over each other).
function A.PurgeEarly(idx, name, chan, keep)
	if (A.cfg.early_purge or 1) < 0.5 or idx <= 0 then return end
	local files = name and name ~= "" and A.StopFiles(name) or nil
	local tick = engine.TickCount()
	for _, p in ipairs(player.GetHumans()) do
		local list = A.PState(p).early
		if list then
			for i = #list, 1, -1 do
				local x = list[i]
				if x.idx == idx and (not chan or x.chan == chan) and (not files or A.StopReaches(files, x.name))
					and not (keep and x.name == keep.SoundName and x.tick == tick) then
					table.remove(list, i)
				end
			end
		end
	end
end
-- his client's rendering is settled: the lines kept for him (still playing), how long each has played; the window shuts
net.Receive("pba_early", function(_, ply)
	local st = A.PState(ply)
	local list = st.early
	st.earlyDone, st.early = true, nil
	if not list or (A.cfg.early_line_takeover or 1) < 0.5 then return end
	local now, out = RealTime(), {}
	for _, x in ipairs(list) do if x.t + x.secs > now then out[#out + 1] = x end end
	if #out == 0 then return end
	net.Start("pba_early")
	net.WriteUInt(#out, 5)
	local ct = CurTime()
	for _, x in ipairs(out) do
		net.WriteString(x.name)
		A.WriteSound({ pos = x.pos, lvl = x.lvl, pitch = x.pitch, vol = x.vol, chan = x.chan, flags = x.flags, dsp = x.dsp,
			idx = x.idx, face = x.face })
		net.WriteFloat(now - x.t)
		net.WriteFloat(x.ev)
		net.WriteBool(x.blocked)
		-- his copy from now on: the stops of its entity and the channel rule reach him (A.RelayStop, A.CutChannel)
		local e = Entity(x.idx)
		if IsValid(e) then
			local r = A.recentTo[x.idx] or {}
			A.recentTo[x.idx] = r
			r[ply] = ct
			A.HoldCopies({ Entity = e, Channel = x.chan }, { ply })
		end
	end
	net.Send(ply)
	A.stats.earlySent = (A.stats.earlySent or 0) + #out
end)

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
-- relayed: those players get the line by the relay (pba_snd, unreliable): their client plays it itself when no
-- sound of that file reached it (pba_caption_net), from what follows the file: the speaker's index, channel,
-- level, pitch, volume and position.
local function sendCaption(data, plys, relayed)
	local tok = data.OriginalSoundName
	if #plys == 0 or not tok or tok == "" or tok == data.SoundName or not sound.GetProperties(tok) then return end
	net.Start("pba_caption")
	net.WriteString(tok)
	net.WriteFloat(A.SoundDuration(data.SoundName) or 0)
	net.WriteString(data.SoundName or "") -- (its file: the client's speech lines, pba_handback_speech)
	local e = data.Entity
	net.WriteBool(relayed == true)
	net.WriteUInt(IsValid(e) and not e:IsWorld() and e:EntIndex() or 0, 16)
	net.WriteInt(data.Channel or CHAN_AUTO, 16)
	net.WriteUInt(math.Clamp(data.SoundLevel or 75, 0, 511), 9)
	net.WriteUInt(math.Clamp(data.Pitch or 100, 0, 255), 8)
	net.WriteFloat(data.Volume or 1)
	net.WriteVector(A.SoundPos(data) or vector_origin) -- (a speaker out of the client's PVS: no entity there)
	net.Send(plys)
end
A.SendCaption = sendCaption -- (sv_sound for relayed sounds; the long lines sv_loops takes over: pba_long_captions)

-- who received relayed copies of an entity's sounds recently: they must hear its StopSound too
A.recentTo = A.recentTo or {} -- entindex -> { [ply] = time }

-- Sound-name dictionary: a name travels in full until the client acknowledges its id,
-- then as a 16-bit id (~20-byte messages instead of ~50). Ids 1..65535; once they are all given (a
-- long-running server), a new name gets id 0: sent in full every time, never stored by the client (an id
-- past 65535 wrapped on the wire onto an old one, and the client then played the new sound for the old).
A.dict = A.dict or { ids = {}, names = {}, n = 0 }
local MAX_ID = 65535

--- The ids player ply acknowledged for this dictionary (both die with this Lua state: A.PState).
function A.RelayKnown(ply)
	local st = A.PState(ply)
	st.known = st.known or {}
	return st.known
end
local function nameId(name)
	local id = A.dict.ids[name]
	if not id then
		if A.dict.n >= MAX_ID then return 0 end
		A.dict.n = A.dict.n + 1
		id = A.dict.n
		A.dict.ids[name], A.dict.names[id] = id, name
	end
	return id
end

net.Receive(NET_ACK, function(_, ply)
	local known = A.RelayKnown(ply)
	for _ = 1, math.min(net.ReadUInt(8), 64) do
		local id = net.ReadUInt(16)
		if id > 0 then known[id] = true end
	end
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

--- THE stop path of the server: the engine stopped `name` (every name when ""/nil) of entity e on channel chan
-- (any when nil): its relayed copies stop on the clients that got them (pba_snd_stop: copies, native voices,
-- mouth copies, client mirrors; cl_render A.StopSource), and so do the long sounds and loops sv_loops
-- follows (their mirrors, their mouth copy).
function A.StopSource(e, name, chan)
	if A.RelayStop then pcall(A.RelayStop, e, name, chan) end
	if A.Loops and A.Loops.Stop and IsValid(e) and not e:IsWorld() then pcall(A.Loops.Stop, e:EntIndex(), name, chan) end
end

-- StopSound never reaches EntityEmitSound: relay it to the players who got copies (transparent)
function ENT:StopSound(name)
	A.orig.EntStopSound(self, name)
	A.StopSource(self, name)
end

--- The engine's audible radius of a sound level: it sends to players within 100*(lvl-50) units (500 if lvl
-- <= 50). One rule for the relayed sounds and the mirrors (sv_sound, sv_loops).
function A.AudibleRadius(lvl)
	return lvl > 50 and 100 * (lvl - 50) or 500
end

local function writeSound(data, pos, id, full, echoOnly)
	net.WriteUInt(id, 16)
	net.WriteBool(full)
	net.WriteBool(echoOnly or false)
	if full then net.WriteString(data.SoundName) end
	-- the common body (sh_core A.WriteSound, as pba_loop's)
	local e = data.Entity
	A.WriteSound({ pos = pos, lvl = data.SoundLevel, pitch = data.Pitch, vol = data.Volume, chan = data.Channel,
		flags = data.Flags, dsp = data.DSP, idx = IsValid(e) and e:EntIndex() or 0, st = data.SoundTime,
		face = A.OnFace(e, data.Channel) })
end

A.stats = A.stats or { seen = 0, relayed = 0, untouched = 0 }

--- Sends sound `data` at `pos` to `plys` (pba_snd, unreliable: a lost sound is better than a late one), its
-- name in full until every one of them knows its id. echoOnly: the client plays only the module's echo tail.
function A.RelaySend(data, pos, plys, echoOnly)
	local id = nameId(data.SoundName)
	local full = false
	for _, ply in ipairs(plys) do
		if id == 0 or not A.RelayKnown(ply)[id] then full = true break end
	end
	net.Start(NET, true)
	writeSound(data, pos, id, full, echoOnly)
	local k = echoOnly and "echoBytes" or "bytes"
	A.stats[k] = (A.stats[k] or 0) + net.BytesWritten() * #plys
	net.Send(plys)
end

--- One explicit stop (pba_snd_stop) of entity idx's `name` on chan to plys; unreliable: in order with the relays.
local function sendStop(idx, name, chan, plys, unreliable)
	net.Start("pba_snd_stop", unreliable)
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
	net.WriteBool(false) -- (no replacing sound: an explicit stop, at once)
	net.Send(plys)
end

-- (pba_stop_both) A copy relayed a few ticks before its stop can ride in the same packet as the stop: a client at a low
-- frame rate or cl_updaterate reads several ticks per packet, and reads a packet's reliable messages before its unreliable
-- ones, so a reliable stop found nothing yet and the copy played to its end (two ticks apart on d3_citadel_01's pods: two
-- module voices). To a player relayed a copy of the entity in the last STOP_BOTH_S seconds the stop goes on both streams:
-- the reliable one cannot be lost, the unreliable one is read behind the copy (and if that packet is lost, so is the copy
-- it carried). A second stop of a stopped sound does nothing. Same for the channel rule's cut (A.CutChannel).
local STOP_BOTH_S = 1

--- The engine stopped `name` on entity e (chan: only that channel's copies; nil, any): clients that got
-- relayed copies stop theirs. except: players left out (set).
-- A player relayed a copy of that entity in this very tick gets the stop on the unreliable stream, behind that
-- copy (pba_stop_order): the client reads a packet's reliable messages before its unreliable ones, so a reliable stop
-- would find nothing yet (a non-looped ambient_generic fired twice in one tick: stop, play, stop, play; both plays kept).
function A.RelayStop(e, name, chan, except)
	local idx = IsValid(e) and not e:IsWorld() and e:EntIndex() or 0
	A.PurgeEarly(idx, name, chan)
	local r = idx > 0 and A.recentTo[idx]
	if not r then return end
	local plys, now = {}, CurTime()
	local inOrder = (A.cfg.stop_order or 1) >= 0.5
	local both = (A.cfg.stop_both or 1) >= 0.5
	local behind -- (the players relayed a copy of e in this tick)
	local recent -- (pba_stop_both: those relayed one in the last STOP_BOTH_S: the stop goes on both streams)
	for p, t in pairs(r) do
		if IsValid(p) and now - t < 30 then
			if not (except and except[p]) then
				if inOrder and t == now then
					behind = behind or {}
					behind[#behind + 1] = p
				else
					plys[#plys + 1] = p
					if both and now - t <= STOP_BOTH_S then
						recent = recent or {}
						recent[#recent + 1] = p
					end
				end
			end
		else
			r[p] = nil
		end
	end
	if behind then sendStop(idx, name, chan, behind, true) end
	if #plys == 0 then return end
	sendStop(idx, name, chan, plys, false)
	if recent then sendStop(idx, name, chan, recent, true) end
end

-- Players holding relayed copies per entity and replacing channel (A.recentChan): the channel rule reaches
-- them only (an NPC firing CHAN_WEAPON at a player in plain sight sends nothing per shot).
A.recentChan = A.recentChan or {} -- entindex -> { [chan] = { [ply] = time relayed } }
A.relayedTo = nil -- the players the sound being handled was relayed to (sv_sound Dispatch)

function A.HoldCopies(data, plys)
	local e, chan = data.Entity, data.Channel
	if not plys or #plys == 0 or not A.ReplacingChannel(chan) or not IsValid(e) or e:IsWorld() then return end
	local idx = e:EntIndex()
	local rc = A.recentChan[idx]
	if not rc then rc = {} A.recentChan[idx] = rc end
	local held = rc[chan]
	if not held then held = {} rc[chan] = held end
	local now = CurTime()
	for _, p in ipairs(plys) do held[p] = now end
end

--- The channel rule on the server (sh_core A.CutsChannel, called by A.WithChannelRule once the hook handled
-- the new sound; the engine sounds are cut there): the long sounds and loops sv_loops follows on that
-- channel stop (a capped one is over), and so do the copies relayed earlier to players this sound was not
-- relayed to (audit A-P1-1, D7: left untouched, re-emitted clear or muffled, taken by sv_loops or refused,
-- the new sound never reaches their client, and an NPC's line through a wall played on over its death
-- cry). The players it is relayed to cut theirs themselves (cl_render A.CutChannel), in order with the new copy.
-- The cut carries the new sound's own start time (SoundTime, as a relay's body does): the engine stops the old sound
-- when the new one STARTS, and the packets of a burst (a hitch, a late packet) reach the client with several shots
-- still waiting for their own stamp, which a stop on arrival cut before they began (pba_cut_at_start, cl_render).
function A.CutChannel(data, idx, chan)
	if A.Loops and A.Loops.CutChannel then A.Loops.CutChannel(idx, chan, data.SoundName) end
	A.PurgeEarly(idx, nil, chan, data)
	local rc = A.recentChan[idx]
	local held = rc and rc[chan]
	if not held then return end
	local keep = {}
	for _, p in ipairs(A.relayedTo or {}) do keep[p] = true end
	local plys, now = {}, CurTime()
	local both = (A.cfg.stop_both or 1) >= 0.5
	local recent -- (pba_stop_both: the cut on both streams)
	for p, t in pairs(held) do
		if not keep[p] then
			held[p] = nil
			-- (a copy is never longer than max_duration; 30 s as for recentTo)
			if IsValid(p) and now - t < 30 then
				plys[#plys + 1] = p
				if both and now - t <= STOP_BOTH_S then
					recent = recent or {}
					recent[#recent + 1] = p
				end
			end
		end
	end
	if next(held) == nil then rc[chan] = nil end
	if #plys == 0 then return end
	local st = (A.cfg.soundtime or 1) >= 0.5 and data.SoundTime or 0
	local function cut(to, unreliable)
		net.Start("pba_snd_stop", unreliable)
		net.WriteUInt(idx, 16)
		net.WriteInt(chan, 10)
		net.WriteUInt(0, 8) -- every name
		net.WriteBool(st ~= 0)
		if st ~= 0 then net.WriteUInt(math.floor(st * 1000 + 0.5) % 65536, 16) end
		net.Send(to)
	end
	cut(plys, false)
	if recent then cut(recent, true) end
	A.stats.chanCuts = (A.stats.chanCuts or 0) + 1
end


-- Brief sounds started on an entity: entindex -> { [file] = { t = time the sound ends, took = pba took it
-- over (relayed, re-emitted) } }. A later SND_CHANGE_VOL / PITCH for one of them (non-looped
-- ambient_generic with a preset or Pitch / Volume inputs, func_rotating / func_tracktrain with a non-looped
-- move sound) is not a new sound (audit B-8, pba_brief_updates). Taken over: dropped (the engine would start
-- a vanilla copy midway at the players who got pba's, no channel matching; sv_loops a second copy from the
-- top). Left to the engine: the change is the engine's too (sv_loops must not take it as a patch start).
A.recentBrief = A.recentBrief or {}
local function briefKey(name) return string.lower(A.SoundFile(name or "")) end
function A.NoteBrief(data, took)
	if bit.band(data.Flags or 0, SND_STOP) ~= 0 then return end
	-- (a change flag: only a new sound taken as new, A.NewChange; a real change of a playing one is not a start)
	if bit.band(data.Flags or 0, SND_CHANGE_VOL + SND_CHANGE_PITCH) ~= 0 and not (took and A.newChangeData == data) then return end
	local e = data.Entity
	if not IsValid(e) or e:IsWorld() or not isstring(data.SoundName) then return end
	local now = A.SoundNow()
	local tEnd = A.PlayEnd(data.SoundName, data.Pitch, now, 0.1) -- (the end-of-file rule, sh_core)
	if not tEnd then return end
	local idx = e:EntIndex()
	local r = A.recentBrief[idx]
	if not r then r = {} A.recentBrief[idx] = r end
	for k, x in pairs(r) do if x.t < now then r[k] = nil end end
	r[briefKey(data.SoundName)] = { t = tEnd, took = took and true or false }
	if A.Loops and A.Loops.NoteBriefMover then A.Loops.NoteBriefMover(data, took) end
end
--- True when data is a volume / pitch change of a brief sound that still plays; second value: pba took it
-- over (else the engine plays it).
function A.BriefPlaying(data)
	if (A.cfg.brief_updates or 1) < 0.5 then return false end
	if bit.band(data.Flags or 0, SND_CHANGE_VOL + SND_CHANGE_PITCH) == 0 or bit.band(data.Flags or 0, SND_STOP) ~= 0 then return false end
	local e = data.Entity
	local r = IsValid(e) and A.recentBrief[e:EntIndex()]
	local x = r and r[briefKey(data.SoundName)]
	if not x or x.t < A.SoundNow() then return false end
	return true, x.took
end

--- True when `data`, a volume / pitch change, is in fact the START of a sound: nothing of that name plays on its
-- entity (no followed one, no capped one, no brief one still playing). The engine starts such a sound (a scene
-- line with a pitch other than 1; EmitSound(..., SND_CHANGE_PITCH) on a new sound): pba_change_new takes it as
-- any new sound (A.Eligible). A real change of a playing sound stays as it was (b5139cb): the engine's, or dropped.
function A.NewChange(data)
	if (A.cfg.change_new or 1) < 0.5 then return false end
	local flags = data.Flags or 0
	if bit.band(flags, SND_CHANGE_VOL + SND_CHANGE_PITCH) == 0 or bit.band(flags, SND_STOP) ~= 0 then return false end
	local e = data.Entity
	if not IsValid(e) or e:IsPlayer() or not isstring(data.SoundName) then return false end
	local LP = A.Loops
	if LP then
		local idx = e:EntIndex()
		if LP.capped[idx .. ":" .. (data.Channel or 0) .. ":" .. data.SoundName] or LP.Following(idx, data.SoundName) then return false end
	end
	local r = A.recentBrief[e:EntIndex()]
	local x = r and r[briefKey(data.SoundName)]
	if x and x.t >= A.SoundNow() then return false end
	A.newChangeData = data
	return true
end

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
	A.StopSource(actor, "", CHAN_VOICE)
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
	-- (its brief sounds too: a new entity taking the index must not see its first change of one of those names dropped)
	if idx > 0 then A.recentTo[idx] = nil A.recentChan[idx] = nil A.recentBrief[idx] = nil end
end)
