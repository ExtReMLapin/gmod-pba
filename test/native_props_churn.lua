-- Prop ranking kept between two rankings (client lua_job, native module ready, after native_props_add_setup.lua: 30 big props round
-- the player). More props than pba_native_props_max: every 2 s the ranking keeps the cap's most relevant ones and takes
-- the others out; with pba_native_props_add_ms the winners not in yet enter over the next syncs. Between two rankings,
-- the fill loop (room under the cap: in at once) put in whatever prop came first in ents.GetAll(), losers included, which
-- the next ranking took out again: props went in and out every 2 s (each one a DynamicAdd and a scene commit on the
-- game's thread) with nothing moving. Now the props entering after a ranking are its winners only.
-- Cap 10, add budget 0.3 ms (about one prop per sync), props switched off then on; after 5 s to settle, the DynamicAdd /
-- DynamicRemove calls of the props over 8 s, listener and props still.
-- Pass: no add or remove once settled, 10 props in.
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
local function run()
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
local ok, r = pcall(run)
pba_native.DynamicAdd, pba_native.DynamicRemove = origAdd, origRemove
for _, k in ipairs({ "native_props_max", "native_props_add_ms", "native_props" }) do A.SetOverride(k, nil) end
if not ok then return { pass = false, err = tostring(r) } end
return { pass = r.adds == 0 and r.removes == 0 and r.propsIn == 10, run = r }
