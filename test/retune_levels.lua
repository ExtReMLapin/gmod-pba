-- Report-only measurement of the reverb / echo levels of the native renderer (client lua_job, args: reverbs = {..}, echoes = {..},
-- dist = units, sky = bool). Used to retune the defaults for the level-fixed phonon.dll (2026-11-17) and to compare it with the old one.
-- Measure: the module's own mix energy (N.energyL/R, the sum the audio thread reports) of one shot from a clientside prop
-- `dist` units ahead along a clear line, after a warm-up shot (the source slot's simulation):
--   direct = energy with pba_native_reverb 0 and pba_native_echo 0 (the direct voice alone);
--   reverb dB = 10 log10((energy - direct) / direct) at each pba_native_reverb with echo 0;
--     (energy - direct also holds the cross term 2 <direct, reverb> of the early reflections that are coherent with the
--     direct sound: on pba_pipe a level 140 shot at 300 u reads -9.4 dB at reverb 1 where the reverb alone is -15.2 dB (fitted
--     from reverb 1 and 0.25: energy ~ r^2, cross term ~ r). Compare an echo, measured alone, with the reverb alone, not with this;)
--   echo dB   = the same with pba_native_all 0 (the engine-played mode: N.Echo is the only reflection) at each pba_native_echo, reverb 0.
-- Also the room reverb time of the listener's room (pba_native.RoomReverb), the module's own estimate.
-- Every setting changed is put back at the end.
local N = pba.Native
if not (N and N.render) then return { pass = false, err = "native renderer not running" } end
local args = job.args or {}
local reverbs = args.reverbs or { 0.4, 1 }
local echoes = args.echoes or { 0.25, 0.75, 1 }
local dist = args.dist or 300
local ply = LocalPlayer()
local names = { "pba_native_reverb", "pba_native_echo", "pba_native_all", "pba_native_loud_dry", "pba_native_loud_dry_db" }
local saved = {}
for _, n in ipairs(names) do saved[n] = GetConVar(n):GetString() end
local function set(cv, v)
	v = tostring(v)
	RunConsoleCommand(cv, v)
	job:wait(function() return math.abs(GetConVar(cv):GetFloat() - tonumber(v)) < 1e-6 end, 5)
	job:sleep(0.4)
end
local function restore() for n, v in pairs(saved) do RunConsoleCommand(n, v) end end
-- a clear line of `dist` units in some direction (sky not needed here: reverb of the room the player is in)
local eye = ply:EyePos()
local ang, found
for yaw = 0, 350, 30 do
	local a = Angle(0, yaw, 0)
	local tr = util.TraceLine({ start = eye, endpos = eye + a:Forward() * (dist + 20), mask = MASK_SOLID_BRUSHONLY })
	if not tr.Hit then ang, found = a, true break end
end
if not found then restore() return { pass = false, err = "no clear line of " .. dist .. " u around the player" } end
local e = ClientsideModel("models/props_junk/PopCan01a.mdl")
e:SetPos(eye + ang:Forward() * dist + Vector(0, 0, -16))
local function shot(name, lvl, vol)
	local e0 = (N.energyL or 0) + (N.energyR or 0)
	e:EmitSound(name, lvl, 100, vol, CHAN_WEAPON)
	job:sleep(3)
	return (N.energyL or 0) + (N.energyR or 0) - e0
end
local function measure(name, lvl, vol)
	shot(name, lvl, vol)
	local s = 0
	for _ = 1, 2 do s = s + shot(name, lvl, vol) end
	return s / 2
end
local function db(x) return math.Round(10 * math.log10(math.max(x, 1e-12)), 2) end
local LOUD, QUIET = "^weapons/smg1/npc_smg1_fire1.wav", "vo/npc/male01/hi01.wav"
local SOUNDS = { loud = { LOUD, 140, 0.7 }, quiet = { QUIET, 75, 1 }, mid = { LOUD, 95, 0.7 } }
local res = { map = game.GetMap(), dist = dist, pos = tostring(ply:GetPos()), native_all = saved.pba_native_all }
-- the room's reverb time
job:sleep(2)
local rt = { pba_native.RoomReverb() }
res.rt = { math.Round(rt[1] or -1, 3), math.Round(rt[2] or -1, 3), math.Round(rt[3] or -1, 3) }
-- direct
set("pba_native_all", 1)
set("pba_native_echo", 0)
set("pba_native_reverb", 0)
local direct = {}
for k, s in pairs(SOUNDS) do direct[k] = measure(s[1], s[2], s[3]) end
res.directDb = {}
for k, v in pairs(direct) do res.directDb[k] = db(v) end
-- slot reverb (native_all 1) at each reverb setting, loud-dry as configured (and without it for the loud one)
res.reverb = {}
for _, r in ipairs(reverbs) do
	set("pba_native_reverb", r)
	local row = {}
	for k, s in pairs(SOUNDS) do
		local tot = measure(s[1], s[2], s[3])
		row[k] = db(math.max(tot - direct[k], 1e-12) / direct[k])
	end
	set("pba_native_loud_dry", 0)
	local tot = measure(LOUD, 140, 0.7)
	row.loud_nodry = db(math.max(tot - direct.loud, 1e-12) / direct.loud)
	set("pba_native_loud_dry", saved.pba_native_loud_dry)
	res.reverb[tostring(r)] = row
end
-- echoes alone (engine-played mode, native_all 0: N.Echo is then the only source reflection), from the same prop, the
-- loud shot (level 140) and a 95 dB bang; the energy of 4 shots (one shot per 0.35 s, 1.2 s of tail) / 4, in dB re the module's
-- own direct voice of the same shot (same gain units: the echo gain is the source's power, the voice's too)
set("pba_native_reverb", 0)
set("pba_native_all", 0)
local function echoE(name, lvl, vol)
	local data = { SoundName = name, SoundLevel = lvl, Volume = vol, Pitch = 100 }
	N.energyL, N.energyR = 0, 0
	for _ = 1, 4 do N.Echo(data, e:GetPos()) job:sleep(0.35) end
	job:sleep(1.2)
	return (N.energyL + N.energyR) / 4
end
local function stable(name, lvl, vol)
	local prev = echoE(name, lvl, vol)
	for _ = 1, 8 do
		local cur = echoE(name, lvl, vol)
		if math.abs(cur - prev) <= 0.03 * math.max(prev, 1e-9) then return cur end
		prev = cur
	end
	return prev
end
res.echo = {}
for _, x in ipairs(echoes) do
	set("pba_native_echo", x)
	local row = {}
	for k, s in pairs({ loud = SOUNDS.loud, mid = SOUNDS.mid }) do
		local en = stable(s[1], s[2], s[3])
		row[k] = db(math.max(en, 1e-12) / direct[k])
	end
	set("pba_native_loud_dry", 0)
	row.loud_nodry = db(math.max(stable(LOUD, 140, 0.7), 1e-12) / direct.loud)
	set("pba_native_loud_dry", saved.pba_native_loud_dry)
	res.echo[tostring(x)] = row
end
e:Remove()
restore()
job:sleep(0.5)
res.pass = true
return res
