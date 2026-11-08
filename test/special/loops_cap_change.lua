-- A loop left to the engine by the pba_loops_max cap later receives a volume change (SND_CHANGE_VOL),
-- once the cap has room again. Why: Loops.Handle treats a change event with no mirror as a new loop:
-- it starts a mirror and suppresses the change, while the engine's own copy (never stopped) keeps
-- playing: the loop is heard twice, the vanilla copy through every wall. Same for any loop the
-- engine plays unknown to pba (started before the hooks, while pba was off...).
-- Map: pba_tworooms (props in room B). Realm: server (lua_job). Sets pba_loops_max 4, restores it.
-- Expected: after the change, the capped loop is either still left to the engine (no mirror) or its
-- engine copy was stopped by pba when the mirror took over (Entity:StopSound on the original).
-- Returns { pass, taken, capped, mirroredAfterChange, engineCopyStopped }.
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
ply:SetPos(Vector(256, 256, 0))
local NAME = "ambient/machines/spin_loop.wav"
local old = GetConVar("pba_loops_max"):GetString()
local props = {}
local function mirrored(e)
	for _, l in pairs(pba.Loops.active) do if l.ent == e and l.name == NAME then return true end end
	return false
end
local stops = {}
local origStop = pba.orig.EntStopSound
local ok, res = pcall(function()
	RunConsoleCommand("pba_loops_max", "4")
	job:wait(function() return pba.cfg.loops_max == 4 end, 3)
	-- loops until one is left to the engine (the cap counts every followed loop on the map)
	local taken, capped = {}, nil
	for i = 1, 8 do
		local e = ents.Create("prop_dynamic")
		e:SetModel("models/props_junk/popcan01a.mdl")
		e:SetPos(Vector(600 + 40 * i, 128, 40))
		e:Spawn()
		props[#props + 1] = e
		job:sleep(0.1)
		e:EmitSound(NAME, 75, 100, 1, CHAN_STATIC)
		job:sleep(0.1)
		if mirrored(e) then taken[#taken + 1] = e else capped = e break end
	end
	if not capped then return { err = "the cap never applied", taken = #taken } end
	-- room again: one followed loop stops
	taken[1]:StopSound(NAME)
	job:sleep(0.2)
	pba.orig.EntStopSound = function(ent, name)
		if ent == capped then stops[#stops + 1] = name end
		return origStop(ent, name)
	end
	capped:EmitSound(NAME, 75, 100, 0.5, CHAN_STATIC, SND_CHANGE_VOL)
	job:sleep(0.3)
	pba.orig.EntStopSound = origStop
	return { taken = #taken, capped = tostring(capped), mirroredAfterChange = mirrored(capped), engineCopyStopped = #stops > 0 }
end)
pba.orig.EntStopSound = origStop
RunConsoleCommand("pba_loops_max", old)
for _, e in ipairs(props) do if IsValid(e) then e:StopSound(NAME) e:Remove() end end
if not ok then return { pass = false, err = tostring(res) } end
if res.err then res.pass = nil return res end
res.pass = (not res.mirroredAfterChange) or res.engineCopyStopped
res.expected = "mirroredAfterChange = false, or engineCopyStopped = true"
return res
