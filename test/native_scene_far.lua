-- pba_native_scene_far_m (client lua_job, native module ready, after native_scene_far_setup.lua: a door args.id opened and
-- closed every 2 s, args.dist units from the player). Every scene commit restarts Steam Audio's accumulated reflections of
-- every source (and the source slots' listener anchor, srcAnchorMoves): a door swinging far away committed the scene at
-- every 0.1 s sync while it moved, and the reverb's averages never converged. With the option, a door farther than
-- pba_native_scene_far_m sends its move once it has rested.
-- Per option value (0, then 20 m): the door's DynamicMove calls and the module's scene commits over 8 s (4 swings).
-- Pass (args.far true, door at 40 m): option 20: at most 6 moves (one per swing, +2 for the edges of the window), option 0
-- at least 3 times as many; (args.far false, door at 5 m, the control): the same count either way.
local A = pba
local N = A.Native
if not (N and N.ready and pba_native and pba_native.DynamicMove and N.SyncDoors) then
	return { pass = false, err = "needs the native module ready" }
end
local args = args or {}
-- the door: args.id, else the rotating door nearest to args.dist units from the player (the battery passes no id)
local id = args.id
if not id then
	local best
	for _, e in ipairs(ents.FindByClass("prop_door_rotating")) do
		local err = math.abs(e:GetPos():Distance(LocalPlayer():GetPos()) - (args.dist or 2100))
		if not best or err < best then best, id = err, e:EntIndex() end
	end
end
if not N.doors[id] then job:wait(function() return N.doors[id] ~= nil end, 3) end
if not N.doors[id] then return { pass = false, err = "the door never entered the native scene" } end
local origMove = pba_native.DynamicMove
local moves, counting = 0, false
pba_native.DynamicMove = function(i, ...)
	if counting and i == id then moves = moves + 1 end
	return origMove(i, ...)
end
local function commits()
	local st = pba_native.Stats()
	return st.commits or st.sceneCommits or 0
end
local function run(v)
	A.SetOverride("native_scene_far_m", v)
	job:sleep(1)
	moves, counting = 0, true
	local c0 = commits()
	job:sleep(8)
	counting = false
	return { moves = moves, commits = commits() - c0 }
end
local ok, r0, r1 = pcall(function() return run(0), run(20) end)
pba_native.DynamicMove = origMove
A.SetOverride("native_scene_far_m", nil)
if not ok then return { pass = false, err = tostring(r0) } end
local pass
if args.far then pass = r1.moves <= 6 and r0.moves >= 3 * math.max(r1.moves, 1)
else pass = r0.moves >= 8 and math.abs(r1.moves - r0.moves) <= 3 end
return { pass = pass, far = args.far, opt0 = r0, opt20 = r1, hasOption = A.cfg.native_scene_far_m ~= nil }
