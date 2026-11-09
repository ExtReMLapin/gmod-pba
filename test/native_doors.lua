-- Doors in the Steam Audio scene (client lua_job, pba_tworooms, native backend loaded): the direct
-- line through the doorway must be occluded by the closed door and clear once it is open.
-- The door is closed then opened here (pba_demo tworooms_closed / tworooms_open, server side), and each
-- state is measured once the door has finished moving (pba.Doors fraction). Ends with the door OPEN.
-- Returns { pass, doors, closed = { occlusion, tm }, open = {...} }: pass = closed occlusion < 0.1 and
-- open occlusion > 0.9 (Steam Audio occlusion: 1 = clear line, 0 = fully blocked).
local N, NA = pba.Native, pba_native
if game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms" } end
if not (N and N.ready and NA and NA.Direct) then return { pass = false, err = "native backend not loaded (pba_native 1)" } end
local door
for _, e in ipairs(ents.FindByClass("prop_door_rotating")) do door = e break end
if not door then for _, e in ipairs(ents.FindByClass("func_door*")) do door = e break end end
if not door then return { pass = false, err = "no door on the map" } end
local function frac()
	local s = pba.Doors and pba.Doors.byEnt and pba.Doors.byEnt[door:EntIndex()]
	return s and s.frac
end
-- waits until the door stands still at the wanted end (fraction networked by pba.Doors), then syncs
local function settle(wantOpen)
	job:wait(function()
		local f = frac()
		return f ~= nil and (wantOpen and f >= 0.98 or not wantOpen and f <= 0.02)
	end, 6)
	job:sleep(0.4)
	N.SyncDoors()
	job:sleep(0.2)
	return frac()
end
local c = door:WorldSpaceCenter()
-- the line crossing the door leaf: along the leaf's thinnest axis
local mn, mx = door:OBBMins(), door:OBBMaxs()
local size = mx - mn
local axis = size.x < size.y and door:GetForward() or door:GetRight()
local S, L = c + axis * 64, c - axis * 64
local function occl() local r = NA.Direct({ S }, L, 4) return r[1].occlusion, r[1].tm end
RunConsoleCommand("pba_demo", "tworooms_closed")
local closedF = settle(false)
local closedO, closedT = occl()
local nDoors = table.Count(N.doors)
RunConsoleCommand("pba_demo", "stop")
-- open the door from the server side through the demo scenario
RunConsoleCommand("pba_demo", "tworooms_open")
local openF = settle(true)
local openO, openT = occl()
RunConsoleCommand("pba_demo", "stop")
return { doors = nDoors, closed = { occlusion = closedO, tm = closedT, frac = closedF },
	open = { occlusion = openO, tm = openT, frac = openF },
	pass = nDoors > 0 and closedO ~= nil and openO ~= nil and closedO < 0.1 and openO > 0.9 }
