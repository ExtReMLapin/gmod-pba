-- Looping ambient_generic whose SourceEntityName is a brush at rest (func_door_rotating door_s).
-- Why: the sound is emitted on the source entity's index, a MOVETYPE_PUSH brush; the moving-brush
-- rule (mirror stopped once a pusher is still) can mistake it for a finished movement loop and
-- stop the mirror while the engine copy stays suppressed: the ambient falls silent.
-- Map: pba_twodoors. Realm: server (lua_job).
-- Expected: the mirror exists 0.5 s after PlaySound and is still there 2.5 s later (ambient active).
-- Returns { pass, mirroredStart, mirroredLater, active, source }.
local NAME = "ambient/machines/spin_loop.wav" -- loop points
local door = ents.FindByName("door_s")[1]
if not IsValid(door) then return { pass = false, err = "no door_s (load pba_twodoors)" } end
util.PrecacheSound(NAME)
local amb = ents.Create("ambient_generic")
amb:SetPos(door:WorldSpaceCenter())
amb:SetKeyValue("message", NAME)
amb:SetKeyValue("radius", "1250")
amb:SetKeyValue("health", "10")
amb:SetKeyValue("pitch", "100")
amb:SetKeyValue("pitchstart", "100")
amb:SetKeyValue("spawnflags", "16") -- start silent: started below by input
amb:SetKeyValue("SourceEntityName", "door_s")
amb:SetKeyValue("targetname", "pba_test_amb_brush")
amb:Spawn()
amb:Activate()
local function count()
	local n = 0
	for _, l in pairs(pba.Loops.active) do
		if (l.ent == amb or l.ent == door) and l.name == NAME then n = n + 1 end
	end
	return n
end
local ok, res = pcall(function()
	job:sleep(0.2)
	amb:Fire("PlaySound")
	job:sleep(0.5)
	local start = count()
	job:sleep(2.5) -- several passes of the 0.5 s loops timer
	local later = count()
	return { mirroredStart = start, mirroredLater = later, active = amb:GetInternalVariable("m_fActive"),
		source = tostring((amb:GetInternalVariable("m_hSoundSource"))), doorStill = pba.Loops.MoverStill and pba.Loops.MoverStill(door) }
end)
if IsValid(amb) then amb:Fire("StopSound") end
job:sleep(0.3)
if IsValid(amb) then amb:Remove() end
if not ok then return { pass = false, err = tostring(res) } end
res.pass = res.mirroredStart == 1 and res.mirroredLater == 1
res.expected = "mirroredStart = 1, mirroredLater = 1 (the ambient still plays)"
return res
