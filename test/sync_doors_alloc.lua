-- Garbage of the native door sync at rest (client lua_job, pba_tworooms, native module ready; sync_doors_alloc_sv.lua
-- started on the server first: 30 big props round the player, the first moved 100 u 8 s later, then every 4 s).
-- N.SyncDoors runs 10 times a second. It made a new ents.GetAll() list, a new `seen` table and three closures per call,
-- and read the position and angles (two userdata) of every door, mover and prop in the scene at every call: 11 KB per
-- call on gm_converted_apartment (55 objects), 120-220 KB/s on prop maps, all of it for objects that do not move.
-- Now (pba_native_props_still): a prop still for STILL syncs is looked at once every ROUND syncs (in turns), doors and
-- movers at every sync; no list, table or closure per call.
-- Pass: the median garbage of one sync over 60 syncs (in a timer, the listener and the props still) is under
-- MAX_KB, and the prop the server moves is sent to the module (DynamicMove) at most MAX_LAG_S after the client saw it
-- move (it was still for 4 s or more: the slowest case).
local A = pba
local N = A.Native
local MAX_KB, MAX_LAG_S = 2, 1.3
if game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms" } end
if not (N and N.ready and pba_native and pba_native.DynamicMove and N.SyncDoors) then
	return { pass = false, err = "needs the native module ready" }
end
local function propsIn()
	local n = 0
	for _, d in pairs(N.doors) do if d.prop then n = n + 1 end end
	return n
end
job:wait(function() return propsIn() >= 20 end, 15)
local nProps = propsIn()
job:sleep(2)
-- garbage per sync, measured from a timer (outside this job's coroutine)
local res
timer.Simple(0, function()
	local kb, ms = {}, {}
	collectgarbage("stop") -- (a collector step inside a call gives a negative count)
	for i = 1, 60 do
		local c0 = collectgarbage("count")
		local t0 = SysTime()
		N.SyncDoors()
		ms[i] = (SysTime() - t0) * 1000
		kb[i] = collectgarbage("count") - c0
	end
	collectgarbage("restart")
	table.sort(kb) table.sort(ms)
	res = { kb = kb[30], ms = ms[30] }
end)
job:wait(function() return res end, 5)
-- the prop the server moves: positions polled every 0.05 s, the send of that id stamped
local pos = {}
for id, d in pairs(N.doors) do if d.prop and IsValid(d.ent) then pos[id] = d.ent:GetPos() end end
-- (sends stamped by id; the move is seen by a 0.05 s poll, which may come after the send: a send up to one poll
-- before it counts, at lag 0)
local seenAt, sends, movedId = nil, {}, nil
local origMove = pba_native.DynamicMove
pba_native.DynamicMove = function(id, ...)
	sends[id] = sends[id] or {}
	table.insert(sends[id], SysTime())
	return origMove(id, ...)
end
timer.Create("pba_test_sync_poll", 0.05, 0, function()
	if seenAt then return end
	for id, p in pairs(pos) do
		local d = N.doors[id]
		if d and IsValid(d.ent) and d.ent:GetPos():DistToSqr(p) > 1 then
			seenAt, movedId = SysTime(), id
			return
		end
	end
end)
local function sentAfter()
	for _, t in ipairs(movedId and sends[movedId] or {}) do
		if t >= seenAt - 0.06 then return math.max(t - seenAt, 0) end
	end
end
job:wait(function() return movedId and sentAfter() end, 16)
timer.Remove("pba_test_sync_poll")
pba_native.DynamicMove = origMove
local lag = movedId and sentAfter() or nil
local pass = nProps >= 20 and res.kb < MAX_KB and lag ~= nil and lag <= MAX_LAG_S
return { pass = pass, props = nProps, kbPerSync = math.Round(res.kb, 2), msPerSync = math.Round(res.ms, 3), lagS = lag and math.Round(lag, 2),
	bounds = { kb = MAX_KB, lag = MAX_LAG_S }, option = A.cfg.native_props_still }
