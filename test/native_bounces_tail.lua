-- native_bounces_tail (client lua_job, native renderer running, map pba_tworooms): the room reverb's parametric TAIL must
-- start at its level with the DEFAULT pba_native_bounces, not only with a generous one.
-- Why: Steam Audio stops a ray when its path is longer than duration x c (the 0.5 s window = 171 m), or after numBounces
-- bounces, whichever comes first. In a room of mean free path 4V/S = 4.2 m (this map: 9.7 x 9.7 x 3.7 m) 16 bounces
-- are 67 m = 0.2 s: the energy field is empty after that, so the hybrid EQ (the share of the response's energy beyond the
-- convolution / tail handover, 0.375 s) comes out about 25 dB too low and the tail is inaudible (measured 2026-11-16 in game,
-- noise burst captured at the final output: 0.6 s after its end the reverb was at -60 dB re the steady state, -26 dB with 256
-- bounces; T20 0.55 s against 1.7 s).
-- The tail EQ the module reports (Stats().tailEqMid) is read with the default value, then with 256 (the reference: the
-- window, not the bounce count, bounds the tracing). Verdict: default / reference >= 0.5 (-6 dB; measured 0.06 with 16, 0.9 with
-- 128; the readings still move by +-3 dB between runs, the average of successive simulation passes).
local N, NA = pba.Native, pba_native
job:wait(function() return N and N.ready and N.render end, 15)
if not (N and N.ready and N.render) then return { pass = false, err = "native renderer not running" } end
local st0 = NA.Stats()
if st0.tailEqMid == nil then return { pass = false, err = "module without Stats().tailEqMid" } end

local function u32(n) return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256) end
local function u16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
local parts, seed = {}, 12345
for i = 1, 48000 do
	seed = (seed * 1664525 + 1013904223) % 4294967296
	parts[i] = u16(math.floor((math.floor(seed / 65536) - 32768) * 0.5) % 65536)
	if i % 8000 == 0 then job:step() end
end
local pcm = table.concat(parts)
local KEEP = "pba_test_bounces_tail"
NA.LoadSound(KEEP, "RIFF" .. u32(36 + #pcm) .. "WAVEfmt " .. u32(16) .. u16(1) .. u16(1) .. u32(48000) .. u32(96000) .. u16(2) .. u16(16) .. "data" .. u32(#pcm) .. pcm)

local cv = GetConVar("pba_native_bounces")
local was = cv:GetInt()
local default = tonumber(cv:GetDefault())
local L = LocalPlayer():EyePos()
local pos = L + Vector(100, 0, 0)

local function setBounces(b)
	RunConsoleCommand("pba_native_bounces", tostring(b))
	for _ = 1, 60 do
		if (pba.cfg.native_bounces or -1) == b and NA.Stats().bounces == b then break end
		job:sleep(0.1)
	end
end

-- median of the tail EQ (mid band) over `n` readings, 0.5 s apart, after `warm` seconds of the noise playing
local function read(b, warm, n)
	setBounces(b)
	local id = NA.Play(KEEP, pos, 0.5, 1, 1, 1, 100, true, 0)
	job:sleep(warm)
	local v = {}
	for _ = 1, n do
		local s = NA.Stats()
		if (s.tailEqMid or 0) > 0 then v[#v + 1] = s.tailEqMid end
		job:sleep(0.5)
	end
	NA.StopVoice(id)
	job:sleep(1)
	table.sort(v)
	return v[math.floor((#v + 1) / 2)] or 0, #v
end

local eqDefault, nd = read(default, 6, 12)
local eqRef, nr = read(256, 6, 12)
setBounces(was)
local ratio = eqRef > 0 and eqDefault / eqRef or 0
return { pass = nd >= 6 and nr >= 6 and ratio >= 0.5, default = default, eqDefault = eqDefault, eqRef256 = eqRef,
	ratio = math.Round(ratio, 3), ratioDb = ratio > 0 and math.Round(20 * math.log10(ratio), 1) or nil, readings = { nd, nr } }
