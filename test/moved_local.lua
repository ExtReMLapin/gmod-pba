-- A mover near the listener but away from a sound's path no longer re-evaluates that sound (pba_native_moved_local).
-- Client lua_job, pba_tworooms, native module ready; moved_local_sv.lua (args.where "far" or "across") started on the
-- server first. N.SyncDoors emptied the whole path cache whenever a door, mover or prop moved within 1024 u of the
-- listener: every continuous sound was re-evaluated at every 0.1 s sync while anything moved nearby (d3_breen_01,
-- the listener still, two lifts 650 u off: 10 invalidations and 39 far evaluations a second). Now the invalidation
-- covers the region the object swept: a cached path, or a sound whose source-listener box (plus a margin) it does
-- not touch, is kept.
-- A loop (spin_loop.wav, client CreateSound) plays at (100, 250, 40), the player at (100, 100). Over 5 s:
--   far    (the leaf travels 330 u off that line): the loop is re-evaluated at most MAX_FAR times (reeval_max_s: 1 s),
--          and the native sync did not empty the whole cache;
--   across (the leaf travels 60 u beside the line): at least MIN_ACROSS re-evaluations (as often as before).
-- Not vacuous: the leaf is in the native scene and was sent (DynamicMove) at least 20 times.
local A = pba
local N, LP, P = A.Native, A.Loops, A.Paths
local where = args and args.where or "far"
local MAX_FAR, MIN_ACROSS = 8, 12
if game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms" } end
if not (N and N.ready and pba_native and pba_native.DynamicMove) then return { pass = false, err = "needs the native module ready" } end
local door
job:wait(function()
	for _, e in ipairs(ents.FindByClass("prop_door_rotating")) do
		if e:GetModel() == "models/props_c17/door01_left.mdl" and e:GetPos().x ~= 520 and N.doors[e:EntIndex()] then door = e return true end
	end
end, 10)
if not door then return { pass = false, err = "the moving leaf never entered the native scene" } end
local NAME = "ambient/machines/spin_loop.wav"
local src = ClientsideModel("models/props_junk/popcan01a.mdl", RENDERGROUP_OTHER)
src:SetPos(Vector(100, 250, 40))
local patch = CreateSound(src, NAME)
patch:Play()
local m
job:wait(function()
	for _, x in pairs(LP.mirrors) do if x.client and x.ent == src and x.name == NAME then m = x return true end end
end, 3)
if not m then patch:Stop() src:Remove() return { pass = false, err = "no mirror for the loop" } end
job:sleep(2)
local id = door:EntIndex()
local sends, full, fullFromSync = 0, 0, 0
local origMove, origInv = pba_native.DynamicMove, P.InvalidateCache
pba_native.DynamicMove = function(i, ...)
	if i == id then sends = sends + 1 end
	return origMove(i, ...)
end
P.InvalidateCache = function(...)
	full = full + 1
	local info = debug.getinfo(2, "S")
	if info and info.short_src:find("cl_native", 1, true) then fullFromSync = fullFromSync + 1 end
	return origInv(...)
end
local n0 = m.reeval and m.reeval.n or 0
job:sleep(5)
pba_native.DynamicMove, P.InvalidateCache = origMove, origInv
local reevals = (m.reeval and m.reeval.n or 0) - n0
patch:Stop()
src:Remove()
local pass
if where == "far" then pass = reevals <= MAX_FAR and fullFromSync == 0 else pass = reevals >= MIN_ACROSS end
pass = pass and sends >= 20
return { pass = pass, where = where, reevals = reevals, sends = sends, fullInvalidations = full, fromSync = fullFromSync,
	option = A.cfg.native_moved_local, bounds = where == "far" and ("<= " .. MAX_FAR) or (">= " .. MIN_ACROSS) }
