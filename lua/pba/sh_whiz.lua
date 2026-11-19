-- pba: bullet whizz (fly-bys). The pure part, shared by both realms.
-- Copyright (C) 2026 pba contributors. Licensed under the GNU GPL v3 or later (see LICENSE).
--
-- The engine plays the whizz of a bullet passing the ear itself (the client's tracer effect: a CHAN_STATIC
-- sound on the world, Bullets.DefaultNearmiss and its gunship / strider variants), through no hook: not
-- EntityEmitSound, so pba never saw it and it played unprocessed. What the client does, observed in the game's
-- binary and measured with tracer effects swept past the ear (snd_dumpclientsounds):
--   - a tracer segment whizzes when it passes within 24 u of a vertical segment from the view origin down to
--     24 u below it (a head-and-chest column: the default tracer; 22 u whizzes, 25 u does not, 46 u under the
--     eye whizzes, 50 u does not), or within 72 u of the view origin itself (gunship and strider tracers);
--     the segment's ends count;
--   - at most one whizz every 0.1 s;
--   - the sound is at the tracer's start point, 140 dB, volume 0.7.
-- The server sees the bullets (GM:EntityFireBullets, NPCs' included): sv_whiz.lua finds the near misses and
-- tells the client, cl_whiz.lua plays them through the module (pba_native_whiz).
local A = pba
if A.JitFile then A.JitFile("sh_whiz") end -- LuaJIT per file: pba_lua_interp (sh_config.lua)
A.Whiz = A.Whiz or {}
local W = A.Whiz

W.GAP = 0.1 -- s between two whizzes (the engine's: one at a time)

--- The reach of a tracer kind (W.Kind): the distance (units) from the ears within which it whizzes, and the
-- length of the column below the view origin that counts as "the ears" (0 = the view origin alone).
function W.Reach(kind)
	if (kind or 0) == 0 then return 24, 24 end
	return 72, 0
end

-- the closest points of segment p1q1 and segment p2q2 (Ericson, Real-Time Collision Detection 5.1.9)
local function segSeg(p1, q1, p2, q2)
	local d1, d2, r = q1 - p1, q2 - p2, p1 - p2
	local a, e, f = d1:Dot(d1), d2:Dot(d2), d2:Dot(r)
	local s, t
	if a <= 1e-9 and e <= 1e-9 then
		s, t = 0, 0
	elseif a <= 1e-9 then
		s, t = 0, math.Clamp(f / e, 0, 1)
	else
		local c = d1:Dot(r)
		if e <= 1e-9 then
			s, t = math.Clamp(-c / a, 0, 1), 0
		else
			local b = d1:Dot(d2)
			local den = a * e - b * b
			s = den > 1e-9 and math.Clamp((b * f - c * e) / den, 0, 1) or 0
			t = (b * s + f) / e
			if t < 0 then t, s = 0, math.Clamp(-c / a, 0, 1)
			elseif t > 1 then t, s = 1, math.Clamp((b - c) / a, 0, 1) end
		end
	end
	return p1 + d1 * s, p2 + d2 * t
end

--- The point of the bullet's path a -> b (where it started, where it stopped) closest to the listener, and
-- that distance, when it is below `radius`; else nil. The listener is the point p, or with `drop` the vertical
-- segment from p down to p - drop (W.Reach). The distance is to the segment, its ends included: a bullet that
-- hits the player whizzes, one stopped by a wall farther than the radius does not.
function W.Near(a, b, p, radius, drop)
	local c, e = segSeg(a, b, p, (drop or 0) > 0 and (p - Vector(0, 0, drop)) or p)
	local d = c:Distance(e)
	if d >= radius then return nil end
	return c, d
end

local SCRIPTS = { [0] = "Bullets.DefaultNearmiss", "Bullets.GunshipNearmiss", "Bullets.StriderNearmiss" }
W.SCRIPTS = SCRIPTS
local KIND = { gunshiptracer = 1, stridertracer = 2 } -- (lower case)

--- The kind (0 default, 1 gunship, 2 strider) of the whizz a tracer effect makes (the SDK's three).
function W.Kind(tracerName)
	return KIND[string.lower(tracerName or "")] or 0
end
--- The sound script of a tracer effect's whizz.
function W.Script(tracerName) return SCRIPTS[W.Kind(tracerName)] end

--- True when the count-th shot (from 1) of a shooter draws a tracer: every `freq` shots, 0 never. The
-- engine whizzes only for a tracer it draws.
function W.TracerDrawn(freq, count)
	if not freq or freq <= 0 then return false end
	return (count - 1) % freq == 0
end
