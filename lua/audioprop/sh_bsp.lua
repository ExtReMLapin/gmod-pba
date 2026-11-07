-- Minimal Source BSP reader: only the lumps audioprop needs.
--   0 ENTITIES (func_areaportal links), 1 PLANES, 5 NODES, 10 LEAFS (area of each leaf), 14 MODELS,
--   20 AREAS, 21 AREAPORTALS, 41 CLIPPORTALVERTS (portal polygons).
-- Layouts from the public Source SDK 2013 bspfile.h (facts only).

local A = audioprop
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
		if not keep or keep[cls] or string.StartWith(cls, "info_player") then out[#out + 1] = kv end
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
