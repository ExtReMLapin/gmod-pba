-- Client side: computes the paths from a sound to the local listener and re-emits one
-- voice per selected path at its apparent position, with compensated volume and DSP.
-- Handles both client-born sounds (EntityEmitSound on the client) and sounds relayed by
-- the server (net "audioprop_snd").

local A = audioprop
local AC = A.AC
local NET = "audioprop_snd"

A.active = A.active or {}      -- list of { t_end, gain } for the voice budget
A.lastResults = A.lastResults or {}
A.perf = A.perf or { sum = 0, n = 0, maxCall = 0, maxFrame = 0, frames = 0, cur = 0 }
function A.ResetPerf() A.perf = { sum = 0, n = 0, maxCall = 0, maxFrame = 0, frames = 0, cur = 0 } end
A.stats = A.stats or { processed = 0, vanilla = 0, voices = 0, relayedIn = 0, dropped = 0 }

local function listenerPos()
	local ply = LocalPlayer()
	if not IsValid(ply) then return nil end
	return ply:EyePos(), ply:EyeAngles()
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

--- Propagation delay of a voice (audioprop_delay), seconds.
local function voiceDelay(v, L)
	if (A.cfg.delay or 0) < 0.5 then return 0 end
	return (v.len or v.pos:Distance(L)) / SPEED
end

local function emitVoice(data, v, L, src)
	-- native rendering: the module plays the voice itself (HRTF + EQ); no engine compensation
	if A.Native and A.Native.render then
		local g = (data.Volume or 1) * v.gain * A.Native.Directivity(src, L)
		if g < 0.001 then return false end
		if A.Native.PlayVoice(data.SoundName, v.pos, g, v.lp, data.Pitch, { len = v.len, sh = v.sh, delay = voiceDelay(v, L) }) then
			v.vol, v.dsp, v.native = g, -1, true
			return true
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
	if delay >= 0.02 then
		local name, pos, pitch = data.SoundName, v.pos, data.Pitch or 100
		timer.Simple(delay, function() A.Emit(EmitSound, name, pos, -1, CHAN_AUTO, vol, lvl, flags, pitch, dsp) end)
	else
		A.Emit(EmitSound, data.SoundName, v.pos, -1, CHAN_AUTO, vol, lvl, flags, data.Pitch or 100, dsp)
	end
	v.vol, v.dsp = vol, dsp
	return true
end

--- Processes one sound. Returns true when audioprop took charge of it (the original must
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
	if r.clear or not r.voices or #r.voices == 0 then
		A.stats.vanilla = A.stats.vanilla + 1
		return false
	end
	local now = RealTime()
	local dur = math.max(SoundDuration(data.SoundName) or 0.5, 0.1)
	local budget = A.cfg.max_active - activeCount(now)
	local emitted = 0
	for i, v in ipairs(r.voices) do
		if i > 1 and emitted >= budget then A.stats.dropped = A.stats.dropped + 1 break end
		if emitVoice(data, v, L, IsValid(src) and src or nil) then
			emitted = emitted + 1
			A.active[#A.active + 1] = now + dur
		end
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

	local rec = { t = now, S = S, L = L, r = r, name = data.SoundName, relayed = relayed, ms = (SysTime() - t0) * 1000 }
	table.insert(A.lastResults, 1, rec)
	while #A.lastResults > 8 do table.remove(A.lastResults) end
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
				az = math.Round(A.Azimuth(L, ang.y, p.pos), 1) }
		end
		A.Report("paths", { name = data.SoundName, relayed = relayed, aS = r.aS, aL = r.aL, voices = vs, paths = ps,
			trans = r.trans and { loss_db = math.Round(r.trans.lossDb, 1), raw_db = math.Round(r.trans.rawLossDb or r.trans.lossDb, 1),
				mid_db = math.Round(r.trans.midDb or 0, 1), walls = #r.trans.walls, lp = r.trans.lp },
			ms = math.Round(rec.ms, 3) })
	end
	return true
end

A.AddHook("EntityEmitSound", function(data)
	if A.reemitting then return end
	if not A.Eligible(data) then return end
	local pos = A.SoundPos(data)
	if not pos then return end
	-- echoes (native reflections) for loud sounds, whoever plays the direct sound
	if A.Native and A.Native.render and A.Enabled() then A.Native.Echo(data, pos) end
	local ply = LocalPlayer()
	if IsValid(ply) and data.Entity == ply then return end -- own sounds: always clear
	data.Pos = pos
	if A.Process(data, false) then return false end
end)

-- relayed server sounds: always played by us (the server suppressed the original)
A.dict = A.dict or {}
local pendingAcks = {}
timer.Create("audioprop_ack", 0.2, 0, function()
	if #pendingAcks == 0 then return end
	net.Start("audioprop_snd_ack")
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
	if IsValid(e) and not e:IsWorld() and data.Channel ~= CHAN_AUTO then
		A.Emit(e.EmitSound, e, data.SoundName, data.SoundLevel, data.Pitch, data.Volume, data.Channel, data.Flags, data.DSP)
	else
		A.Emit(EmitSound, data.SoundName, data.Pos, IsValid(e) and data.EntIndex or 0, data.Channel, data.Volume,
			data.SoundLevel, data.Flags, data.Pitch, data.DSP)
	end
end)
