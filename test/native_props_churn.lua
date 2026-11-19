-- pba_native_props_rank_keep (client lua_job, native module ready, after native_props_add_setup.lua: 30 big props round
-- the player). More props than pba_native_props_max: every 2 s the ranking keeps the cap's most relevant ones and takes
-- the others out; with pba_native_props_add_ms the winners not in yet enter over the next syncs. Between two rankings,
-- the fill loop (room under the cap: in at once) put in whatever prop came first in ents.GetAll(), losers included, which
-- the next ranking took out again: props went in and out every 2 s (each one a DynamicAdd and a scene commit on the
-- game's thread) with nothing moving. With the option, the props entering after a ranking are its winners only.
-- Per option value (0, then 1): cap 10, add budget 0.3 ms (about one prop per sync), props switched off then on; after
-- 5 s to settle, the DynamicAdd / DynamicRemove calls of the props over 8 s, listener and props still.
-- Pass: option 1: no add or remove once settled, 10 props in; option 0 (the control, the former way): churn.
local A = pba
local N = A.Native
if not (N and N.ready and pba_native and pba_native.DynamicAdd and N.SyncDoors) then
	return { pass = false, err = "needs the native module ready" }
end
local function propsIn()
	local n = 0
	for _, d in pairs(N.doors) do if d.prop then n = n + 1 end end
	return n
end
local origAdd, origRemove = pba_native.DynamicAdd, pba_native.DynamicRemove
local adds, removes, counting = 0, 0, false
pba_native.DynamicAdd = function(...)
	if counting then adds = adds + 1 end
	return origAdd(...)
end
pba_native.DynamicRemove = function(id, ...)
	if counting and N.doors[id] and N.doors[id].prop then removes = removes + 1 end
	return origRemove(id, ...)
end
local function run(v)
	A.SetOverride("native_props_rank_keep", v)
	A.SetOverride("native_props_max", 10)
	A.SetOverride("native_props_add_ms", 0.3)
	A.SetOverride("native_props", 0)
	job:wait(function() return propsIn() == 0 end, 5)
	job:sleep(1.2)
	N.propCommitT, N.propRankT, N.propWinners = 0, 0, nil
	A.SetOverride("native_props", nil)
	job:sleep(5)
	adds, removes, counting = 0, 0, true
	job:sleep(8)
	counting = false
	return { adds = adds, removes = removes, propsIn = propsIn() }
end
local ok, r0, r1 = pcall(function() return run(0), run(1) end)
pba_native.DynamicAdd, pba_native.DynamicRemove = origAdd, origRemove
for _, k in ipairs({ "native_props_rank_keep", "native_props_max", "native_props_add_ms", "native_props" }) do A.SetOverride(k, nil) end
if not ok then return { pass = false, err = tostring(r0) } end
local pass = r1.adds == 0 and r1.removes == 0 and r1.propsIn == 10 and (r0.adds + r0.removes) > 0
return { pass = pass, opt0 = r0, opt1 = r1, hasOption = A.cfg.native_props_rank_keep ~= nil }
