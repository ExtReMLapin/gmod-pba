-- channel_cut, client half 2 (after channel_cut_next.lua): a new sound left to the engine on the
-- line's channel cut the line; its relayed copy is gone too (it was live in channel_cut_mid.lua).
-- Pass: a copy was live before, none 0.3 s after the new sound.
local idx = GetGlobalInt("pba_test_cc_idx")
job:sleep(0.3)
local n, now = 0, RealTime()
for _, h in ipairs(pba.emitted[idx] or {}) do
	if not h.cancelled and now <= h.tEnd then n = n + 1 end
end
local before = pba._ccLive or 0
pba._ccLive = nil
return { pass = before >= 1 and n == 0, before = before, live = n, native = pba.Native and pba.Native.render or false }
