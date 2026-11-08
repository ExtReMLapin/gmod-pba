-- Doors in the Steam Audio scene (client lua_job, pba_tworooms, native backend loaded): the direct
-- line through the doorway must be occluded by the closed door and clear once it is open.
local N, NA = pba.Native, pba_native
local door
for _, e in ipairs(ents.FindByClass("prop_door_rotating")) do door = e break end
if not door then for _, e in ipairs(ents.FindByClass("func_door*")) do door = e break end end
if not door then return "no door" end
local function settle() job:sleep(0.6) N.SyncDoors() job:sleep(0.2) end
local c = door:WorldSpaceCenter()
-- the line crossing the door leaf: along the leaf's thinnest axis
local mn, mx = door:OBBMins(), door:OBBMaxs()
local size = mx - mn
local axis = size.x < size.y and door:GetForward() or door:GetRight()
local S, L = c + axis * 64, c - axis * 64
local function occl() local r = NA.Direct({ S }, L, 4) return r[1].occlusion, r[1].tm end
RunConsoleCommand("pba_demo", "tworooms_closed")
settle()
local closedO, closedT = occl()
local nDoors = table.Count(N.doors)
RunConsoleCommand("pba_demo", "stop")
-- open the door from the server side through the demo scenario
RunConsoleCommand("pba_demo", "tworooms_open")
job:sleep(2.5)
N.SyncDoors()
job:sleep(0.2)
local openO, openT = occl()
RunConsoleCommand("pba_demo", "stop")
return { doors = nDoors, closed = { occlusion = closedO, tm = closedT }, open = { occlusion = openO, tm = openT },
	pass = nDoors > 0 and closedO < 0.5 and openO > closedO + 0.3 }
