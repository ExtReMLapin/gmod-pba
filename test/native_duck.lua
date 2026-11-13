-- Ducking of a natively rendered loop (client, lua_job; module with native rendering; audit C-4). The
-- engine lowers ambience (60 %) under gunfire, explosions and dialog; a loop the module plays kept its
-- level. A client sound patch on a looping ambience file (on a client prop: followed as a loop, played by the
-- module) runs;
-- a burst of loud shots 150 u away, made by a player (Player_Weapons_Loud: causes ducking; a weapon of
-- no entity is only Weapons, which does not), is processed (A.Process, as relayed).
-- Pass: the loop's voice is native with its groups; before the burst its value is 0.72 (Default_Mix
-- All); 0.6 s into the burst Ambient_Atmosphere is ducked to 0.6 and the voice's value to 0.72 x 0.6;
-- with pba_native_duck 0 the value stays 0.72.
local A, N, M = pba, pba.Native, pba.Mix
if not (N and N.render and M and M.Value) then return { pass = false, err = "native rendering or cl_mix missing" } end
local res = { checks = {} }
local function near(a, b, e) return a and math.abs(a - b) < (e or 0.02) end
local NAME = "ambient/atmosphere/tone_alley.wav"
local SHOT = "weapons/smg1/smg1_fire1.wav"
local t0 = RealTime()
while not N.EnsureSound(NAME) or not N.EnsureSound(SHOT) do
	if RealTime() - t0 > 10 then return { pass = false, err = "not decoded" } end
	job:sleep(0.1)
end
local saved = A.cfg.native_duck
M.Reset()
local ply = LocalPlayer()
-- (on a client prop 200 u ahead: a patch on the local player is his own, left to the engine)
local fwd0 = ply:EyeAngles():Forward() fwd0.z = 0 fwd0:Normalize()
local prop = ents.CreateClientProp("models/props_junk/PopCan01a.mdl")
prop:SetPos(A.ListenerPos() + fwd0 * 200)
prop:Spawn()
local patch = CreateSound(prop, NAME)
patch:SetSoundLevel(75)
patch:PlayEx(0.5, 100)
job:sleep(0.5)
local m
for _, x in pairs(A.Loops.mirrors) do if x.name == NAME and x.client then m = x end end
res.checks.mirror = m ~= nil and m.nativeId ~= nil and m.mixG ~= nil
local function burst(secs)
	local L = A.ListenerPos()
	local fwd = ply:EyeAngles():Forward() fwd.z = 0 fwd:Normalize()
	local tEnd = RealTime() + secs
	while RealTime() < tEnd do
		A.Process({ SoundName = SHOT, Pos = L + fwd * 150, SoundLevel = 140, Pitch = 100, Volume = 1, Channel = CHAN_WEAPON,
			Flags = 0, DSP = 0, EntIndex = ply:EntIndex() }, true)
		job:sleep(0.075)
	end
end
local ok, err = pcall(function()
	if not m then return end
	res.before = M.Value(m.mixG)
	res.checks.before = near(res.before, 0.72)
	burst(0.7)
	res.duck = M.DuckOf("Ambient_Atmosphere")
	res.during = M.Value(m.mixG)
	res.checks.ducked = near(res.duck, 0.6) and near(res.during, 0.72 * 0.6)
	job:sleep(3)
	M.Reset()
	A.cfg.native_duck = 0
	burst(0.7)
	res.off = M.Value(m.mixG)
	res.checks.off = near(res.off, 0.72)
end)
A.cfg.native_duck = saved
patch:Stop()
if IsValid(prop) then prop:Remove() end
M.Reset()
if not ok then return { pass = false, err = err } end
res.fails = {}
for k, v in SortedPairs(res.checks) do if not v then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
