-- "^" distance-variant sounds (CHAR_DISTVARIANT: a stereo wav, left = near, right = far). The engine
-- crossfades the two channels by the distance from the CHANNEL ORIGIN to the listener:
-- distmix = clamp((d - 240) / (1320 - 240), 0, 1) (snd_dma.cpp DVAR_DIST_MIN 20 ft / DVAR_DIST_MAX 110 ft;
-- checked in GMod with sv_cheats 1, developer 1, snd_showstart 2: 2371 u -> 1.00, 700 u -> 0.43,
-- 192 u -> 0.00). HL2 NPC gunfire and explosions use it (Weapon_SMG1.NPC_Single
-- "^weapons/smg1/npc_smg1_fire1.wav", Weapon_AR2.NPC_Single, Weapon_Pistol.NPC_Single,
-- BaseExplosionEffect.Sound...). A pba copy re-emitted at a virtual point near the listener (an
-- opening, a wall face) would play the NEAR wave of a far gunshot.
-- lua_job, client realm, gm_construct or any big map, listener anywhere: far sources (> 1300 u) with a
-- non-clear answer are sampled round the listener and played through pba.Process (engine path: the
-- native renderer is held off during the test, it downmixes both channels to mono anyway).
-- Returns { pass, copies = {...} }: pass = every engine copy of a "^" sound keeps the far mix vanilla
-- GMod would give it (distmix at the copy >= distmix at the real source - 0.1).
local A = pba
local DMIN, DMAX = 240, 1320
local function mix(d) return math.Clamp((d - DMIN) / (DMAX - DMIN), 0, 1) end
local NAME = "^weapons/smg1/npc_smg1_fire1.wav"
local L = A.ListenerPos()
if not L then return { pass = false, error = "no listener" } end

-- far sources whose pba answer is not clear (something to re-emit)
local cands = {}
math.randomseed(7)
for _ = 1, 800 do
	if #cands >= 6 then break end
	local x, y = L.x + math.random(-4000, 4000), L.y + math.random(-4000, 4000)
	local tr = util.TraceLine({ start = Vector(x, y, L.z + 2000), endpos = Vector(x, y, L.z - 3000), mask = MASK_SOLID_BRUSHONLY })
	if tr.Hit and not tr.StartSolid and not tr.HitSky then
		local S = tr.HitPos + Vector(0, 0, 48)
		local d = S:Distance(L)
		if bit.band(util.PointContents(S), MASK_SOLID) == 0 and d > 1300 and d < 4000 then
			local r = A.Paths.Compute(S, L, 105)
			if not r.clear and r.voices and #r.voices > 0 then cands[#cands + 1] = S end
		end
	end
	job:step()
end
if #cands == 0 then return { pass = false, error = "no far obstructed source found round the listener" } end

-- capture what reaches the engine (test-scoped wrapper of pba.Emit, restored below)
local seen = {}
local emit, nativeRender = A.Emit, A.Native and A.Native.render
A.Emit = function(fn, ...)
	local a = { ... }
	if type(a[1]) == "string" then
		seen[#seen + 1] = { name = a[1], pos = a[2] } -- EmitSound(name, pos, ...)
	elseif IsValid(a[1]) then
		seen[#seen + 1] = { name = a[2], pos = a[1]:GetPos() } -- anchor:EmitSound(name, ...) after SetPos
	end
	return emit(fn, ...)
end
if A.Native then A.Native.render = false end
local copies, pass = {}, true
local ok, err = pcall(function()
	for i, S in ipairs(cands) do
		seen = {}
		A.Process({ SoundName = NAME, OriginalSoundName = "Weapon_SMG1.NPC_Single", Pos = S, SoundLevel = 105,
			Pitch = 100, Volume = 1, Channel = CHAN_WEAPON, Flags = 0, DSP = 0, Entity = game.GetWorld(), EntIndex = 0 }, true)
		job:sleep(0.4) -- voice delays (propagation) fire on timers
		local vanilla = mix(S:Distance(L))
		for _, e in ipairs(seen) do
			local dc = e.pos:Distance(L)
			local isDV = string.find(string.match(e.name, "^[%^%)%*#@<>!%?%$&~`+%%%(}]*") or "", "^", 1, true) ~= nil
			local m = isDV and mix(dc) or nil
			if isDV and m < vanilla - 0.1 then pass = false end
			copies[#copies + 1] = string.format("src %d u (vanilla distmix %.2f) -> copy '%s' at %d u, distmix %s", S:Distance(L), vanilla,
				e.name, dc, m and string.format("%.2f", m) or "n/a (no ^)")
		end
	end
end)
A.Emit = emit
if A.Native then A.Native.render = nativeRender end
if not ok then return { pass = false, error = tostring(err) } end
return { pass = pass and #copies > 0, copies = copies, sources = #cands }
