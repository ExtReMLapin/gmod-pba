-- scene_cancel, client half 2 (after scene_cancel_next.lua): the cancelled scene's line stopped; its
-- relayed copy too. Pass: a copy was live before, none 0.4 s after the cancel.
local idx = GetGlobalInt("pba_test_sc_idx")
job:sleep(0.4)
local n, now = 0, RealTime()
for _, h in ipairs(pba.emitted[idx] or {}) do
	if not h.cancelled and now <= h.tEnd then n = n + 1 end
end
local before = pba._scLive or 0
pba._scLive = nil
return { pass = before >= 1 and n == 0, before = before, live = n, native = pba.Native and pba.Native.render or false }
