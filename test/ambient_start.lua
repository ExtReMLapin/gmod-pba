-- Looping ambient_generic already playing when the map loads (started in Activate(), before
-- pba's hooks): pba must take them over (server mirror in pba.Loops.active), else they stay
-- vanilla and cross every wall. lua_exec, server realm, right after a map load.
-- Returns { pass, active (looping, playing, audible ambient_generic), mirrored, missing = {names} }.
local active, mirrored, missing = 0, 0, {}
for _, e in ipairs(ents.FindByClass("ambient_generic")) do
	local name = e:GetInternalVariable("message") or ""
	-- a sound script: its wave (what EntityEmitSound and the mirrors carry)
	local props = name ~= "" and name:sub(1, 1) ~= "!" and sound.GetProperties(name)
	if props then
		local w = props.sound
		name = istable(w) and w[1] or w or name
	end
	local on = e:GetInternalVariable("m_fActive")
	local flags = e:GetSpawnFlags()
	local everywhere = bit.band(flags, 1) ~= 0
	if on and not everywhere and name ~= "" and name:sub(1, 1) ~= "!" and pba.IsLooping(name) then
		active = active + 1
		local found = false
		for _, l in pairs(pba.Loops.active) do
			local src = e:GetInternalVariable("m_hSoundSource")
			if l.ent == e or (IsValid(src) and l.ent == src) then found = true break end
		end
		if found then mirrored = mirrored + 1 else missing[#missing + 1] = name end
	end
end
return { pass = mirrored == active, active = active, mirrored = mirrored, missing = missing }
