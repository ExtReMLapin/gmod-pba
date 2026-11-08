-- Minimal Source BSP reader: only the lumps pba needs.
--   0 ENTITIES (func_areaportal links), 1 PLANES, 5 NODES, 10 LEAFS (area of each leaf), 14 MODELS,
--   20 AREAS, 21 AREAPORTALS, 41 CLIPPORTALVERTS (portal polygons).
-- Layouts from the public Source SDK 2013 bspfile.h (facts only).

local A = pba
local BSP = {}
A.BSP = BSP

local HEADER_LUMPS = 64

local function lumpInfo(f)
	local info = {}
	f:Seek(8)
	for i = 0, HEADER_LUMPS - 1 do
		local ofs, len, ver = f:ReadLong(), f:ReadLong(), f:ReadLong()
		local unc = f:ReadLong() -- fourCC / uncompressed size, 0 when not compressed
		info[i] = { ofs = ofs, len = len, ver = ver, unc = unc }
	end
	return info
end

--- Parses the entity lump text into a list of keyvalue tables, keeping only `keep` classes.
function BSP.ParseEntities(text, keep)
	local out = {}
	for block in string.gmatch(text, "%b{}") do
		local kv = {}
		for k, v in string.gmatch(block, '"([^"]*)"%s*"([^"]*)"') do
			kv[string.lower(k)] = v
		end
		local cls = kv.classname or ""
		-- also named brush entities (func_brush, doors...): areaportals target them
		local namedBrush = kv.targetname and kv.model and string.sub(kv.model, 1, 1) == "*"
		if not keep or keep[cls] or namedBrush or string.StartWith(cls, "info_player") then out[#out + 1] = kv end
	end
	return out
end

local ENT_KEEP = { -- door entities are kept for the portal <-> door matching
	func_areaportal = true, func_areaportalwindow = true,
	prop_door_rotating = true, func_door = true, func_door_rotating = true,
}

--- Reads maps/<map>.bsp. Returns a table or nil, reason.
function BSP.Load(map)
	local path = "maps/" .. map .. ".bsp"
	local f = file.Open(path, "rb", "GAME")
	if not f then return nil, "cannot open " .. path end
	local ident = f:Read(4)
	if ident ~= "VBSP" then f:Close() return nil, "not a VBSP file" end
	local version = f:ReadLong()
	local L = lumpInfo(f)
	for _, i in ipairs({ 0, 1, 5, 10, 14, 20, 21, 41 }) do
		if L[i].unc ~= 0 and L[i].len > 0 then
			f:Close()
			return nil, "compressed lump " .. i
		end
	end
	local b = { map = map, version = version, size = f:Size() }

	-- entities
	f:Seek(L[0].ofs)
	b.entities = BSP.ParseEntities(f:Read(L[0].len) or "", ENT_KEEP)

	-- planes (dplane_t, 20 bytes)
	local np = L[1].len / 20
	local px, py, pz, pd = {}, {}, {}, {}
	f:Seek(L[1].ofs)
	for i = 0, np - 1 do
		px[i], py[i], pz[i], pd[i] = f:ReadFloat(), f:ReadFloat(), f:ReadFloat(), f:ReadFloat()
		f:Skip(4)
	end
	b.px, b.py, b.pz, b.pd = px, py, pz, pd

	-- nodes (dnode_t, 32 bytes): planenum, children[2], then skip
	local nn = L[5].len / 32
	local npl, c0, c1 = {}, {}, {}
	f:Seek(L[5].ofs)
	for i = 0, nn - 1 do
		npl[i], c0[i], c1[i] = f:ReadLong(), f:ReadLong(), f:ReadLong()
		f:Skip(20)
	end
	b.npl, b.c0, b.c1 = npl, c0, c1

	-- leafs: contents(int), cluster(short), area:9|flags:7 (short) then the rest
	local leafSize = (L[10].ver == 0) and 56 or 32
	local nl = math.floor(L[10].len / leafSize)
	local leafArea = {}
	f:Seek(L[10].ofs)
	for i = 0, nl - 1 do
		f:Skip(6)
		leafArea[i] = bit.band(f:ReadUShort(), 0x1FF)
		f:Skip(leafSize - 8)
	end
	b.leafArea = leafArea

	-- brush models (dmodel_t, 48 bytes): bounds of *N (brush doors)
	local models = {}
	f:Seek(L[14].ofs)
	for i = 0, L[14].len / 48 - 1 do
		local mins = Vector(f:ReadFloat(), f:ReadFloat(), f:ReadFloat())
		local maxs = Vector(f:ReadFloat(), f:ReadFloat(), f:ReadFloat())
		f:Skip(24)
		models[i] = { mins = mins, maxs = maxs }
	end
	b.models = models

	-- clip portal verts
	local verts = {}
	f:Seek(L[41].ofs)
	for i = 0, L[41].len / 12 - 1 do
		verts[i] = Vector(f:ReadFloat(), f:ReadFloat(), f:ReadFloat())
	end

	-- areaportals (dareaportal_t, 12 bytes)
	local aps = {}
	f:Seek(L[21].ofs)
	for i = 0, L[21].len / 12 - 1 do
		local key, other, first, count, plane = f:ReadUShort(), f:ReadUShort(), f:ReadUShort(), f:ReadUShort(), f:ReadLong()
		local poly = {}
		for k = 0, count - 1 do poly[#poly + 1] = verts[first + k] end
		aps[i] = { key = key, other = other, poly = poly, plane = plane }
	end

	-- areas (darea_t, 8 bytes)
	local areas = {}
	f:Seek(L[20].ofs)
	for i = 0, L[20].len / 8 - 1 do
		local n, first = f:ReadLong(), f:ReadLong()
		local list = {}
		for k = first, first + n - 1 do list[#list + 1] = aps[k] end
		areas[i] = list
	end
	b.areas = areas
	b.numAreas = L[20].len / 8
	f:Close()
	return b
end

--- Displacement surfaces as triangles (terrain): flat vertex list {x,y,z,...} and 0-based
-- index list. Reads lumps 3 VERTEXES, 7 FACES, 12 EDGES, 13 SURFEDGES, 26 DISPINFO,
-- 33 DISP_VERTS. Grid = bilinear interpolation of the face corners (starting at
-- startPosition) + per-vertex offset (vec * dist).
function BSP.LoadDisplacements(map, swap)
	local f = file.Open("maps/" .. map .. ".bsp", "rb", "GAME")
	if not f then return nil, "cannot open" end
	if f:Read(4) ~= "VBSP" then f:Close() return nil, "not VBSP" end
	f:ReadLong()
	local L = lumpInfo(f)
	for _, i in ipairs({ 3, 7, 12, 13, 26, 33 }) do
		if L[i].unc ~= 0 and L[i].len > 0 then f:Close() return nil, "compressed lump " .. i end
	end
	local ndisp = L[26].len / 176
	if ndisp == 0 then f:Close() return {}, {} end
	local function vec() return Vector(f:ReadFloat(), f:ReadFloat(), f:ReadFloat()) end
	-- dispinfo: startPosition, DispVertStart, power, MapFace
	local infos = {}
	for i = 0, ndisp - 1 do
		if BSP.Yield then BSP.Yield() end -- optional: lets a caller spread the work over frames
		f:Seek(L[26].ofs + i * 176)
		local start = vec()
		local vstart = f:ReadLong()
		f:ReadLong() -- DispTriStart
		local power = f:ReadLong()
		f:Skip(12) -- minTess, smoothingAngle, contents
		local face = f:ReadUShort()
		infos[#infos + 1] = { start = start, vstart = vstart, power = power, face = face }
	end
	local verts, idx = {}, {}
	for _, d in ipairs(infos) do
		if BSP.Yield then BSP.Yield() end
		-- face corners
		f:Seek(L[7].ofs + d.face * 56 + 4)
		local firstedge, numedges = f:ReadLong(), f:ReadShort()
		if numedges == 4 then
			local corners = {}
			for k = 0, 3 do
				f:Seek(L[13].ofs + (firstedge + k) * 4)
				local se = f:ReadLong()
				f:Seek(L[12].ofs + math.abs(se) * 4)
				local v0, v1 = f:ReadUShort(), f:ReadUShort()
				local vi = se >= 0 and v0 or v1
				f:Seek(L[3].ofs + vi * 12)
				corners[k + 1] = vec()
			end
			-- rotate so that corners[1] is the one closest to startPosition
			local best, bd = 1, math.huge
			for k = 1, 4 do
				local dd = corners[k]:DistToSqr(d.start)
				if dd < bd then best, bd = k, dd end
			end
			local c = {}
			for k = 0, 3 do c[k + 1] = corners[(best - 1 + k) % 4 + 1] end
			local size = 2 ^ d.power + 1
			local base = #verts / 3
			f:Seek(L[33].ofs + d.vstart * 20)
			for y = 0, size - 1 do
				local ty = y / (size - 1)
				local e0, e1
				if swap then
					e0 = c[1] + (c[4] - c[1]) * ty
					e1 = c[2] + (c[3] - c[2]) * ty
				else
					e0 = c[1] + (c[2] - c[1]) * ty
					e1 = c[4] + (c[3] - c[4]) * ty
				end
				for x = 0, size - 1 do
					local p = e0 + (e1 - e0) * (x / (size - 1))
					local off = vec()
					local dist = f:ReadFloat()
					f:Skip(4) -- alpha
					p = p + off * dist
					verts[#verts + 1], verts[#verts + 2], verts[#verts + 3] = p.x, p.y, p.z
				end
			end
			for y = 0, size - 2 do
				for x = 0, size - 2 do
					local a = base + y * size + x
					local b, c2, d2 = a + 1, a + size, a + size + 1
					idx[#idx + 1], idx[#idx + 2], idx[#idx + 3] = a, c2, b
					idx[#idx + 1], idx[#idx + 2], idx[#idx + 3] = b, c2, d2
				end
			end
		end
	end
	f:Close()
	return verts, idx
end

--- Leaf index containing point p.
function BSP.PointLeaf(b, p)
	local x, y, z = p.x, p.y, p.z
	local node = 0
	local npl, c0, c1, px, py, pz, pd = b.npl, b.c0, b.c1, b.px, b.py, b.pz, b.pd
	local guard = 0
	while node >= 0 do
		local pl = npl[node]
		if not pl then return 0 end
		if x * px[pl] + y * py[pl] + z * pz[pl] - pd[pl] >= 0 then node = c0[node] else node = c1[node] end
		guard = guard + 1
		if guard > 4096 then return 0 end
	end
	return -1 - node
end

--- Area index of point p (0 = outside / solid).
function BSP.PointArea(b, p)
	return b.leafArea[BSP.PointLeaf(b, p)] or 0
end
