-- Real map: the "train_idle" ambient_generic of d1_trainstation_01 (Trainyard.train_idle, a looping
-- ambient/machines/train_idle.wav, active at map load) has SourceEntityName "intro_train_1", a
-- func_tracktrain. Why: the ambient is taken over at map load (AdoptAmbients) on the train's index;
-- the train is a MOVETYPE_PUSH brush standing still (or stopping at the station), and the
-- moving-brush rule stops a pusher's mirror once it is still: the idle hum of the train would go
-- silent although the ambient still plays.
-- Map: d1_trainstation_01, fresh load. Realm: server (lua_job, up to ~70 s).
-- Expected: while the ambient is active, one mirror of train_idle.wav on the ambient or the train,
-- checked once the train has been still for 2 s.
-- Returns { pass, active, mirrored, trainStillFor, trainSpeed, waited }.
if game.GetMap() ~= "d1_trainstation_01" then return { pass = false, err = "needs d1_trainstation_01" } end
local amb = ents.FindByName("train_idle")[1]
local train = ents.FindByName("intro_train_1")[1]
if not IsValid(amb) or not IsValid(train) then return { pass = false, err = "train_idle / intro_train_1 not found" } end
local WAV = "ambient/machines/train_idle.wav"
local function count()
	local n = 0
	for _, l in pairs(pba.Loops.active) do
		if (l.ent == amb or l.ent == train) and string.lower(pba.SoundFile(l.name)) == WAV then n = n + 1 end
	end
	return n
end
local function still() return train:GetVelocity():LengthSqr() < 1 and train:GetLocalAngularVelocity():IsZero() end
-- the train may be riding in (map intro): wait until it has stood still for 2 s
local t0, stillSince = CurTime(), nil
job:wait(function()
	if still() then stillSince = stillSince or CurTime() else stillSince = nil end
	return stillSince ~= nil and CurTime() - stillSince >= 2
end, 70)
job:sleep(1) -- two passes of the loops timer
local active = amb:GetInternalVariable("m_fActive")
local mirrored = count()
local res = { active = active, mirrored = mirrored, trainStillFor = stillSince and math.Round(CurTime() - stillSince, 1) or 0,
	trainSpeed = math.Round(train:GetVelocity():Length(), 1), waited = math.Round(CurTime() - t0, 1),
	expected = "active = true and mirrored = 1" }
if not active then
	res.pass = nil -- the ambient was turned off by the map: nothing to check
	res.note = "train_idle not active: inconclusive"
else
	res.pass = mirrored == 1
end
return res
