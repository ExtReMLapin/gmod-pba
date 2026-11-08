-- Soundscape sounds (env_soundscape, C_SoundscapeSystem) are played by the CLIENT: "playrandom"
-- waves with "position random" come through EntityEmitSound on the world entity, CHAN_STATIC,
-- SNDLVL_140db, at a random point ~36 u around the ear. They are ambience: pba must leave them to
-- the engine (no re-emission, no muffling through a wall the random point landed behind, no
-- native echo of a "140 dB" source next to the ear).
-- lua_job, client realm, d1_town_01 (any map with a soundscape works: pass args.soundscape).
-- Needs sv_cheats 1 (playsoundscape, setpos). Moves the player next to the nearest wall, forces
-- the soundscape, captures args.secs (default 30) of live sounds and also calls pba's hook with
-- synthetic soundscape sounds on a 36 u ring around the ear; restores position and hook.
-- Returns { pass, live = {...}, ring = {...}, counts }.
-- pass = every soundscape sound (live and ring) is left to the engine (pba's hook does not return
-- false, pba neither processes nor re-emits it natively nor echoes it).
local args = job.args or {}
local SECS = args.secs or 30
local SCAPE = args.soundscape or (game.GetMap() == "d1_town_01" and "d1_town.Street") or nil
local ply = LocalPlayer()
if not pba or not pba.Enabled or not pba.Enabled() then return { pass = false, err = "pba disabled" } end
if GetConVarNumber("sv_cheats") < 1 then return { pass = false, err = "needs sv_cheats 1" } end

-- soundscape wave set (manifest), to tell soundscape sounds from other world CHAN_STATIC sounds
local waves = {}
local man = file.Read("scripts/soundscapes_manifest.txt", "GAME") or ""
for f in man:gmatch('"file"%s+"([^"]+)"') do
	local s = file.Read(f, "GAME") or ""
	for w in s:gmatch('"wave"%s+"([^"]+)"') do waves[string.lower((w:gsub("\\", "/")))] = true end
end
local nWaves = table.Count(waves)
local function isScape(name)
	return name and waves[string.lower((string.gsub(name, "^[%^%)%(%*@#<>!?$&]+", ""):gsub("\\", "/")))] or false
end

-- nearest wall (horizontal), stand 20 u from it: a random point 36 u away can land behind it
local P0, A0 = ply:GetPos(), ply:EyeAngles()
local E0 = ply:EyePos()
local best
for a = 0, 345, 15 do
	local d = Angle(0, a, 0):Forward()
	local tr = util.TraceLine({ start = E0, endpos = E0 + d * 400, mask = MASK_SOLID_BRUSHONLY })
	if tr.Hit and not tr.HitSky and (not best or tr.Fraction < best.f) then best = { f = tr.Fraction, d = d, a = a } end
end
local moved = false
if best and best.f * 400 > 24 then
	local np = P0 + best.d * (best.f * 400 - 20)
	RunConsoleCommand("setpos", np.x, np.y, np.z)
	job:wait(function() return ply:GetPos():DistToSqr(np) < 4 end, 3)
	moved = ply:GetPos():DistToSqr(np) < 4
	job:frames(5)
end

