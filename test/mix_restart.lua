-- The mixer's ducker across an audio restart and with ungrouped voices (client, lua_job; module with native
-- rendering; singleplayer map, native on).
-- Found while recording a movie (startmovie restarts the engine's sound system): "cl_mix.lua:245: attempt to
-- index field 'g' (a nil value)" in M.Tick, every frame. A module voice the mixer tracks without groups (the
-- listener's own sound played with no mix groups: M.voice[id] = { g = nil, own = true }) was read as if
-- it had some by the ducker's scan of the playing voices.
-- Pass: (1) an own voice without groups, then the ducker's Tick and the Think hook run without error;
-- (2) after the stop-all a restart does (A.StopAllSounds: what the stopsound watch runs), no voice is
-- left in the mixer's table; (3) a sound pba plays after it is tracked with its groups, and the ducker ducks
-- a playing ambience as before (the mix resumed).
local A, N, M = pba, pba.Native, pba.Mix
if not (N and N.render and pba_native and M) then return { pass = false, err = "native rendering off" } end
local res = { checks = {} }
local function chk(k, ok) res.checks[k] = ok and true or false end
local NAME = "items/smallmedkit1.wav"
local t0 = RealTime()
while not N.EnsureSound(NAME) do
	if RealTime() - t0 > 10 then return { pass = false, err = "not decoded: " .. NAME } end
	job:sleep(0.1)
end
local L = A.ListenerPos()
local S = L + LocalPlayer():EyeAngles():Forward() * 200
local savedDuck = M.duck
local ok, err = pcall(function()
	-- (1) an own voice without groups
	local id = N.PlayVoice(NAME, S, 0.3, 0, 100, { own = true })
	chk("own_voice_played", id and id > 0)
	chk("own_voice_tracked_without_groups", id and M.voice[id] ~= nil and M.voice[id].g == nil and M.voice[id].own == true)
	local okTick, eTick = pcall(M.Tick, RealTime())
	chk("tick_no_error", okTick)
	if not okTick then res.tick_err = tostring(eTick) end
	M.lastTick = nil
	local think = hook.GetTable().Think and hook.GetTable().Think.pba_mix
	local okThink, eThink = pcall(think or error, "no pba_mix hook")
	chk("think_no_error", okThink)
	if not okThink then res.think_err = tostring(eThink) end
	-- (2) the stop-all of an audio restart
	A.StopAllSounds()
	job:sleep(0.2)
	chk("restart_voices_cleared", next(M.voice) == nil)
	-- (3) the mix resumes: a sound played now carries its groups, and the ducker ducks as before
	local g = M.GroupsOf(NAME, 0, CHAN_AUTO, 75)
	local id2 = N.PlayVoice(NAME, S, 0.3, 0, 100, { mix = g })
	chk("after_play", id2 and id2 > 0)
	chk("after_tracked_with_groups", id2 and M.voice[id2] ~= nil and M.voice[id2].g == g)
	M.Reset()
	local thunder = M.Groups("ambient/atmosphere/thunder1.wav", nil, CHAN_STATIC, 75)
	local shot = M.Groups("weapons/smg1/smg1_fire1.wav", "npc_citizen", CHAN_WEAPON, 140)
	local t = 1000
	M.Note(thunder, 0.3, t + 100)
	M.Note(shot, 0.9, t + 100)
	for _ = 1, 8 do t = t + 0.1 M.Tick(t) end
	chk("after_duck", math.abs(M.DuckOf("Ambient_Atmosphere") - 0.6) < 1e-3)
end)
M.Reset()
M.duck = savedDuck or M.duck
A.StopAllSounds()
if not ok then return { pass = false, err = tostring(err), checks = res.checks } end
res.fails = {}
for k, v in SortedPairs(res.checks) do if not v then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
