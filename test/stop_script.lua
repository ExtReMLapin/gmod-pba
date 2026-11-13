-- stop_script, client half 2 (after stop_script_next.lua): StopSound by script name stopped the relayed
-- copy (live in stop_script_mid.lua) and the loop's mirror.
-- Pass: a copy was live before; 0.3 s after the StopSound no copy and no mirror of the prop are left.
local idx = GetGlobalInt("pba_test_ss_idx")
job:sleep(0.3)
local n, now = 0, RealTime()
for _, h in ipairs(pba.emitted[idx] or {}) do
	if not h.cancelled and now <= h.tEnd then n = n + 1 end
end
local mirrors = 0
for _, m in pairs(pba.Loops.mirrors or {}) do if m.idx == idx then mirrors = mirrors + 1 end end
local before = pba._ssLive or 0
pba._ssLive = nil
return { pass = before >= 1 and n == 0 and mirrors == 0, before = before, live = n, mirrors = mirrors }
