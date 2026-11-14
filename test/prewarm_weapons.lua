-- pba_native_prewarm_weapons (client lua_job, native module loaded, pba_native_own on). With the module playing
-- the player's own sounds, the first play of a sound not decoded yet goes to the engine (pba_native_predecode):
-- the first shot of a weapon after a map load sounded different. The sound files of the weapons he holds are
-- decoded ahead as soon as he has them (map load, pickup, give).
-- Run by the battery step of the same name, in phases (the file reads PHASE, CLASS and OPT put before it):
--   PHASE "pre":  native rendering was just restarted (the module dropped its sounds) and the weapons stripped:
--                 the weapon files of weapon_smg1 and weapon_pistol are listed (N.WeaponSoundFiles: the script's
--                 sounds, more than one each) and none is decoded nor decoding;
--   PHASE "post": the server just gave CLASS: with OPT 1 every file of CLASS is decoded within 8 s, before any
--                 shot (N.EnsureSound answers true, not "pending": the first shot is the module's); with OPT 0 none
--                 is decoded 4 s later (the first shot is the engine's: the test has teeth).
local A, N, NA = pba, pba.Native, pba_native
if not (N and N.ready and N.render and NA and NA.LoadSoundAsync and N.WeaponSoundFiles) then
	return { pass = false, err = "native module not loaded or no N.WeaponSoundFiles" }
end
if not A.NativeOwn() then return { pass = false, err = "pba_native_own is not active" } end
local CLASSES = { "weapon_smg1", "weapon_pistol" }
local function state(files)
	local dec, pend = 0, 0
	for _, f in ipairs(files) do
		if NA.HasSound(f) then dec = dec + 1 elseif NA.SoundPending(f) then pend = pend + 1 end
	end
	return dec, pend
end
if PHASE == "pre" then
	local res, fails = { files = {} }, {}
	for _, c in ipairs(CLASSES) do
		local files = N.WeaponSoundFiles(c)
		local dec, pend = state(files)
		res.files[c] = #files .. " files, " .. dec .. " decoded, " .. pend .. " pending"
		if #files < 2 then fails[#fails + 1] = c .. ": " .. #files .. " files listed" end
		if dec + pend > 0 then fails[#fails + 1] = c .. ": already decoded or decoding" end
	end
	res.weaponsHeld = #LocalPlayer():GetWeapons()
	if res.weaponsHeld > 0 then fails[#fails + 1] = "the weapons are not stripped" end
	res.fails = fails
	res.pass = #fails == 0
	return res
end
-- "post"
local files = N.WeaponSoundFiles(CLASS)
if #files < 2 then return { pass = false, err = CLASS .. ": " .. #files .. " files listed" } end
local res = { class = CLASS, opt = OPT, n = #files }
if OPT == 1 then
	job:wait(function() local d = state(files) return d == #files end, 8)
	local dec, pend = state(files)
	res.decoded, res.pending = dec, pend
	-- the first shot: every file is ready for the module at once (no worker decode to wait for)
	local notNow = 0
	for _, f in ipairs(files) do
		local ok, _, why = N.EnsureSound(f)
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
