-- BASS streams of other addons (radios, media players: sound.PlayURL / sound.PlayFile "3d").
-- They never go through EntityEmitSound. A TRANSPARENT detour of the shared IGModAudioChannel
-- metatable discovers every 3D channel the first time its owner positions it:
--   * SetPos / SetVolume remember the values the owner wants; GetPos / GetVolume return them,
--     so the owner sees nothing changed;
--   * every 0.25 s, pba computes the paths as for a loop and applies, through the
--     original methods: the apparent position (the opening) and the level (losses, plus a
--     correction for BASS's own distance law at the apparent position);
--   * the distance law stays the channel's own (BASS: full up to the owner's Set3DFadeDistance min, then
--     min / d), for the BASS channel and for the native voice alike: the addon's author chose the range
--     (a radio set to 1e6 means "the same volume on the whole floor", not a 1 m point source);
--   * with the native module, a 3-band EQ is attached to the channel as a BASS DSP: the radio
--     behind a wall is really muffled (cl_native: pba_native.StreamFilter).
-- Everything is in pcall with a fallback to the original call; pba_streams 0 restores the
-- owners' values and the original methods.

local A = pba
local AC = A.AC
local ST = A.Streams or {}
A.Streams = ST

local meta = FindMetaTable("IGModAudioChannel")
if not meta then return end

ST.chans = ST.chans or setmetatable({}, { __mode = "k" }) -- channel -> record
-- methods in place when pba installed its detour (another addon may have detoured first)
ST.orig = ST.orig or { SetPos = meta.SetPos, GetPos = meta.GetPos, SetVolume = meta.SetVolume, GetVolume = meta.GetVolume }
local O = ST.orig

local function enabled() return (A.cfg.streams or 0) >= 0.5 and A.Enabled() end

local function record(ch)
	local r = ST.chans[ch]
	if r then return r end
	local ok, is3d = pcall(function() return ch:Is3D() and ch:Get3DEnabled() end)
	if not ok or not is3d then return nil end -- 2D channels (interface music): untouched
	if table.Count(ST.chans) >= (A.cfg.streams_max or 16) then return nil end -- cap: untouched
	local okv, vol = pcall(O.GetVolume, ch)
	r = { vol = okv and vol or 1, g = 1, apparent = nil, eq = { 1, 1, 1 } }
	local okf, file = pcall(ch.GetFileName, ch)
	r.file = okf and file or nil -- shown by the debug overlay
	ST.chans[ch] = r
	return r
end

