-- source_long_rt_runs (client lua_job, native rendering, map pba_pipe, run ALONE: a cost test): what the long-window estimates add to
-- the source slots' pass, run by run. Stats.srcMs is an exponential average (0.9 / 0.1) that moves only when a pass runs, so a
-- difference of two averages read at two moments (as source_long_rt_cost.lua prints them) mixes the passes of the arrival burst, the
-- warm-up from 0 and the staleness of a settled slot (no pass runs: the value stays): it once read as an unexplained +1.3 ms per pass.
-- Here every pass is read on its own: the average's step in the frame where it changed, ms = (new - 0.9 old) / 0.1, with the number of
-- estimates the pass made (slotRevRuns).
-- RUNS.slots (8) silent looping voices bound to source slots spread over the hall, all moved by 4 m every RUNS.moveEvery s (1.5) so that
-- passes keep coming (a new place: a pending pass, with its estimates); RUNS.seconds (20) per option value (off, then on).
-- Verdict: with the option on a pass costs what its estimates cost and nothing more: (mean pass on - mean pass off) / (mean estimates per
-- pass) <= 1.5 x the module's own time per estimate (Stats.slotRevMs, taken inside the estimate). Measured 2026-11-16 (8 slots, hall):
-- pass off 16.9 ms, on 28.4 ms with 6.9 estimates (1.67 ms each) against 1.61 ms inside the estimate.
local N = pba.Native
local res = { opts = {} }
if not (N and N.render and pba_native and pba_native.SlotReverbTimes) then res.err = "module without SlotReverbTimes" return res end
local C = RUNS or {}
local nSlots, secs, moveEvery = C.slots or 8, C.seconds or 20, C.moveEvery or 1.5
local function u32(n) return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256) end
local function u16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
local parts, seed = {}, 7
for i = 1, 48000 do
	seed = (seed * 1664525 + 1013904223) % 4294967296
	parts[i] = u16(math.floor((math.floor(seed / 65536) - 32768) * 0.5) % 65536)
	if i % 8000 == 0 then job:step() end
end
local pcm = table.concat(parts)
local KEEP = "pba_test_slotrt_runs"
pba_native.LoadSound(KEEP, "RIFF" .. u32(36 + #pcm) .. "WAVEfmt " .. u32(16) .. u16(1) .. u16(1) .. u32(48000) .. u32(96000) .. u16(2) .. u16(16) .. "data" .. u32(#pcm) .. pcm)
local L = LocalPlayer():EyePos()
local M = 52.49
local base = {}
for i = 1, nSlots do
	local a = (i / nSlots) * math.pi * 2
	base[i] = L + Vector(math.cos(a) * (6 + 4 * (i % 3)) * M, math.sin(a) * (6 + 3 * (i % 2)) * M, 60)
end

local function run(opt)
	RunConsoleCommand("pba_native_source_long_rt", tostring(opt))
	for _ = 1, 60 do
		if math.abs((pba.cfg.native_source_long_rt or -1) - opt) < 1e-6 then break end
		job:sleep(0.05)
	end
	job:sleep(1.5)
	local ids, ph, off = {}, 0, Vector(0, 0, 0)
	for i = 1, nSlots do ids[i] = pba_native.Play(KEEP, base[i], 0.0000001, 1, 1, 1, 100, true, 0, nil, 0, 0) end
	local m = { opt = opt, passes = 0, ms = 0, est = 0, rev = 0 }
	local last = pba_native.Stats()
	local lastRuns = last.slotRevRuns or 0
	local t0, tm = RealTime(), RealTime()
	while RealTime() - t0 < secs do
		if RealTime() - tm > moveEvery then
			tm, ph = RealTime(), ph + 1
			off = Vector(math.cos(ph * 2.1) * 210, math.sin(ph * 2.1) * 210, 0)
		end
		for i = 1, nSlots do if ids[i] and ids[i] > 0 then pba_native.SourceReflect(ids[i], base[i] + off, 0.0000001) end end
		job:frames(1)
		local st = pba_native.Stats()
		if st.srcMs ~= last.srcMs then
			local runs = st.slotRevRuns or 0
			local ms = (st.srcMs - 0.9 * last.srcMs) / 0.1
			if last.srcMs > 0 and runs - lastRuns <= 12 then -- (two passes in one frame, or the first one, are not read)
				m.passes, m.ms, m.est, m.rev = m.passes + 1, m.ms + ms, m.est + runs - lastRuns, m.rev + (st.slotRevMs or 0)
			end
			lastRuns = runs
			last = st
		end
	end
	for _, id in ipairs(ids) do pba_native.StopVoice(id) end
	job:sleep(1.5)
	if m.passes > 0 then m.ms, m.est, m.rev = m.ms / m.passes, m.est / m.passes, m.rev / m.passes end
	return m
end

local saved = GetConVar("pba_native_source_long_rt"):GetString()
local ok, err = pcall(function() for _, o in ipairs({ 0, 1 }) do res.opts[#res.opts + 1] = run(o) end end)
if not ok then res.err = tostring(err) end
RunConsoleCommand("pba_native_source_long_rt", saved)
local off, on = res.opts[1], res.opts[2]
if off and on and on.est > 0 and on.passes >= 10 and off.passes >= 10 then
	res.perEstimate = (on.ms - off.ms) / on.est
	res.insideEstimate = on.rev
	res.pass = res.perEstimate <= 1.5 * on.rev and off.est == 0
else
	res.pass = false
	res.err = res.err or "too few passes read"
end
return res
