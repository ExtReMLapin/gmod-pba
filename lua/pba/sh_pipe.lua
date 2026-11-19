-- Metal pipe (meme prop, lua/entities/pba_metal_pipe.lua): the rules that turn a physics impact into a clang.
-- Pure functions, no engine calls: tested offline (test/gluatest/pba_pure_test.lua). The sounds are
-- sound/pba/pipe/<tier>_<n>.wav, synthesized by tools/meme_pipe/ (modal synthesis of a struck steel tube).

local A = pba
if A.JitFile then A.JitFile("sh_pipe") end -- LuaJIT per file: pba_lua_interp (sh_config.lua)
local Pi = {}
A.Pipe = Pi

Pi.MODEL = "models/props_canal/mattpipe.mdl"
-- impact speeds (units/s along the contact normal) of the three tiers; below MIN_SPEED the pipe makes no sound
-- (resting, rolling, sliding: the engine's physics noise is silenced for this prop, so nothing else plays either)
Pi.MIN_SPEED = 60
Pi.MEDIUM_SPEED = 160
Pi.HARD_SPEED = 300
-- variants on disk per tier (different strike positions)
Pi.VARIANTS = { hard = 4, medium = 4, soft = 4 }
-- dry-run each tier gets: seconds before the same pipe may clang again
local COOLDOWN = { hard = 0.10, medium = 0.16, soft = 0.28 }
-- a hit this many times harder than the last one heard is not held back by the cooldown (after 0.04 s)
local ESCALATE = 2.5
-- share of the sliding speed that counts as impact (a glancing hit is not silent, a slide is)
local TANGENT = 0.15

--- Impact speed from the relative velocity (dx, dy, dz) of the two bodies and the contact normal (nx, ny, nz).
function Pi.ImpactSpeed(dx, dy, dz, nx, ny, nz)
	local vn = math.abs(dx * nx + dy * ny + dz * nz)
	local sq = dx * dx + dy * dy + dz * dz - vn * vn
	local vt = sq > 0 and math.sqrt(sq) or 0
	return vn + TANGENT * vt
end

--- "soft" | "medium" | "hard", or nil when the impact is too weak to be heard.
function Pi.Tier(speed)
	if speed < Pi.MIN_SPEED then return nil end
	if speed < Pi.MEDIUM_SPEED then return "soft" end
	if speed < Pi.HARD_SPEED then return "medium" end
	return "hard"
end

--- Volume (0..1] of an impact: rises with the speed, full from 700 u/s.
function Pi.Volume(speed)
	local t = (speed - Pi.MIN_SPEED) / (700 - Pi.MIN_SPEED)
	if t < 0 then t = 0 elseif t > 1 then t = 1 end
	return 0.45 + 0.55 * t
end

--- Seconds a pipe stays quiet after a clang of this tier.
function Pi.Cooldown(tier) return COOLDOWN[tier] or COOLDOWN.soft end

--- Per-pipe gate. st is the pipe's own table (st.t, st.speed: the last impact let through). True = play it (and the
-- gate records it); a refused impact leaves the state alone, so a rolling pipe is heard once per cooldown.
function Pi.Gate(st, now, speed)
	local tier = Pi.Tier(speed)
	if not tier then return false end
	local t = st.t
	if t then
		local dt = now - t
		if dt < 0.04 then return false end
		if dt < Pi.Cooldown(Pi.Tier(st.speed) or tier) and speed < (st.speed or 0) * ESCALATE then return false end
	end
	st.t, st.speed = now, speed
	return true
end

--- A file of the tier and its index; rnd in [0, 1) picks it, never the index `last` (the one just played).
function Pi.Pick(tier, rnd, last)
	local n = Pi.VARIANTS[tier] or Pi.VARIANTS.soft
	local idx
	if last and last >= 1 and last <= n and n > 1 then
		idx = 1 + math.floor(rnd * (n - 1))
		if idx >= last then idx = idx + 1 end
	else
		idx = 1 + math.floor(rnd * n)
	end
	if idx > n then idx = n end
	return "pba/pipe/" .. tier .. "_" .. idx .. ".wav", idx
end

--- The option: the entities exist only while pba_meme_pipe is on.
function Pi.Allowed() return A.On(A.cfg, "meme_pipe") end

--- Every sound file (as EmitSound takes it), the hardest first (the first clang of a fall is a hard one).
function Pi.Files()
	local out = {}
	for _, tier in ipairs({ "hard", "medium", "soft" }) do
		for i = 1, Pi.VARIANTS[tier] do out[#out + 1] = "pba/pipe/" .. tier .. "_" .. i .. ".wav" end
	end
	return out
end
