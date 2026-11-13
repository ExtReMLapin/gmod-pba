-- scene_cancel, client half 1 (after scene_cancel_setup.lua): the relayed copy of the scene's line plays.
local idx = GetGlobalInt("pba_test_sc_idx")
local n, now = 0, RealTime()
for _, h in ipairs(pba.emitted[idx] or {}) do
	if not h.cancelled and now <= h.tEnd then n = n + 1 end
end
pba._scLive = n
return { pass = n >= 1, live = n }
