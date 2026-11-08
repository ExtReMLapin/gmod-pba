-- Invisible / tool brushes (toolsinvisible, toolsblockbullets, clips, sky...) are mapper tools, not
-- walls: sound must cross them for free, while the nodraw faces of real walls stay walls. Reads the
-- map's own brushes (BSP lumps 1 PLANES, 2 TEXDATA, 6 TEXINFO, 18 BRUSHES, 19 BRUSHSIDES, 43/44 texture
-- names), groups them by kind, and for brushes standing in open air (both sides free) measures the loss
-- pba.Paths charges across them. lua_job, client realm, any map.
-- Returns { pass, map, perKind = { [kind] = { brushes, contents, tested, hitByWallTrace, maxDb, meanDb, sample } } }.
-- pass: every invisible kind costs <= MAXLOSS dB and blocks no probe link; real walls behind a nodraw
-- face, sky and translucent (window) brushes are reported, not judged. toolsblockbullets is in
-- d2_coast_04, d2_coast_12, d3_c17_13 (compiled CONTENTS_WINDOW | CONTENTS_TRANSLUCENT, as glass).
local MAXLOSS = 3
local PER_KIND = 24 -- brushes tested per kind (open air found among them)
-- kinds a listener cannot see nor stand behind: sound should pass
local INVISIBLE = {
	["TOOLS/TOOLSINVISIBLE"] = true, ["TOOLS/TOOLSBLOCKBULLETS"] = true, ["TOOLS/TOOLSPLAYERCLIP"] = true,
	["TOOLS/TOOLSNPCCLIP"] = true, ["TOOLS/TOOLSCLIP"] = true, ["TOOLS/TOOLSBLOCKLIGHT"] = true,
	["TOOLS/TOOLSBLOCK_LOS"] = true, ["TOOLS/TOOLSINVISIBLELADDER"] = true, ["TOOLS/TOOLSOCCLUDER"] = true,
	["TOOLS/TOOLSHINT"] = true, ["TOOLS/TOOLSSKIP"] = true, ["TOOLS/TOOLSTRIGGER"] = true,
	["TOOLS/TOOLSAREAPORTAL"] = true, ["TOOLS/TOOLSFOG"] = true,
}

local f = file.Open("maps/" .. game.GetMap() .. ".bsp", "rb", "GAME")
if not f then return { pass = false, error = "bsp not readable" } end
f:Seek(8)
local L = {}
for i = 0, 63 do
	L[i] = { ofs = f:ReadLong(), len = f:ReadLong(), ver = f:ReadLong(), unc = f:ReadLong() }
end
for _, i in ipairs({ 1, 2, 6, 18, 19, 43, 44 }) do
	if L[i].unc ~= 0 and L[i].len > 0 then f:Close() return { pass = false, error = "compressed lump " .. i } end
