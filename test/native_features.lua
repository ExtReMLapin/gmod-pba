-- Native feature checks (client lua_job, native rendering on, pba_tworooms):
-- echoes, output modes, start delay, path-effect field, bake disk cache, reflection thread load.
local N = pba.Native
local NA = pba_native
local ply = LocalPlayer()
local res = {}
local function cvar(n, v) RunConsoleCommand(n, tostring(v)) end

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

-- 5. bake disk cache
do
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
return res