local HT = hook.GetTable().EntityEmitSound
local orig = HT and HT.pba
if not orig then return { pass = false, err = "pba hook missing" } end
local live, cur = {}, nil
local echoes0 = pba.Native and pba.Native.echoes or 0
local function stat(k) return pba.stats[k] or 0 end
local wrap
wrap = function(data)
	if pba.reemitting then return orig(data) end
	local L = pba.ListenerPos()
	local e = data.Entity
	local world = IsValid(e) and e:IsWorld() or (e and e.IsWorld and e:IsWorld()) or false
	local r = { name = data.SoundName, chan = data.Channel, lvl = data.SoundLevel, ent = world and "world" or tostring(e),
		scape = isScape(data.SoundName), synthetic = cur ~= nil }
	local pos = data.Pos or pba.SoundPos(data)
	if pos and L then
		r.dist = math.Round(pos:Distance(L))
		r.solid = bit.band(util.PointContents(pos), CONTENTS_SOLID) ~= 0
		r.blocked = util.TraceLine({ start = L, endpos = pos, mask = MASK_SOLID_BRUSHONLY }).Fraction < 0.99
		pba.Paths.InvalidateCache()
		local pr = pba.Paths.Compute(pos, L, data.SoundLevel or 75)
		r.clear = pr.clear or false
		if not pr.clear then
			local lv = -999
			for _, v in ipairs(pr.voices or {}) do lv = math.max(lv, v.level or -999) end
			r.level_db = math.Round(lv, 1)
		end
	end
	local p0, n0 = stat("processed"), stat("nativeDirect")
	local e0 = pba.Native and pba.Native.echoes or 0
	local ret = orig(data)
	r.taken = ret == false
	r.muffled = stat("processed") > p0
	r.native = stat("nativeDirect") > n0
	r.echoed = (pba.Native and pba.Native.echoes or 0) > e0
	if cur then cur[#cur + 1] = r else live[#live + 1] = r end
	return ret
end
hook.Add("EntityEmitSound", "pba", wrap)

local ring = {}
local ok, err = pcall(function()
	if SCAPE then RunConsoleCommand("playsoundscape", SCAPE) end
	job:frames(10)
	-- synthetic ring: the same table C_SoundscapeSystem::PlayRandomSound builds, 16 directions
	cur = ring
	local L = pba.ListenerPos()
	local name = "ambient/wind/wind_moan1.wav"
	for i = 0, 15 do
		local d = Angle(0, i * 22.5, 0):Forward()
		local data = { SoundName = name, OriginalSoundName = name, Channel = CHAN_STATIC, Entity = game.GetWorld(),
			Pos = L + d * 36 - Vector(0, 0, 2), SoundLevel = 140, Volume = 0.05, Pitch = 100, Flags = 0, DSP = 0, SoundTime = 0 }
		hook.Run("EntityEmitSound", data)
		job:frames(2)
	end
	cur = nil
	job:sleep(SECS)
end)
if hook.GetTable().EntityEmitSound.pba == wrap then hook.Add("EntityEmitSound", "pba", orig) end
if moved then
	RunConsoleCommand("setpos", P0.x, P0.y, P0.z)
	RunConsoleCommand("setang", A0.p, A0.y, A0.r)
end
if not ok then return { pass = false, err = tostring(err) } end

local c = { live = 0, liveScape = 0, liveTaken = 0, liveMuffled = 0, liveNative = 0, liveEchoed = 0, liveBlocked = 0,
	liveSolid = 0, liveNear64 = 0, ring = #ring, ringTaken = 0, ringMuffled = 0, ringBlocked = 0, ringSolid = 0 }
for _, r in ipairs(live) do
	c.live = c.live + 1
	if r.scape then
		c.liveScape = c.liveScape + 1
		if r.taken then c.liveTaken = c.liveTaken + 1 end
		if r.muffled then c.liveMuffled = c.liveMuffled + 1 end
		if r.native then c.liveNative = c.liveNative + 1 end
		if r.echoed then c.liveEchoed = c.liveEchoed + 1 end
		if r.clear == false then c.liveBlocked = c.liveBlocked + 1 end
		if r.solid then c.liveSolid = c.liveSolid + 1 end
		if (r.dist or 1e9) <= 64 then c.liveNear64 = c.liveNear64 + 1 end
	end
end
for _, r in ipairs(ring) do
	if r.taken or r.echoed then c.ringTaken = c.ringTaken + 1 end
	if r.muffled then c.ringMuffled = c.ringMuffled + 1 end
	if r.clear == false then c.ringBlocked = c.ringBlocked + 1 end
	if r.solid then c.ringSolid = c.ringSolid + 1 end
end
local pass = c.liveScape >= 1 and c.liveTaken == 0 and c.liveEchoed == 0 and c.ringTaken == 0
return { pass = pass, counts = c, soundscape = SCAPE, waves = nWaves, moved = moved,
	wallDist = best and math.Round(best.f * 400), live = live, ring = ring }
