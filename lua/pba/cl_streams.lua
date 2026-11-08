-- BASS streams of other addons (radios, media players: sound.PlayURL / sound.PlayFile "3d").
-- They never go through EntityEmitSound. A TRANSPARENT detour of the shared IGModAudioChannel
-- metatable discovers every 3D channel the first time its owner positions it:
--   * SetPos / SetVolume remember the values the owner wants; GetPos / GetVolume return them,
--     so the owner sees nothing changed;
--   * every 0.25 s, pba computes the paths as for a loop and applies, through the
--     original methods: the apparent position (the opening) and the level (losses, plus a
--     correction for BASS's own distance law at the apparent position);
--   * with the native module, a 3-band EQ is attached to the channel as a BASS DSP: the radio
--     behind a wall is really muffled (cl_native: pba_native.StreamFilter).
-- Everything is in pcall with a fallback to the original call; pba_streams 0 restores the
-- owners' values and the original methods. See docs/SITREP_STREAMS.md.

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
-- Set3DFadeDistance's "max" only as a cut-off). Used to correct the level at the apparent position.
local function bassGain(ch, d)
	local ok, mn, mx = pcall(ch.Get3DFadeDistance, ch)
	mn = (ok and mn and mn > 0) and mn or 200
	if d <= mn then return 1 end
	return mn / d
end

local function applyPos(ch, r)
	local pos = r.apparent or r.pos
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
	O.SetVolume(ch, (r.vol or 1) * (r.g or 1))
end

--- Native voice of a stream: position, gain (owner volume x BASS distance law x path), EQ.
local function nativeParams(ch, r, L)
	local pos = r.apparent or r.pos
	local dS = r.pos:Distance(L)
	local gain = (r.vol or 1) * bassGain(ch, dS) * (r.gRel or 1) * A.cfg.native_gain
	local el, em, eh = A.Native.VoiceEQ(r.lp or 0, r.len or dS)
	return pos, gain, el, em, eh
end

local function nativeUpdate(ch, r, L)
	if not r.nativeId then return end
	local pos, gain, el, em, eh = nativeParams(ch, r, L)
	if not pba_native.Update(r.nativeId, pos, gain, el, em, eh, 100) then r.nativeId = nil end
end

local function nativeStart(ch, r, L)
	local ok, id = pcall(function()
		local pos, gain, el, em, eh = nativeParams(ch, r, L)
		return pba_native.PlayStream(ch, pos, gain, el, em, eh, 100)
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
	A.DebugNote(ch, S, L, res, r.file or "stream", "stream")
	if res.clear or not res.voices or #res.voices == 0 then
		r.apparent, r.g, r.eq, r.gRel, r.lp, r.len = nil, 1, { 1, 1, 1 }, 1, 0, nil
		return
	end
	local p = 0
	for _, v in ipairs(res.voices) do p = p + v.gain * v.gain end
	local dS = S:Distance(L)
	local g = math.sqrt(p) / math.max(AC.EngineGain(dS, 75), 1e-6)
	local apparent = res.voices[1].pos
	-- BASS attenuates from the apparent (closer) position: compensate to the real distance
	local corr = bassGain(ch, dS) / math.max(bassGain(ch, apparent:Distance(L)), 1e-6)
	r.apparent, r.g = apparent, math.Clamp(g * corr, 0, 1)
	r.gRel, r.lp, r.len = math.Clamp(g, 0, 1), res.voices[1].lp or 0, res.voices[1].len
	local N = A.Native
	r.eq = N and N.EQ and N.EQ[math.Clamp(res.voices[1].lp or 0, 0, 4)] or { 1, 1, 1 }
end

local function filter(ch, r)
	local N = A.Native
	if not (N and N.ready and pba_native and pba_native.StreamFilter) then return end
	if (A.cfg.streams_filter or 0) < 0.5 then return end
	if r.filterFailed then return end
	local e = r.eq
	local ok, done, why = pcall(pba_native.StreamFilter, ch, e[1], e[2], e[3])
	if not ok or not done then
		r.filterFailed = tostring(why or done)
		ST.lastFilterError = r.filterFailed
	else
		r.filtered = true
	end
end

local function release(ch, r)
	nativeStop(ch, r)
	r.apparent, r.g, r.eq = nil, 1, { 1, 1, 1 }
	pcall(applyPos, ch, r)
	pcall(applyVol, ch, r)
	if r.filtered then pcall(pba_native.StreamFilter, ch, 1, 1, 1) r.filtered = nil end
end

timer.Create("pba_streams", A.cfg.update_interval or 0.25, 0, function()
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
		elseif r.pos then
			n = n + 1
			local ok, err = pcall(evaluate, ch, r, L)
			if not ok and ST.lastEvalError ~= err then
				-- never swallow silently: keep it for diagnostics and say it once
				ST.lastEvalError = err
				ErrorNoHalt("[PBA] stream evaluation failed: " .. tostring(err) .. "\n")
			end
			if ok then
				if nativeMode(r) then
					if r.filtered then pcall(pba_native.StreamFilter, ch, 1, 1, 1) end
					if not r.nativeId then nativeStart(ch, r, L) else pcall(nativeUpdate, ch, r, L) end
				elseif r.nativeId then
					nativeStop(ch, r) -- native rendering switched off: back to BASS
				end
				pcall(applyPos, ch, r)
				pcall(applyVol, ch, r)
				if not r.nativeId then filter(ch, r) end
			end
		end
	end
	ST.count = n
	if pba_native and pba_native.StreamCollect then pcall(pba_native.StreamCollect) end
end)
