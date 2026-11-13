-- stop_script, client half 1 (after stop_script_setup.lua): the relayed copy of the line is playing.
local idx = GetGlobalInt("pba_test_ss_idx")
local n, now = 0, RealTime()
for _, h in ipairs(pba.emitted[idx] or {}) do
	if not h.cancelled and now <= h.tEnd then n = n + 1 end
end
pba._ssLive = n
return { pass = n >= 1, live = n }
