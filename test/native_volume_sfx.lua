-- volume_sfx in native rendering (client lua_job, native rendering on; parity audit C-1). The engine scales
-- every sound it plays except voice chat by volume_sfx (its channel mixing, engine.dll), and GMod sets BASS's
-- global stream volume to volume x volume_sfx (gmod_audio.dll SetGlobalVolume, measured: GVOL_STREAM 1600 ->
-- 800 when volume_sfx goes 1 -> 0.5 at volume 0.16): game sounds and other addons' streams alike. The module
-- got only `volume`, so lowering the effects left its voices at full level.
-- The battery sets volume_sfx 0.25 from the console before this job (Lua cannot set it) and back after.
-- Pass: the master given to pba_native.SetListener over a few frames is volume x volume_sfx with
-- pba_native_volume_sfx 1, volume alone with 0 (the option off: the old behaviour).
local N = pba.Native
local NA = pba_native
if not (N and N.ready and N.render and NA) then return { pass = false, err = "native renderer not running" } end
local vol, sfx = GetConVar("volume"):GetFloat(), GetConVar("volume_sfx"):GetFloat()
if sfx > 0.9 then return { pass = false, err = "volume_sfx not lowered by the battery (" .. sfx .. ")" } end
if not system.HasFocus() and GetConVar("snd_mute_losefocus"):GetBool() then
	return { pass = false, err = "snd_mute_losefocus 1 without focus: master is 0 whatever volume_sfx" }
end
local res = { checks = {}, volume = vol, volume_sfx = sfx }
local orig = NA.SetListener
local seen
NA.SetListener = function(p, f, u, master, ...) seen = master return orig(p, f, u, master, ...) end
local function capture()
	seen = nil
	job:frames(3)
	return seen
end
local saved = GetConVar("pba_native_volume_sfx") and GetConVar("pba_native_volume_sfx"):GetString()
local ok, err = pcall(function()
	if saved then
		RunConsoleCommand("pba_native_volume_sfx", "1")
		job:wait(function() return pba.cfg.native_volume_sfx == 1 end, 5)
	end
	res.on = capture()
	res.checks.on = res.on ~= nil and math.abs(res.on - vol * sfx) < 1e-3
	if saved then
		RunConsoleCommand("pba_native_volume_sfx", "0")
		job:wait(function() return pba.cfg.native_volume_sfx == 0 end, 5)
		res.off = capture()
		res.checks.off = res.off ~= nil and math.abs(res.off - vol) < 1e-3
		RunConsoleCommand("pba_native_volume_sfx", saved)
	else
		res.checks.option = false
	end
end)
NA.SetListener = orig
if not ok then res.err = err res.pass = false return res end
res.fails = {}
for k, v in SortedPairs(res.checks) do if not v then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
