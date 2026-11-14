-- pba_native_predecode: the map load prewarm walks ents.GetAll() over several frames (a yield per entity); an
-- entity removed between two frames must be skipped, not end the whole prewarm on "Tried to use a NULL entity!"
-- (seen on d3_citadel_04). Client lua_job, any map: three client props, the first yield removes the last one,
-- N.PrewarmList must run to its end and still return the explosion script's waves.
local N = pba and pba.Native
if not (N and N.PrewarmList) then return { pass = false, err = "no N.PrewarmList" } end
local props = {}
for i = 1, 3 do
	local e = ents.CreateClientProp("models/props_c17/oildrum001.mdl")
	e:SetPos(LocalPlayer():GetPos() + Vector(100 * i, 0, 0))
	e:Spawn()
	props[i] = e
end
-- the first yield of the entity walk (after one per sound script): the snapshot is taken, the prop goes
local removed, calls, at = false, 0, #(sound.GetTable() or {}) + 1
local function yield()
	calls = calls + 1
	if calls == at and IsValid(props[3]) then props[3]:Remove() removed = true job:frames(2) end -- (a client entity goes at the frame's end)
end
local ok, out = pcall(N.PrewarmList, yield)
for _, e in ipairs(props) do if IsValid(e) then e:Remove() end end
local expl = sound.GetProperties("BaseExplosionEffect.Sound")
local ew = expl and expl.sound
if isstring(ew) then ew = { ew } end
local found = 0
if ok then
	local set = {}
	for _, n in ipairs(out) do set[n] = true end
	for _, w in ipairs(ew or {}) do if set[string.lower(pba.SoundFile(w))] then found = found + 1 end end
end
return { pass = ok and removed and found > 0 and found == #(ew or {}), removed = removed, err = not ok and tostring(out) or nil,
	n = ok and #out or nil, explosionWaves = found .. "/" .. #(ew or {}) }
