-- Watchdog dead_npc_loop and rollermines (client lua_job, pba_tworooms, after watch_dead_npc_setup.lua on the
-- server and test/watch/watchdog_cl.lua loaded in the client). A rollermine has no health at all (Health() 0 from
-- its spawn, takes damage as events only, dies by exploding and being removed): in vanilla its motor loops go
-- on after a TakeDamage(1000) as it keeps rolling (checked 2026-11-14, pba_enable 0: rmine_moveslow_loop1 volume
-- changes for seconds after). The detector judged "health <= 0" as dead: an alive rollermine's loops were
-- reported (d2_coast_05, 21 events). A fast zombie killed with pba_loops_npc_death 0 (its mirrors play on until
-- its removal) is the control: still reported.
-- Pass = the rollermine's loops mirrored and none reported; the killed zombie's reported.
local W = PBA_WATCH_CL
if not W then return { pass = false, err = "watchdog_cl.lua not loaded" } end
local rm = ents.FindByClass("npc_rollermine")[1]
local function mirrored(idx)
	for k in pairs(pba.Loops.mirrors) do
		if string.StartWith(k, idx .. ":") then return true end
	end
	return false
end
local rmMirrored = IsValid(rm) and mirrored(rm:EntIndex())
job:sleep(2.5)
local function reported(class)
	local a = W.anomalies.dead_npc_loop
	local n = 0
	for _, s in ipairs(a and a.samples or {}) do if s.class == class then n = n + 1 end end
	return n
end
local res = { rmMirrored = rmMirrored, rmReported = reported("npc_rollermine"), zReported = reported("npc_fastzombie") }
res.pass = rmMirrored and res.rmReported == 0 and res.zReported > 0
return res
