-- pba_native_prewarm_npc_weapons (client lua_job, native module loaded, pba_native_own on or not: NPC shots are
-- other sources' sounds, played by the module in every mode). The first play of a sound not decoded yet goes to
-- the engine (pba_native_predecode): the first shot of each NPC weapon (Combine SMG1/AR2/shotgun, Metropolice
-- pistol) sounded different from the next ones (sharper, no HRTF nor reverb). The NPC sound files of the
-- weapons NPCs hold (the *_npc entries of the weapon script's SoundData block) are decoded ahead as soon as
-- such an NPC exists (map load, spawn). The file list is read here from the real script, independently of
-- the addon's own parser.
-- Run by the battery step of the same name, in phases (the file reads PHASE, CLASS and OPT put before it):
--   PHASE "pre":  native rendering was just restarted (the module dropped its sounds) and the NPCs removed:
--                 the NPC files of four weapon classes are listed; the ones neither decoded nor decoding (some
--                 are shared with the player's own weapons, which the player's prewarm decodes) are kept in
--                 PBA_NPC_TEST_FILES, at least one per class;
--   PHASE "post": the server just spawned an NPC holding CLASS: with OPT 1 every kept file of CLASS is decoded
--                 within 8 s, before any shot (N.EnsureSound answers true, not "pending"); with OPT 0 none is
--                 decoded 4 s later (the first shot is the engine's: the test has teeth).
local A, N, NA = pba, pba.Native, pba_native
if not (N and N.ready and N.render and NA and NA.LoadSoundAsync) then
	return { pass = false, err = "native module not loaded" }
end
local CLASSES = { "weapon_smg1", "weapon_ar2", "weapon_shotgun", "weapon_pistol" }
-- the NPC wave files of a weapon class, read from its script (clean names, each once)
local function npcFiles(class)
	local text = file.Read("scripts/" .. class .. ".txt", "GAME") or ""
	text = string.gsub(text, "//[^\r\n]*", "")
	local out, seen = {}, {}
	for k, v in string.gmatch(text, "\"([^\"]*)\"%s*\"([^\"]*)\"") do
		if string.lower(string.sub(k, -4)) == "_npc" and v ~= "" then
			local p = sound.GetProperties(v)
			local w = p and p.sound
			if type(w) == "string" then w = { w } end
			for _, f in ipairs(w or {}) do
				local n = string.lower(A.SoundFile(f))
				if n ~= "" and not seen[n] then seen[n] = true out[#out + 1] = n end
			end
		end
	end
	return out
end
local function state(files)
	local dec, pend = 0, 0
	for _, f in ipairs(files) do
		if NA.HasSound(f) then dec = dec + 1 elseif NA.SoundPending(f) then pend = pend + 1 end
	end
	return dec, pend
end
if PHASE == "pre" then
	local res, fails = { files = {} }, {}
	PBA_NPC_TEST_FILES = {}
	-- the other prewarms (the map load list, the player's weapons) finish first: they decode shared files
	job:wait(function()
		local q = N.wpnQueue
		if q and #q > 0 then return false end
		for m in pairs(N.wpnInflight or {}) do if NA.SoundPending(m) then return false end end
		return N.prewarm == nil or N.prewarm.done
	end, 30)
	job:sleep(1)
	for _, c in ipairs(CLASSES) do
		local files = npcFiles(c)
		local dec, pend = state(files)
		local keep = {}
		for _, f in ipairs(files) do
			if not NA.HasSound(f) and not NA.SoundPending(f) then keep[#keep + 1] = f end
		end
		PBA_NPC_TEST_FILES[c] = keep
		res.files[c] = #files .. " files, " .. dec .. " decoded, " .. pend .. " pending, " .. #keep .. " kept"
		if #files < 2 then fails[#fails + 1] = c .. ": " .. #files .. " NPC files listed" end
		if #keep < 1 then fails[#fails + 1] = c .. ": every NPC file already decoded or decoding" end
	end
	local npcs = 0
	for _, e in ipairs(ents.GetAll()) do if e:IsNPC() then npcs = npcs + 1 end end
	res.npcs = npcs
	if npcs > 0 then fails[#fails + 1] = "NPCs are still there" end
	res.fails = fails
	res.pass = #fails == 0
	return res
end
-- "post"
local files = PBA_NPC_TEST_FILES and PBA_NPC_TEST_FILES[CLASS] or {}
if #files < 1 then return { pass = false, err = CLASS .. ": no file kept by the pre phase" } end
local res = { class = CLASS, opt = OPT, n = #files }
if OPT == 1 then
	job:wait(function() local d = state(files) return d == #files end, 8)
	local dec, pend = state(files)
	res.decoded, res.pending = dec, pend
	local notNow = 0
	for _, f in ipairs(files) do
		local ok = N.EnsureSound(f)
		if not ok then notNow = notNow + 1 end
	end
	res.notReadyAtFirstShot = notNow
	res.pass = dec == #files and notNow == 0
else
	job:sleep(4)
	local dec, pend = state(files)
	res.decoded, res.pending = dec, pend
	res.pass = dec == 0 and pend == 0
end
return res
