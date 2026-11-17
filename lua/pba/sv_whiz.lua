-- pba: bullet whizz, the server's part (see sh_whiz.lua). It watches the bullets fired (GM:EntityFireBullets:
-- every entity's, NPCs' included) and tells each player whose ears one passes (W.Reach).
-- Copyright (C) 2026 pba contributors. Licensed under the GNU GPL v3 or later (see LICENSE).
local A = pba
local W = A.Whiz
util.AddNetworkString("pba_whiz")

local MAX_PELLETS = 8 -- a shotgun's pellets are sampled up to this many (the closest one whizzes)
local counts = setmetatable({}, { __mode = "k" }) -- shots per shooter: which one draws its tracer (freq)
local nextWhiz = setmetatable({}, { __mode = "k" }) -- per player: no whizz before this CurTime (the engine's 0.1 s)

local function isShooter(ply, ent)
	if ent == ply then return true end
	return IsValid(ent) and ent.GetOwner and ent:GetOwner() == ply
end

--- The near miss of the shot `data` (EntityFireBullets) of tracer kind `kind` for ply: the closest point of
-- its path to his ears, the pellet's direction and the distance, or nil. The pellets of a spread are drawn as
-- the engine does (its triangular spread), each one stopped where it hits.
function W.Miss(ent, data, ply, kind)
	local src, dir = data.Src, data.Dir
	local radius, drop = W.Reach(kind)
	local eye = ply:EyePos()
	-- (cheap exit: the whole cone passes farther than the reach of the column's middle; behind the muzzle,
	-- the muzzle itself is the closest point)
	local ctr = eye - Vector(0, 0, drop / 2)
	local reach = radius + drop / 2
	local rel = ctr - src
	local t = rel:Dot(dir)
	local sp = data.Spread
	local sx, sy = sp and math.abs(sp.x) or 0, sp and math.abs(sp.y) or 0
	if t < 0 then
		if rel:Length() > reach then return nil end
	elseif (rel - dir * t):Length() > reach + t * math.max(sx, sy) then
		return nil
	end
	local dist = data.Distance
	if not dist or dist <= 0 then dist = 56756 end
	local best, bestD, bestDir
	local ang = dir:Angle()
	local right, up = ang:Right(), ang:Up()
	local owner = IsValid(ent) and ent.GetOwner and ent:GetOwner() or nil
	for _ = 1, math.min(math.max(data.Num or 1, 1), MAX_PELLETS) do
		local d = dir
		if sx > 0 or sy > 0 then
			d = dir + right * ((math.Rand(-0.5, 0.5) + math.Rand(-0.5, 0.5)) * sx) + up * ((math.Rand(-0.5, 0.5) + math.Rand(-0.5, 0.5)) * sy)
			d:Normalize()
		end
		local tr = util.TraceLine({ start = src, endpos = src + d * dist, filter = { ent, owner }, mask = MASK_SHOT })
		local p, dd = W.Near(src, tr.HitPos, eye, radius, drop)
		if p and (not bestD or dd < bestD) then best, bestD, bestDir = p, dd, d end
	end
	return best, bestDir, bestD
end

local function onBullets(ent, data)
	if (A.cfg.whiz or 1) < 0.5 or not A.Enabled() then return end
	-- the engine whizzes only for a tracer it draws
	local freq = data.Tracer
	if not freq or freq <= 0 then return end
	local c = (counts[ent] or 0) + 1
	counts[ent] = c
	if not W.TracerDrawn(freq, c) then return end
	if not data.Src or not data.Dir then return end
	local kind = W.Kind(data.TracerName)
	local now = CurTime()
	for _, ply in ipairs(player.GetAll()) do
		if ply:Alive() and not isShooter(ply, ent) and now >= (nextWhiz[ply] or 0) then
			local p, d = W.Miss(ent, data, ply, kind)
			if p then
				nextWhiz[ply] = now + W.GAP
				net.Start("pba_whiz")
				net.WriteVector(p)
				net.WriteNormal(d)
				net.WriteUInt(kind, 2)
				net.Send(ply)
				A.stats.whiz = (A.stats.whiz or 0) + 1
			end
		end
	end
end

hook.Add("EntityFireBullets", "pba_whiz", onBullets)
