-- game.CleanUpMap() while map loops are followed (d1_town_01: looping ambient_generic and a burning
-- env_fire from map load). Why: cleanup removes the map entities and spawns them again; the new
-- ambients start in Activate (hooks installed now), their entity index may be the one of the removed
-- entity, and a loop entry still keyed on that index but holding the removed entity is dropped by
-- the loops timer along with the new sound (the index-keyed entry keeps its old entity): the
-- ambience would fall silent after a cleanup (admin "clean up map", gamemode round restart).
-- Map: d1_town_01 (any map with active looping ambients). Realm: server (lua_job). Runs last on the
-- map (the map is reset).
-- Expected: after cleanup, every active looping ambient_generic (not "play everywhere") is followed
-- again, and no followed loop holds a removed entity.
-- Returns { pass, before = { active, mirrored }, after = { active, mirrored }, stale }.
local function waveOf(name)
	local props = name ~= "" and name:sub(1, 1) ~= "!" and sound.GetProperties(name)
	if not props then return name end
	local w = props.sound
	return istable(w) and (w[1] or "") or w or name
end
local function measure()
	local active, mirrored, missing = 0, 0, {}
	for _, e in ipairs(ents.FindByClass("ambient_generic")) do
		local wav = waveOf(e:GetInternalVariable("message") or "")
		if e:GetInternalVariable("m_fActive") and bit.band(e:GetSpawnFlags(), 1) == 0 and wav ~= "" and wav:sub(1, 1) ~= "!"
			and pba.IsLooping(wav) then
			active = active + 1
			local src = e:GetInternalVariable("m_hSoundSource")
			local found = false
			for _, l in pairs(pba.Loops.active) do
				if l.ent == e or (IsValid(src) and l.ent == src) then found = true break end
			end
			if found then mirrored = mirrored + 1 else missing[#missing + 1] = wav end
		end
	end
	local stale = 0
	for _, l in pairs(pba.Loops.active) do if l.idx ~= 0 and not IsValid(l.ent) then stale = stale + 1 end end
	return { active = active, mirrored = mirrored, missing = missing, stale = stale, followed = table.Count(pba.Loops.active) }
end
job:sleep(1)
local before = measure()
game.CleanUpMap()
job:sleep(3) -- respawn, Activate, several passes of the loops timer
local after = measure()
local res = { before = before, after = after, expected = "after.mirrored = after.active (> 0), after.stale = 0" }
if after.active == 0 then
	res.pass = nil
	res.note = "no active looping ambient after cleanup: inconclusive"
else
	res.pass = after.mirrored == after.active and after.stale == 0
end
return res
