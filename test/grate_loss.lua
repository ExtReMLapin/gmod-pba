-- Grates, fences, grilles (CONTENTS_GRATE: "bullets/sight pass through"): the wall model must charge
-- the small fixed grate loss, whatever surfaceprop the texture declares (a grate in "metal" cost
-- 30-50 dB). lua_job, client realm, on any map with grate brushes (d1_canals_01, d1_town_01...).
-- Returns { pass, found, worst = max loss (dB) across a grate, samples = {...} }.
local MAXLOSS = 3
local found, worst, samples, linkBlocked, inScene = 0, 0, {}, 0, 0
local surfs = game.GetWorld():GetBrushSurfaces() or {}
job:progress(0, #surfs, "scanning brush surfaces")
local tr = {}
for i, s in ipairs(surfs) do
	if found >= 12 then break end
	if not s:IsNoDraw() and not s:IsSky() and not s:IsWater() then
		local v = s:GetVertices()
		if #v >= 3 then
			local c = Vector()
			for _, p in ipairs(v) do c:Add(p) end
			c:Div(#v)
			local n = (v[2] - v[1]):Cross(v[3] - v[1])
			if n:LengthSqr() > 1e-6 then
				n:Normalize()
				util.TraceLine({ start = c + n * 4, endpos = c - n * 4, mask = MASK_SOLID, filter = function() return false end, output = tr })
				if tr.Hit and bit.band(tr.Contents or 0, CONTENTS_GRATE) ~= 0 then
					-- both sides open for 48 u (a fence in the open, not a grate on a wall)
					local S, L = c + n * 48, c - n * 48
					-- a grate in the open: the line S -> L meets it first, and nothing else (not a wall it
					-- is mounted on)
					local tr2 = util.TraceLine({ start = S, endpos = L, mask = MASK_SOLID })
					local tr3 = util.TraceLine({ start = S, endpos = L, mask = bit.band(MASK_SOLID, bit.bnot(CONTENTS_GRATE)) })
					if tr2.Hit and bit.band(tr2.Contents or 0, CONTENTS_GRATE) ~= 0 and not tr3.Hit then
						local walls = pba.Paths.Walls(S, L, 6)
						local loss = #walls > 0 and pba.Paths.EvalWalls(walls, pba.cfg, true) or 0
						found = found + 1
						-- probe links cross it too (else probe paths detour round every fence)
						if not pba.Probes.ClearSeg(S, L) then linkBlocked = linkBlocked + 1 end
						-- and the Steam Audio scene leaves it out (no reverb bouncing on a fence)
						if pba.Native and pba.Native.IsGrateSurface and not pba.Native.IsGrateSurface(s) then inScene = inScene + 1 end
						worst = math.max(worst, loss)
						samples[#samples + 1] = string.format("%s surf=%s loss=%.1f dB at %d %d %d",
							s:GetMaterial():GetName(), tostring(walls[1] and walls[1].surf or "-"), loss, c.x, c.y, c.z)
					end
				end
			end
		end
	end
	if i % 500 == 0 then job:progress(i, #surfs, found .. " grates") end
	job:step()
end
return { pass = found > 0 and worst <= MAXLOSS and linkBlocked == 0 and inScene == 0, found = found, worst = worst,
	linkBlocked = linkBlocked, inScene = inScene, samples = samples }
