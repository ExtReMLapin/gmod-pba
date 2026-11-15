-- source_long_rt (client lua_job of test/source_long_rt.py; native rendering): the reverb time of a source reverb slot's tail,
-- with pba_native_source_long_rt off then on. The module renders a slot's tail with the reverb times of its main simulation (0.5 s
-- window, saturating near 1.2 s) unless the option gives it its own long-window estimate, simulated at the slot's position.
--   SLR (global, written in front of this file by the driver):
--     src      Vector, where the sound is (the listener stays where the player is)
--     opts     { 0, 1 } the option values to measure, in this order
--     capture  true: also record the module's final output of a noise burst fed into the slot (pba_native.CaptureStart/Stop),
--              file data/pba/<name>_o<opt>.wav, SLR.name / SLR.seconds
--     settle   seconds the slot gets to be simulated and its estimate to converge (default 3)
-- One measure = a silent looping voice binds a source slot at src (its first response is simulated, its estimate made), then the
-- burst (20 ms of noise, no room send: only the slot's reverb and the direct sound reach the output) is fed into the SAME slot,
-- so it never waits for a simulation (the keeper feeds the slot at 1e-7: its own noise must not mask the tail). Returns, per option value: the reverb times the slot's tail used (pba_native.SlotReverbTimes:
-- rt, the main simulation's own estimate mainRt, long = the long-window one, n = passes averaged), the room's (RoomReverb) and the
-- reflection thread's cost (Stats: reflMs, srcMs, slotRevMs, slotRevRuns).
local N = pba.Native
local res = { opts = {}, map = game.GetMap() }
if not (N and N.render and pba_native) then res.err = "native renderer not running" return res end
-- (a module without the getter, older than feat/source-long-rt, is measured through its capture alone: the red run)
res.getter = pba_native.SlotReverbTimes ~= nil
local S = SLR or {}
local src = S.src
local settle = S.settle or 3
local function cv(n) return GetConVar(n) end
local function setOpt(v)
	RunConsoleCommand("pba_native_source_long_rt", tostring(v))
	for _ = 1, 60 do
		if math.abs((pba.cfg.native_source_long_rt or -1) - v) < 1e-6 then break end
		job:sleep(0.05)
	end
	job:sleep(0.8) -- cl_native pushes the options to the module every 0.5 s
end

-- a 20 ms noise burst, 16 bit mono 48 kHz, as a WAV for pba_native.LoadSound
local function u32(n) return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256) end
local function u16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
local function burst(name, frames)
	local parts = {}
	local seed = 12345
	for i = 1, frames do
		seed = (seed * 1664525 + 1013904223) % 4294967296
		local x = (math.floor(seed / 65536) - 32768) * 0.7
		parts[i] = u16(math.floor(x) % 65536)
		if i % 4000 == 0 then job:step() end
	end
	local pcm = table.concat(parts)
	local wav = "RIFF" .. u32(36 + #pcm) .. "WAVEfmt " .. u32(16) .. u16(1) .. u16(1) .. u32(48000) .. u32(96000) .. u16(2) .. u16(16)
		.. "data" .. u32(#pcm) .. pcm
	return pba_native.LoadSound(name, wav)
end
local BURST, KEEP = "pba_test_slotrt_burst", "pba_test_slotrt_keep"
local okB = burst(BURST, 960)
local okK = burst(KEEP, 48000)
if not (okB and okK) then res.err = "cannot load the test sounds" return res end

local function slotRow(slot)
	if not pba_native.SlotReverbTimes then return nil end
	for _, r in ipairs(pba_native.SlotReverbTimes()) do
		if r.kind == "src" and r.slot == slot then return r end
	end
end
local function roomRt() local a, b, c = pba_native.RoomReverb(LocalPlayer():EyePos()) return { a, b, c } end

local keep, slot
local function measure(opt)
	setOpt(opt)
	local m = { opt = opt }
	local st0 = pba_native.Stats()
	keep = pba_native.Play(KEEP, src, 0.0000001, 1, 1, 1, 100, true, 0, nil, 0, 0)
	if not keep or keep <= 0 then m.err = "play failed" return m end
	slot = pba_native.SourceReflect(keep, src, 0.0000001)
	m.slot = slot
	local t0 = RealTime()
	while RealTime() - t0 < settle do
		slot = pba_native.SourceReflect(keep, src, 0.0000001) -- (a loop re-binds as it updates)
		job:sleep(0.2)
	end
	local row = slotRow(slot)
	if row then
		m.rt, m.mainRt, m.long, m.n = row.rt, row.mainRt, row.long, row.n
	end
	m.room = roomRt()
	if S.capture then
		local secs = S.seconds or 10
		local ok, why = pba_native.CaptureStart(secs + 1)
		if not ok then m.err = "CaptureStart: " .. tostring(why) else
			local b = pba_native.Play(BURST, src, 1, 1, 1, 1, 100, false, 0, nil, 0, 0)
			pba_native.SourceReflect(b, src, 1)
			job:sleep(0.1)
			local t1 = RealTime()
			while RealTime() - t1 < secs do
				pba_native.SourceReflect(keep, src, 0.0000001)
				job:sleep(0.25)
			end
			local path, frames, peak = pba_native.CaptureStop((S.name or "slotrt") .. "_o" .. opt, 32)
			m.capture = path and { path = path, frames = frames, peak = peak } or { err = tostring(frames) }
		end
		row = slotRow(slot)
		if row then m.rtAfter = row.rt end
	end
	local st1 = pba_native.Stats()
	m.stats = { reflMs = st1.reflMs, srcMs = st1.srcMs, slotRevMs = st1.slotRevMs, slotRevRuns = (st1.slotRevRuns or 0) - (st0.slotRevRuns or 0),
		srcLongRt = st1.srcLongRt, reflRuns = st1.reflRuns, srcSlots = st1.srcSlots }
	pba_native.StopVoice(keep)
	job:sleep(0.3)
	return m
end

local saved = cv("pba_native_source_long_rt"):GetString()
local ok, err = pcall(function()
	for _, o in ipairs(S.opts or { 0, 1 }) do res.opts[#res.opts + 1] = measure(o) end
end)
if not ok then res.err = tostring(err) end
if keep then pba_native.StopVoice(keep) end
RunConsoleCommand("pba_native_source_long_rt", saved)
res.listener = tostring(LocalPlayer():EyePos())
return res
