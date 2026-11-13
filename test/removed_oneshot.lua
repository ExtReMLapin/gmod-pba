-- removed_oneshot (client lua_job, right after removed_oneshot_setup.lua): the relayed copy of a line
-- whose entity was removed plays on to its end, as the engine's own sound does.
-- Pass: 0.8 s after the removal the copy is still registered and live (not stopped, before its end).
local idx = GetGlobalInt("pba_test_removed_idx")
if idx <= 0 then return { pass = false, err = "run removed_oneshot_setup.lua first" } end
job:sleep(0.8)
local n, now = 0, RealTime()
for _, h in ipairs(pba.emitted[idx] or {}) do
	if not h.cancelled and now <= h.tEnd then n = n + 1 end
end
return { pass = n >= 1, live = n, native = pba.Native and pba.Native.render or false }