-- BASS distance law (rolloff 1): full volume up to `min`, then min / d (silent past `max` with
-- Set3DFadeDistance's "max" only as a cut-off). The law of a stream's level, BASS channel and native
-- voice alike (see the header), and the correction of the level at the apparent position.
-- GMod's defaults are min 200, max 1e9 (wiki, IGModAudioChannel:Set3DFadeDistance, "The default
-- values"): a channel whose min cannot be read is taken at that default, and it is said once in the
-- console (a silent 200 hid a broken binding: a radio set to 1e6 would be heard 14 dB low at 5 m).
local BASS_DEFAULT_MIN = 200
local function bassGain(ch, d)
	local ok, mn = pcall(ch.Get3DFadeDistance, ch)
	if not ok or type(mn) ~= "number" or mn <= 0 then
		if not ST.fadeWarned then
			ST.fadeWarned = true
			MsgN("[PBA] streams: Get3DFadeDistance gave ", tostring(mn), "; BASS's default min distance (",
				BASS_DEFAULT_MIN, " u) assumed for such channels")
		end
		mn = BASS_DEFAULT_MIN
	end
	if d <= mn then return 1 end
	return mn / d
end

-- r.hPos / r.hG / r.hEq: what a running ramp (continuous_ramp) makes heard now, instead of the targets
local function applyPos(ch, r)
	local pos = r.hPos or r.apparent or r.pos
	if pos then O.SetPos(ch, pos, r.dir, r.apparent and vector_origin or r.vel) end
end

-- rendered by the native module (N2): BASS is muted (FFT / GetLevel are not affected by the
-- channel volume, so visualisers keep working), the module plays the captured audio
local function nativeMode(r)
	local N = A.Native
	return N and N.render and (A.cfg.streams_native or 0) >= 0.5 and pba_native and pba_native.PlayStream
		and not r.nativeFailed
end

local function applyVol(ch, r)
	if r.nativeId then O.SetVolume(ch, 0) return end
	O.SetVolume(ch, (r.vol or 1) * (r.hG or r.g or 1))
end

--- Reverb sends of a stream's native voice: the same rule as every sound (cl_native, "Reverb of natively
-- rendered sounds"), with the channel's own distance law (bassGain: the addon chose the range): source
-- slot = N.SlotSend(law, d) (refreshed every 0.3 s, the module frees one not refreshed for 1 s), listener
-- room = what enters the listener's space (r.entryG, N.EntrySend per voice at the last evaluation). No
-- slot: the room bus at the gain.
local function streamSend(ch, r, L, g, pos)
	local N = A.Native
	local now = RealTime()
	if r.nativeId and (not r.srcNext or now >= r.srcNext) then
		r.srcNext = now + 0.3
		local law = function(d) return bassGain(ch, d) end
		r.srcBound = N.BindSource(r.nativeId, r.pos, (r.vol or 1) * N.SlotSend(law, r.pos:Distance(L)) * A.cfg.native_gain)
	end
	if not r.srcBound then return g end
	if r.entryG then return (r.vol or 1) * r.entryG * A.cfg.native_gain end
	return 0
end

--- Native voice of a stream: position, gain (owner volume x BASS distance law x path), EQ.
local function nativeParams(ch, r, L)
	local pos = r.apparent or r.pos
	local dS = r.pos:Distance(L)
	-- the channel's own distance law (bassGain), not the full version's 1/r from 1 m (N.PhysStream, the law
	-- of engine sounds): an addon that set Set3DFadeDistance(1e6, ...) wants its radio heard alike on the
	-- whole floor; with 1/r it came out 14 dB weaker at 5 m (gm_melancholia: ~10 dB under vanilla next door)
	local gain = (r.vol or 1) * (r.gNative or bassGain(ch, dS)) * A.cfg.native_gain
	local el, em, eh = A.Native.VoiceEQ(r.lp or 0, r.len or dS, r.lpDb)
	local send = streamSend(ch, r, L, gain, pos)
	return pos, gain, el, em, eh, send
end

local function nativeUpdate(ch, r, L)
	if not r.nativeId then return end
	local pos, gain, el, em, eh, send = nativeParams(ch, r, L)
	if not pba_native.Update(r.nativeId, pos, gain, el, em, eh, 100, r.diffuse or 0, send) then r.nativeId = nil end
end

local function nativeStart(ch, r, L)
	local ok, id = pcall(function()
		local pos, gain, el, em, eh, send = nativeParams(ch, r, L)
		return pba_native.PlayStream(ch, pos, gain, el, em, eh, 100, send)
	end)
	if ok and id and id > 0 then
		r.nativeId = id
		O.SetVolume(ch, 0)
	else
		r.nativeFailed = true
		ST.lastNativeError = ok and "PlayStream failed" or tostring(id)
	end
end

local function nativeStop(ch, r)
	if r.nativeId and pba_native then pba_native.StopVoice(r.nativeId) end
	r.nativeId = nil
	if pba_native and pba_native.StreamCapture then pcall(pba_native.StreamCapture, ch, false) end
end

function meta:SetPos(pos, dir, vel)
	local ok, r = pcall(record, self)
	if not ok or not r or not enabled() then return O.SetPos(self, pos, dir, vel) end
	r.pos, r.dir, r.vel = pos, dir, vel
	if r.ramp and r.ramp.pending then return end -- gliding: placed every frame (pba_streams_ramp)
	if r.nativeId and not r.apparent then
		-- clear line: the native voice follows the owner's position every frame
		local L = A.ListenerPos()
		if L then pcall(nativeUpdate, self, r, L) end
	end
	if not r.apparent then return O.SetPos(self, pos, dir, vel) end
	local ok2 = pcall(applyPos, self, r)
	if not ok2 then return O.SetPos(self, pos, dir, vel) end
end

function meta:GetPos()
	local r = ST.chans[self]
	if r and r.pos then return r.pos end
	return O.GetPos(self)
end

function meta:SetVolume(v)
	local r = ST.chans[self]
	if not r or not enabled() then return O.SetVolume(self, v) end
	r.vol = v
	if r.nativeId and r.reeval then r.reeval.force = true end -- the native gain follows at its next turn
	local ok = pcall(applyVol, self, r)
	if not ok then return O.SetVolume(self, v) end
end

function meta:GetVolume()
	local r = ST.chans[self]
	if r and r.vol then return r.vol end
	return O.GetVolume(self)
end

--- Path from the stream's position to the listener: apparent position, gain relative to the
-- direct line (BASS law corrected), EQ.
-- A stream has no entity, but it is played AT one (the radio's model): without this the radio
-- would occlude its own sound like a wall. The object whose box contains the stream position.
local function emitterAt(S)
	local best, bestD
	for _, e in ipairs(ents.FindInSphere(S, 48)) do
		if IsValid(e) and not e:IsPlayer() and not e:IsWorld() and e:GetModel() then
			local lp = e:WorldToLocal(S)
			local mn, mx = e:OBBMins() - Vector(8, 8, 8), e:OBBMaxs() + Vector(8, 8, 8)
			if lp.x >= mn.x and lp.y >= mn.y and lp.z >= mn.z and lp.x <= mx.x and lp.y <= mx.y and lp.z <= mx.z then
				local d = e:WorldSpaceCenter():DistToSqr(S)
				if not bestD or d < bestD then best, bestD = e, d end
			end
		end
	end
	return best
end

local function evaluate(ch, r, L)
	local S = r.pos
	if not r.emitterPos or r.emitterPos:DistToSqr(S) > 1 or (r.emitter ~= nil and not IsValid(r.emitter)) then
		r.emitter, r.emitterPos = emitterAt(S) or false, S
	end
	r.hyst = r.hyst or {}
	local res = A.Paths.Stable(r.hyst, A.Paths.Compute(S, L, 75, nil, r.emitter or nil))
	if res.provisional and r.reeval then r.reeval.force = true end -- probe search still running
	A.DebugNote(ch, S, L, res, r.file or "stream", "stream")
	if res.clear or not res.voices or #res.voices == 0 then
		r.apparent, r.g, r.eq, r.gRel, r.lp, r.lpDb, r.len, r.diffuse = nil, 1, { 1, 1, 1 }, 1, 0, nil, nil, 0
		r.entryG, r.gNative = nil, nil -- native: the channel's law at the true distance; clear: slot only
		return
	end
	-- each voice keeps its own losses (walls, doors, corners, absorption) but its distance law is the
	-- channel's (BASS min / d), not the engine's at 75 dB: a long detour of a stream heard from far
	-- (Set3DFadeDistance) lost tens of dB it never would have (room 14: -47 dB instead of -16).
	-- The native voice uses the same channel-law gains (header: the addon chose the range)
	local p, pd, pe = 0, 0, 0
	local dS = S:Distance(L)
	local N0 = A.Native
	local law = function(d) return bassGain(ch, d) end
	for _, v in ipairs(res.voices) do
		local len = v.len or dS
		local loss = N0 and N0.LossLin and N0.LossLin(v, 75) or v.gain / math.max(AC.EngineGain(len, 75), 1e-6)
		local gv = loss * bassGain(ch, len)
		p, pd = p + gv * gv, pd + gv * gv * (v.diffuse or 0)
		-- what ENTERS the listener's space (through an opening or a wall): the same rule as every sound
		if N0 and N0.EntrySend then local s = N0.EntrySend(law, v, L, loss) pe = pe + s * s end
	end
	r.gNative = math.sqrt(p)
	r.entryG = math.sqrt(pe)
	-- energy-weighted diffuse share (diffuse model): rendered by the native module only (BASS has no DSP)
	r.diffuse = pd / math.max(p, 1e-12)
	local g = math.sqrt(p) / math.max(bassGain(ch, dS), 1e-6)
	local apparent = res.voices[1].pos
	-- BASS attenuates from the apparent (closer) position: compensate to the real distance
	local corr = bassGain(ch, dS) / math.max(bassGain(ch, apparent:Distance(L)), 1e-6)
	r.apparent, r.g = apparent, math.Clamp(g * corr, 0, 1)
	r.gRel, r.lp, r.lpDb, r.len = math.Clamp(g, 0, 1), res.voices[1].lp or 0, res.voices[1].lpDb, res.voices[1].len
	-- the BASS filter: the same continuous low-pass EQ as a native voice (N.LowpassEQ: the volume already
	-- holds the loss at diff_freq, the EQ only the other bands' difference)
	local N = A.Native
	if N and N.LowpassEQ then
		local l, m, h = N.LowpassEQ(r.lp, r.lpDb)
		r.eq = { l, m, h }
	else
		r.eq = { 1, 1, 1 }
	end
end

local function filter(ch, r)
	local N = A.Native
	if not (N and N.ready and pba_native and pba_native.StreamFilter) then return end
	if (A.cfg.streams_filter or 0) < 0.5 then return end
	if r.filterFailed then return end
	local e = r.hEq or r.eq
	local ok, done, why = pcall(pba_native.StreamFilter, ch, e[1], e[2], e[3])
	if not ok or not done then
		r.filterFailed = tostring(why or done)
		ST.lastFilterError = r.filterFailed
	else
		r.filtered = true
	end
end

--- Ramps (continuous_ramp): instead of jumping every interval, a stream glides to each
-- re-evaluation over one interval. Its values: the native voice's, or the BASS channel's (volume
-- factor, filter EQ, position).
local function rampTarget(ch, r, L)
	if r.nativeId then
		local pos, gain, el, em, eh = nativeParams(ch, r, L)
		return gain, el, em, eh, pos
	end
	local e = r.eq
	return r.g or 1, e[1], e[2], e[3], r.apparent or r.pos
end

local function dropRamp(r) r.ramp, r.hPos, r.hG, r.hEq = nil, nil, nil, nil end

-- in clear sight the end of the ramp is the owner's (moving) position
local function retarget(ch, r, L) A.Paths.Retarget(r.ramp, rampTarget(ch, r, L)) end

--- Applies what the ramp makes heard at `now`.
local function applyRamp(ch, r, L, now)
	local g, e1, e2, e3, pos = A.Paths.RampAt(r.ramp, now, L)
	if r.nativeId then
		-- the room reverb send too, from what is heard now (else the voice kept the send of its start)
		local send = streamSend(ch, r, L, g, pos)
		if not pba_native.Update(r.nativeId, pos, g, e1, e2, e3, 100, r.diffuse or 0, send) then r.nativeId = nil end
		return
	end
	r.hG, r.hPos = g, pos
	local e = r.hEq or {}
	e[1], e[2], e[3] = e1, e2, e3
	r.hEq = e
	applyPos(ch, r)
	applyVol(ch, r)
	filter(ch, r)
end

--- New targets from a re-evaluation: ramp from what is heard now.
local function rampStep(ch, r, L, now)
	if not r.ramp then
		r.ramp = {}
		-- a BASS channel taken over glides from how its owner played it (a native voice starts at its target)
		if not r.nativeId then A.Paths.RampTo(r.ramp, now, 0, L, 1, 1, 1, 1, r.pos) end
	end
	A.Paths.RampTo(r.ramp, now, math.max(A.cfg.update_interval or 0.25, 0.05), L, rampTarget(ch, r, L))
	applyRamp(ch, r, L, now)
end

hook.Add("Think", "pba_streams_ramp", A.PerfTimed("streams_ramp", function()
	if next(ST.chans) == nil then return false end
	local L = A.ListenerPos()
	if not L then return false end
	local now = RealTime()
	for ch, r in pairs(ST.chans) do
		if r.ramp and r.ramp.pending and r.pos then
			if not r.apparent then pcall(retarget, ch, r, L) end
			pcall(applyRamp, ch, r, L, now)
		end
	end
end))

--- Adaptive re-evaluation (reeval_adaptive, P.ReevalDue): false while the stream, the listener and
-- the world did not change since its last evaluation (it keeps its values). A rendering switch
-- (native voice to start or to stop) is applied at once.
local function reevalDue(r, L)
	if (r.nativeId ~= nil) ~= (nativeMode(r) and true or false) then return true end
	r.reeval = r.reeval or {}
	return A.Paths.ReevalDue(r.reeval, r.pos, L, RealTime())
end

local function release(ch, r)
	nativeStop(ch, r)
	dropRamp(r)
	r.apparent, r.g, r.eq = nil, 1, { 1, 1, 1 }
	pcall(applyPos, ch, r)
	pcall(applyVol, ch, r)
	if r.filtered then pcall(pba_native.StreamFilter, ch, 1, 1, 1) r.filtered = nil end
end

timer.Create("pba_streams", A.cfg.update_interval or 0.25, 0, A.PerfTimed("streams", function()
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	local L = A.ListenerPos()
	if not L then return end
	local on = enabled()
	local n = 0
	for ch, r in pairs(ST.chans) do
		local okv, valid = pcall(ch.IsValid, ch)
		if not okv or not valid then
			if r.nativeId and pba_native then pba_native.StopVoice(r.nativeId) end
			ST.chans[ch] = nil
		elseif not on then
			-- a native voice must stop too: the owner keeps setting the BASS volume back, both would play
			if r.apparent or (r.g or 1) ~= 1 or r.filtered or r.nativeId then release(ch, r) end
		elseif r.pos and not reevalDue(r, L) then
			n = n + 1 -- unchanged: keeps its values (and its ramp, if one is still running)
		elseif r.pos then
			n = n + 1
			-- clear sight since the last ramp ended: its end follows the owner's position up to now
			if r.ramp and not r.ramp.pending and not r.apparent then pcall(retarget, ch, r, L) end
			local ok, err = pcall(evaluate, ch, r, L)
			if not ok and ST.lastEvalError ~= err then
				-- never swallow silently: keep it for diagnostics and say it once
				ST.lastEvalError = err
				ErrorNoHalt("[PBA] stream evaluation failed: " .. tostring(err) .. "\n")
			end
			if ok then
				local ramp = (A.cfg.continuous_ramp or 0) >= 0.5
				if nativeMode(r) then
					if r.filtered then pcall(pba_native.StreamFilter, ch, 1, 1, 1) end
					if not r.nativeId then
						dropRamp(r) -- the voice starts at its target
						nativeStart(ch, r, L)
					elseif not ramp then
						pcall(nativeUpdate, ch, r, L)
					end
				elseif r.nativeId then
					nativeStop(ch, r) -- native rendering switched off: back to BASS
					dropRamp(r)
				end
				if ramp then
					pcall(rampStep, ch, r, L, RealTime())
				else
					dropRamp(r)
					pcall(applyPos, ch, r)
					pcall(applyVol, ch, r)
					if not r.nativeId then filter(ch, r) end
				end
			end
		end
	end
	ST.count = n
	if pba_native and pba_native.StreamCollect then pcall(pba_native.StreamCollect) end
end))
