-- source_long_rt_cost (client lua_job, native rendering, on the map pba_pipe): what pba_native_source_long_rt costs the
-- reflection thread with several source reverb slots busy. SLRC.slots (default 8) silent looping voices are bound to
-- slots spread over the hall (more than the 1.5 m a slot is shared over apart), SLRC.seconds (default 12) per option value.
-- Per option value: the module's own timings read every 0.5 s (Stats: reflMs = the main reflections pass, srcMs = the source
-- slots' pass, slotRevMs = one long-window estimate, slotRevRuns = estimates made; all smoothed by the module, averaged here),
-- the estimates made in the first 4 s (the slots arriving) and in the rest (settled slots: none expected); the pass times of the last 3 s (settled: the module smooths them over ~10 runs, so the arrival burst has left), and the time until every
-- slot holds its estimate (SlotReverbTimes: long, n >= passes).
local N = pba.Native
local res = { opts = {} }
if not (N and N.render and pba_native and pba_native.SlotReverbTimes) then res.err = "module without SlotReverbTimes" return res end
local C = SLRC or {}
local nSlots, secs = C.slots or 8, C.seconds or 12
local function u32(n) return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256) end
local function u16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
local parts, seed = {}, 7
for i = 1, 48000 do
	seed = (seed * 1664525 + 1013904223) % 4294967296
	parts[i] = u16(math.floor((math.floor(seed / 65536) - 32768) * 0.5) % 65536)
	if i % 8000 == 0 then job:step() end
end
local pcm = table.concat(parts)
local KEEP = "pba_test_slotrt_cost"
pba_native.LoadSound(KEEP, "RIFF" .. u32(36 + #pcm) .. "WAVEfmt " .. u32(16) .. u16(1) .. u16(1) .. u32(48000) .. u32(96000) .. u16(2) .. u16(16) .. "data" .. u32(#pcm) .. pcm)

local L = LocalPlayer():EyePos()
local M = 52.49
local positions = {}
for i = 1, nSlots do
	local a = (i / nSlots) * math.pi * 2
	positions[i] = L + Vector(math.cos(a) * (6 + 4 * (i % 3)) * M, math.sin(a) * (6 + 3 * (i % 2)) * M, 60)
end

local function run(opt)
	RunConsoleCommand("pba_native_source_long_rt", tostring(opt))
	for _ = 1, 60 do
		if math.abs((pba.cfg.native_source_long_rt or -1) - opt) < 1e-6 then break end
		job:sleep(0.05)
	end
	job:sleep(1.0)
	local ids, slots = {}, {}
	local st0 = pba_native.Stats()
	local t0 = RealTime()
	for i, p in ipairs(positions) do
		ids[i] = pba_native.Play(KEEP, p, 0.0000001, 1, 1, 1, 100, true, 0, nil, 0, 0)
		slots[i] = ids[i] and ids[i] > 0 and pba_native.SourceReflect(ids[i], p, 0.0000001) or -1
	end
	local m = { opt = opt, samples = 0, srcMs = 0, reflMs = 0, slotRevMs = 0, audioMs = 0 }
	local runsAt4, converged
	while RealTime() - t0 < secs do
		for i, p in ipairs(positions) do if ids[i] and ids[i] > 0 then slots[i] = pba_native.SourceReflect(ids[i], p, 0.0000001) end end
		job:sleep(0.5)
		local st = pba_native.Stats()
		local t = RealTime() - t0
		if t >= 9 then -- settled: the slots have arrived and their estimates are made
			m.nSettled = (m.nSettled or 0) + 1
			m.srcMsSettled = (m.srcMsSettled or 0) + (st.srcMs or 0)
			m.reflMsSettled = (m.reflMsSettled or 0) + (st.reflMs or 0)
		end
		m.samples = m.samples + 1
		m.srcMs = m.srcMs + (st.srcMs or 0)
		m.reflMs = m.reflMs + (st.reflMs or 0)
		m.slotRevMs = math.max(m.slotRevMs, st.slotRevMs or 0)
		m.audioMs = m.audioMs + (st.audioAvgMs or 0)
		if not runsAt4 and t >= 4 then runsAt4 = (st.slotRevRuns or 0) - (st0.slotRevRuns or 0) end
		if not converged and opt >= 0.5 and not C.noPoll then
			local n, ok = 0, 0
			for _, r in ipairs(pba_native.SlotReverbTimes()) do
				if r.kind == "src" then n = n + 1 if r.long and r.n >= 4 then ok = ok + 1 end end
			end
			if n >= nSlots and ok == n then converged = t end
		end
	end
	local st1 = pba_native.Stats()
	m.srcMs, m.reflMs, m.audioMs = m.srcMs / m.samples, m.reflMs / m.samples, m.audioMs / m.samples
	if m.nSettled then m.srcMsSettled, m.reflMsSettled = m.srcMsSettled / m.nSettled, m.reflMsSettled / m.nSettled end
	m.estimates = (st1.slotRevRuns or 0) - (st0.slotRevRuns or 0)
	m.estimatesFirst4s = runsAt4
	m.estimatesAfter = m.estimates - (runsAt4 or 0)
	m.convergedAfter = converged
	m.srcSlots = st1.srcSlots
	for _, id in ipairs(ids) do pba_native.StopVoice(id) end
	job:sleep(1.5)
	return m
end

local saved = GetConVar("pba_native_source_long_rt"):GetString()
local ok, err = pcall(function() for _, o in ipairs(C.opts or { 0, 1 }) do res.opts[#res.opts + 1] = run(o) end end)
if not ok then res.err = tostring(err) end
RunConsoleCommand("pba_native_source_long_rt", saved)
return res
