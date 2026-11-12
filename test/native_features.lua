-- Native feature checks (client lua_job, native rendering on, pba_tworooms):
-- echoes, output modes, start delay, path-effect field, bake disk cache, reflection thread load.
-- Pass (res.checks, res.fails name what failed):
--   headphones: a voice 200 u to the right is louder in the right ear (R > 1.5 L: a male voice's
--     energy lies below 1 kHz, where the head shadow is small: 1.8-1.9 measured with Steam Audio's
--     default HRTF, white noise gives 50; a lost HRTF gives 1.0) and reaches it first (ITD lag <= -3
--     samples; + = left ear first);
--   speakers: no ITD (|lag| <= 1 sample);
--   delay: nothing during the first 0.5 s of a voice started 0.8 s late (first < 0.05 x after);
--   pathfx: a path field arriving from the right is louder on the right (R > L);
--   loopstart: a WAV's loop marker is kept (the jeep's start sound: starter once, then the engine
--     running from sample 80897 at 44.1 kHz = 1.834 s; whole-file loop otherwise = the engine heard
--     restarting every 6 s), and a WAV without one loops from its top (nil);
--   bake: the cache file is deleted first, so bake 1 is a real bake and bake 2 loads it back from the
--     disk cache (fromCache) in under a fifth of the bake time.
local N = pba.Native
local NA = pba_native
local ply = LocalPlayer()
local res = {}
if not (N and N.ready and N.render and NA) then
	return { pass = false, err = "native renderer not running (pba_native_render 1, module loaded)" }
end
local function cvar(n, v) RunConsoleCommand(n, tostring(v)) end
-- every client pba_* setting is put back at the end: the player's choices must survive the test
local saved = {}
for n, c in pairs(pba.CONFIG) do if c[4] == "cl" then saved[n] = GetConVar("pba_" .. n):GetString() end end

-- energies of the native mix over `secs`, per ear
local function measure(secs)
	N.energyL, N.energyR = 0, 0
	NA.RenderDebug()
	job:sleep(secs)
	local _, a = NA.RenderDebug()
	return N.energyL, N.energyR, a.y -- y = ITD lag (samples, + = left ear first)
end

local eye = ply:EyePos()
local ang = ply:EyeAngles()
local right = eye + ang:Right() * 200
local snd = "ambient/levels/citadel/citadel_hit1_adpcm.wav"
local ok, name = N.EnsureSound("vo/npc/male01/hi01.wav")
res.sound = ok

-- 1. echoes: loud clear sound in front, A/B
do
	cvar("pba_native_echo", 1)
	job:sleep(0.6)
	local pos = eye + ang:Forward() * 150
	local data = { SoundName = "weapons/ar2/fire1.wav", SoundLevel = 140, Volume = 1, Pitch = 100 }
	N.energyL, N.energyR = 0, 0
	for _ = 1, 4 do N.Echo(data, pos) job:sleep(0.35) end
	job:sleep(1)
	local st = NA.Stats()
	res.echo = { energy = N.energyL + N.energyR, reflMs = st.reflMs, audioAvgMs = st.audioAvgMs, audioMaxMs = st.audioMaxMs,
		runs = st.reflRuns, rt = { st.rtLow, st.rtMid, st.rtHigh } }
	job:sleep(4)
	local st2 = NA.Stats()
	res.idle = { reflMs = st2.reflMs, runsIn4s = st2.reflRuns - st.reflRuns }
end

-- 2. output modes: same voice on the right, headphones vs speakers
local function playRight(opt)
	NA.Play(name, right, 0.3, 1, 1, 1, 100, false, opt and opt.delay or 0, opt and opt.sh)
end
do
	cvar("pba_native_echo", 0)
	cvar("pba_native_reverb", 0)
	job:sleep(0.7)
	cvar("pba_native_out", 0)
	job:sleep(0.7)
	playRight()
	local l, r, lag = measure(1.2)
	res.headphones = { L = l, R = r, lag = lag }
	cvar("pba_native_out", 1)
	job:sleep(0.7)
	playRight()
	l, r, lag = measure(1.2)
	res.speakers = { L = l, R = r, lag = lag }
	cvar("pba_native_out", 0)
	job:sleep(0.7)
end

-- 3. start delay: nothing during the first 0.5 s, then the voice
do
	playRight({ delay = 0.8 })
	local l1, r1 = measure(0.5)
	local l2, r2 = measure(1.2)
	res.delay = { first = l1 + r1, after = l2 + r2 }
end

-- 4. path effect: unit field arriving from the listener's right (Source axes -> SH via the
-- measured mapping x = -sh1, y = sh3, z = sh2)
do
	local d = ang:Right()
	local k = 0.4886025 -- first-order SH normalisation
	local sh = { 0.2820948, -d.x * k, d.z * k, d.y * k }
	NA.Play(name, eye + ang:Forward() * 200, 0.3, 1, 1, 1, 100, false, 0, sh)
	local l, r, lag = measure(1.2)
	res.pathfx = { L = l, R = r, lag = lag }
end
cvar("pba_native_reverb", 0.3)
cvar("pba_native_echo", 1)

-- 5. bake disk cache: start from no cache and no baked paths, so bake 1 really bakes
do
	cvar("pba_native_cache", 1)
	cvar("pba_native_paths", 0)
	job:sleep(0.5)
	N.pathsReady = false
	file.Delete("pba/" .. game.GetMap() .. "_sa.dat")
	cvar("pba_native_paths", 1)
	job:wait(function() return N.pathsReady end, 30)
	res.bake1 = { ready = N.pathsReady, fromCache = N.fromCache, ms = N.bakeMs, cached = N.bakeCached }
	N.pathsReady = false
	N.Bake()
	job:wait(function() return N.pathsReady end, 30)
	res.bake2 = { ready = N.pathsReady, fromCache = N.fromCache, ms = N.bakeMs }
	res.file = file.Size("pba/" .. game.GetMap() .. "_sa.dat", "DATA")
	cvar("pba_native_paths", 0)
end
-- loop markers (smpl chunk), read straight from the module's loader
local function loopOf(p)
	local _, ls = NA.LoadSound("pba_test_loop:" .. p, file.Read("sound/" .. p, "GAME"))
	return ls
end
res.loopStart = { start = loopOf("vehicles/v8/v8_start_loop1.wav"), idle = loopOf("vehicles/v8/v8_idle_loop1.wav") }
for n, v in pairs(saved) do if GetConVar("pba_" .. n):GetString() ~= v then RunConsoleCommand("pba_" .. n, v) end end
local h, s, d, pf, b1, b2 = res.headphones, res.speakers, res.delay, res.pathfx, res.bake1, res.bake2
local function num(x) return tonumber(x) or 0 end
res.checks = {
	headphones = num(h.R) > 1.5 * num(h.L) and h.lag ~= nil and h.lag <= -3,
	speakers = s.lag ~= nil and math.abs(s.lag) <= 1,
	delay = num(d.after) > 0 and num(d.first) < 0.05 * num(d.after),
	pathfx = num(pf.R) > num(pf.L),
	loopstart = math.abs(num(res.loopStart.start) - 80897 / 44100) < 1e-3 and res.loopStart.idle == nil,
	bake = b1.ready == true and b2.ready == true and b1.fromCache ~= true and b2.fromCache == true
		and num(b1.ms) > 0 and num(b2.ms) < 0.2 * num(b1.ms),
}
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
