-- Real map: env_fire burning from map load (spawnflag 4 "start on"; d1_town_01 has one at
-- 1310 177 -3638, flags 47 = infinite). Why: its Fire.Plasma loop (ambient/fire/firebig.wav) may be
-- started during the map's entity spawn, before pba's hooks are installed (InitPostEntity); the
-- take-over at hook install only restarts ambient_generic entities, so such a fire would stay
-- vanilla and cross every wall.
-- Map: d1_town_01, fresh load (any map with start-on env_fire works). Realm: server (lua_job).
-- Expected: every start-on env_fire has a mirror of firebig.wav within 256 u of it.
-- Returns { pass, fires, mirrored, missing = { origins } }.
local WAV = "ambient/fire/firebig.wav"
job:sleep(1.5) -- AdoptAmbients (next tick after the hooks) and two passes of the loops timer
local fires, mirrored, missing = 0, 0, {}
for _, f in ipairs(ents.FindByClass("env_fire")) do
	if bit.band(f:GetSpawnFlags(), 4) ~= 0 and f:GetInternalVariable("m_bEnabled") ~= false then
		fires = fires + 1
		local found = false
		for _, l in pairs(pba.Loops.active) do
			local p = IsValid(l.ent) and l.ent:GetPos() or l.pos
			if string.lower(pba.SoundFile(l.name)) == WAV and p and p:DistToSqr(f:GetPos()) < 256 * 256 then found = true break end
		end
		if found then mirrored = mirrored + 1 else missing[#missing + 1] = tostring(f:GetPos()) end
	end
end
local res = { fires = fires, mirrored = mirrored, missing = missing, hooks = pba.hooksInstalled,
	expected = "mirrored = fires (> 0)" }
if fires == 0 then
	res.pass = nil
	res.note = "no start-on env_fire on this map: inconclusive"
else
	res.pass = mirrored == fires
end
return res