end
local function seek(i) f:Seek(L[i].ofs) return L[i].len end
-- texture names
local strData = (function() seek(43) return f:Read(L[43].len) end)()
local strTable = {}
for k = 0, seek(44) / 4 - 1 do strTable[k] = f:ReadLong() end
local function cstr(o) local e = strData:find("\0", o + 1, true) return strData:sub(o + 1, (e or #strData + 1) - 1) end
local texdata = {}
for k = 0, seek(2) / 32 - 1 do
	f:Skip(12)
	local id = f:ReadLong()
	f:Skip(16)
	texdata[k] = string.upper(cstr(strTable[id] or 0))
end
local texinfo = {}
for k = 0, seek(6) / 72 - 1 do
	f:Skip(64)
	local flags, td = f:ReadLong(), f:ReadLong()
	texinfo[k] = { name = texdata[td] or "?", flags = flags }
end
job:progress("planes")
local planes = {}
for k = 0, seek(1) / 20 - 1 do
	planes[k] = { f:ReadFloat(), f:ReadFloat(), f:ReadFloat(), f:ReadFloat() }
	f:Skip(4)
	if k % 4000 == 0 then job:step() end
end
local sides = {}
for k = 0, seek(19) / 8 - 1 do
	local pn, ti = f:ReadUShort(), f:ReadShort()
	f:Skip(2)
	local bevel = f:ReadByte()
	f:Skip(1)
	sides[k] = { pn, ti, bevel }
	if k % 4000 == 0 then job:step() end
end
local brushes = {}
for k = 0, seek(18) / 12 - 1 do
	brushes[k] = { f:ReadLong(), f:ReadLong(), f:ReadLong() }
end
f:Close()

-- brush -> kind, AABB (from its axial planes: vbsp gives every brush its 6 axial bevels)
local kinds = {}
local function kindOf(b)
	local tools, visible = {}, 0
	for s = b[1], b[1] + b[2] - 1 do
		local sd = sides[s]
		if sd and sd[3] == 0 and sd[2] >= 0 then
			local n = texinfo[sd[2]] and texinfo[sd[2]].name or "?"
			if n:sub(1, 6) == "TOOLS/" then tools[n] = true else visible = visible + 1 end
		end
	end
	-- toolsblockbullets ($translucent) compiles to CONTENTS_WINDOW like glass: kind by texture first
	if visible > 0 then
		if bit.band(b[3], CONTENTS_WINDOW) ~= 0 then return "window (visible translucent brush)" end
		if tools["TOOLS/TOOLSNODRAW"] then return "real wall with nodraw faces" end
		return nil -- an ordinary brush
	end
	local one
	for n in pairs(tools) do one = (one and one ~= n) and (one .. "+" .. n) or n end
	return one
end
local function texOf(b)
	local t = {}
	for s = b[1], b[1] + b[2] - 1 do
		local sd = sides[s]
		if sd and sd[2] >= 0 and texinfo[sd[2]] then t[texinfo[sd[2]].name] = true end
	end
	return t
end
local function aabb(b)
	local mn, mx = Vector(-1e9, -1e9, -1e9), Vector(1e9, 1e9, 1e9)
	for s = b[1], b[1] + b[2] - 1 do
		local p = planes[sides[s][1]]
		if p then
			if p[1] == 1 then mx.x = math.min(mx.x, p[4]) elseif p[1] == -1 then mn.x = math.max(mn.x, -p[4])
			elseif p[2] == 1 then mx.y = math.min(mx.y, p[4]) elseif p[2] == -1 then mn.y = math.max(mn.y, -p[4])
			elseif p[3] == 1 then mx.z = math.min(mx.z, p[4]) elseif p[3] == -1 then mn.z = math.max(mn.z, -p[4]) end
		end
	end
	return mn, mx
end
local count = 0
for k, b in pairs(brushes) do
	local kind = kindOf(b)
	if kind then
		local K = kinds[kind] or { brushes = 0, contents = {}, list = {} }
		kinds[kind] = K
		K.brushes = K.brushes + 1
		K.contents[string.format("0x%x", b[3])] = (K.contents[string.format("0x%x", b[3])] or 0) + 1
		K.list[#K.list + 1] = b
	end
	count = count + 1
	if count % 2000 == 0 then job:step() end
end

-- open air test: through the brush along its thinner axes, 24 u past each face
local FREE = bit.bor(MASK_PLAYERSOLID, CONTENTS_GRATE, CONTENTS_WINDOW)
local function noEnt() return false end
local wallMask = bit.band(MASK_SOLID, bit.bnot(CONTENTS_GRATE)) -- what P.Walls traces
local function inBox(p, mn, mx) return p:WithinAABox(mn - Vector(1, 1, 1), mx + Vector(1, 1, 1)) end
local perKind = {}
local pass = true
for kind, K in pairs(kinds) do
	local R = { brushes = K.brushes, contents = K.contents, tested = 0, hitByWallTrace = 0, maxDb = 0, sumDb = 0, samples = {}, linkBlocked = 0 }
	-- can the wall trace (MASK_SOLID minus grates) hit this kind at all?
	R.wallMaskContents = false
	for c in pairs(K.contents) do if bit.band(tonumber(c), wallMask) ~= 0 then R.wallMaskContents = true end end
	-- spread the samples over the brush list
	local step = math.max(1, math.floor(#K.list / (PER_KIND * 4)))
	for i = 1, #K.list, step do
		if R.tested >= PER_KIND then break end
		local b = K.list[i]
		local mn, mx = aabb(b)
		local ext = mx - mn
		if ext.x < 1e8 and ext.y < 1e8 and ext.z < 1e8 then
			local c = (mn + mx) * 0.5
			local axes = { { ext.x, Vector(1, 0, 0) }, { ext.y, Vector(0, 1, 0) }, { ext.z, Vector(0, 0, 1) } }
			table.sort(axes, function(a, b2) return a[1] < b2[1] end)
			for _, ax in ipairs(axes) do
				local S, Lp = c + ax[2] * (ax[1] / 2 + 24), c - ax[2] * (ax[1] / 2 + 24)
				if bit.band(util.PointContents(S), FREE) == 0 and bit.band(util.PointContents(Lp), FREE) == 0 then
					-- the brush is the only thing between S and L (any contents, world only)
					local m = bit.bor(MASK_SOLID, b[3])
					local t1 = util.TraceLine({ start = S, endpos = Lp, mask = m, filter = noEnt })
					local t2 = util.TraceLine({ start = Lp, endpos = S, mask = m, filter = noEnt })
					local own = texOf(b)
					if t1.Hit and t2.Hit and t1.HitWorld and inBox(t1.HitPos, mn, mx) and inBox(t2.HitPos, mn, mx)
						and own[string.upper(t1.HitTexture or "")] and own[string.upper(t2.HitTexture or "")] then
						local w = util.TraceLine({ start = S, endpos = Lp, mask = wallMask, filter = noEnt })
						-- something else inside the brush volume (terrain, a static prop): not open air
						if not w.Hit or (own[string.upper(w.HitTexture or "")] and inBox(w.HitPos, mn, mx)) then
							local walls = pba.Paths.Walls(S, Lp, 6)
							local loss = #walls > 0 and pba.Paths.EvalWalls(walls, pba.cfg, true) or 0
							R.tested = R.tested + 1
							if w.Hit then R.hitByWallTrace = R.hitByWallTrace + 1 end
							-- probe links (path finding) cross it too, else paths detour round it
							if pba.Probes and pba.Probes.ClearSeg and not pba.Probes.ClearSeg(S, Lp) then
								R.linkBlocked = R.linkBlocked + 1
							end
							R.sumDb = R.sumDb + loss
							R.maxDb = math.max(R.maxDb, loss)
							if #R.samples < 4 then
								local names = {}
								for n in pairs(own) do names[#names + 1] = n end
								table.sort(names)
								R.samples[#R.samples + 1] = string.format("%.1f dB contents=0x%x surf=%s at %d %d %d thick %d [%s]",
									loss, b[3], walls[1] and walls[1].surf or "-", c.x, c.y, c.z, ax[1], table.concat(names, ","))
							end
							break
						end
					end
				end
			end
		end
		job:step()
	end
	R.meanDb = R.tested > 0 and math.Round(R.sumDb / R.tested, 1) or nil
	R.sumDb = nil
	R.maxDb = math.Round(R.maxDb, 1)
	R.invisible = INVISIBLE[kind] or nil
	if INVISIBLE[kind] and (R.maxDb > MAXLOSS or R.linkBlocked > 0) then pass = false end
	perKind[kind] = R
end
return { pass = pass, map = game.GetMap(), perKind = perKind }
