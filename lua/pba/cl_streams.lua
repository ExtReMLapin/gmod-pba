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
	local okv, vol = pcall(O.GetVolume, ch)
	r = { vol = okv and vol or 1, g = 1, apparent = nil, eq = { 1, 1, 1 } }
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

local function applyVol(ch, r) O.SetVolume(ch, (r.vol or 1) * (r.g or 1)) end

function meta:SetPos(pos, dir, vel)
	local ok, r = pcall(record, self)
	if not ok or not r or not enabled() then return O.SetPos(self, pos, dir, vel) end
	r.pos, r.dir, r.vel = pos, dir, vel
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
local function evaluate(ch, r, L)
	local S = r.pos
	local res = A.Paths.Compute(S, L, 75)
	if res.clear or not res.voices or #res.voices == 0 then
		r.apparent, r.g, r.eq = nil, 1, { 1, 1, 1 }
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
	r.apparent, r.g, r.eq = nil, 1, { 1, 1, 1 }
	pcall(applyPos, ch, r)
	pcall(applyVol, ch, r)
	if r.filtered then pcall(pba_native.StreamFilter, ch, 1, 1, 1) end
end

timer.Create("pba_streams", 0.25, 0, function()
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	local L = A.ListenerPos()
	if not L then return end
	local on = enabled()
	local n = 0
	for ch, r in pairs(ST.chans) do
		local okv, valid = pcall(ch.IsValid, ch)
		if not okv or not valid then
			ST.chans[ch] = nil
		elseif not on then
			if r.apparent or (r.g or 1) ~= 1 or r.filtered then release(ch, r) end
		elseif r.pos then
			n = n + 1
			local ok = pcall(evaluate, ch, r, L)
			if ok then
				pcall(applyPos, ch, r)
				pcall(applyVol, ch, r)
				filter(ch, r)
			end
		end
	end
	ST.count = n
	if pba_native and pba_native.StreamCollect then pcall(pba_native.StreamCollect) end
end)
