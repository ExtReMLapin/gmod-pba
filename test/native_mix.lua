-- Mix groups on natively rendered sounds (client, lua_job; module with native rendering; audit C-2).
-- The engine plays every sound at its mix group's value (Default_Mix: All 0.72, Explosions 0.90...); a
-- sound the module plays skipped it, so it came out 2.9 dB louder than the engine's (more for bullet hits
-- 0.67, the HEV 0.56) and jumped in level when it moved from the engine to the module.
-- A clear sound 200 u ahead is processed twice (A.Process, as relayed), pba_native_mix on then off; the
-- gain the module is given at Play (the mixer's wrapped Play, A.Mix.lastPlay) is caught.
-- Pass: on/off gain ratio = the group's value (items: All 0.72; an explosion: Explosions 0.90; a bullet
-- hit: bullethit 0.67) within 0.5 dB.
local A, N = pba, pba.Native
if not (N and N.render and pba_native) then return { pass = false, err = "native rendering off" } end
local res = { checks = {}, ratio = {} }
local L = A.ListenerPos()
local fwd = LocalPlayer():EyeAngles():Forward()
fwd.z = 0 fwd:Normalize()
local S = L + fwd * 200
local CASES = {
	{ key = "all", name = "items/smallmedkit1.wav", lvl = 75, chan = CHAN_AUTO, want = 0.72 },
	{ key = "explosion", name = "ambient/explosions/explode_1.wav", lvl = 140, chan = CHAN_AUTO, want = 0.90 },
	{ key = "bullethit", name = "physics/concrete/concrete_impact_bullet1.wav", lvl = 75, chan = CHAN_AUTO, want = 0.67 },
}
for _, c in ipairs(CASES) do
	local t0 = RealTime()
	while not N.EnsureSound(c.name) do
		if RealTime() - t0 > 10 then return { pass = false, err = "not decoded: " .. c.name } end
		job:sleep(0.1)
	end
end
local caught, caughtId
local play = pba_native.Play
local savedOpt = A.cfg.native_mix
local function run(c, on)
	A.cfg.native_mix = on and 1 or 0
	caught = nil
	pba_native.Play = function(n, pos, g, ...)
		local id = play(n, pos, g, ...)
		-- (the gain the module was given: the mix is applied in the wrapped Play, below this watcher)
		if caught == nil and isstring(n) and string.find(string.lower(n), c.name, 1, true) and A.Mix.lastPlay then
			caught, caughtId = A.Mix.lastPlay.gain, id
		end
		return id
	end
	local ok, err = pcall(A.Process, { SoundName = c.name, Pos = S, SoundLevel = c.lvl, Pitch = 100, Volume = 1,
		Channel = c.chan, Flags = 0, DSP = 0, EntIndex = 0 }, true)
	pba_native.Play = play
	if not ok then error(err) end
	return caught
end
local ok, err = pcall(function()
	for _, c in ipairs(CASES) do
		local gOn = run(c, true)
		-- the voice keeps its groups: its updates (pba_native.Update, wrapped) follow the mixer and the ducks
		res.checks["tracked_" .. c.key] = caughtId ~= nil and A.Mix.voice[caughtId] ~= nil
		job:sleep(0.3)
		local gOff = run(c, false)
		job:sleep(0.3)
		local r = gOn and gOff and gOff > 0 and gOn / gOff or nil
		res.ratio[c.key] = r and math.Round(r, 3) or "no play"
		res.checks[c.key] = r ~= nil and math.abs(20 * math.log10(r / c.want)) < 0.5
	end
end)
pba_native.Play = play
A.cfg.native_mix = savedOpt
if not ok then return { pass = false, err = err } end
res.checks.option = A.CONFIG.native_mix ~= nil
res.fails = {}
for k, v in SortedPairs(res.checks) do if not v then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
