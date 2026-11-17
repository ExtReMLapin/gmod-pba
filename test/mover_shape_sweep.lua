-- Sweep of the moving brushes of many maps (client lua_job, no map load: the BSPs are read from disk).
-- For each mover (func_movelinear, func_tracktrain, func_rotating, func_physbox(_multiplayer) with a brush model)
-- of the maps matching args.patterns (default: HL2, EP1, EP2): the volume of its bounding box (what entered the
-- Steam Audio scene before) against the volume of its solid brushes (pba.BSP.ModelBrushes + BrushPolygons, what
-- enters it now), and how many triangles that takes.
-- Kinds: "empty" (no brush that stops sound: clips, grates, water; now out of the scene), "hollow" (solid volume
-- under args.hollowFrac = 30 % of the box, and the box over 64 u in each of two dimensions: a cabin, a cage, a
-- gondola the box sealed), "solid" (the rest: the box was about right).
args = args or {}
local patterns = args.patterns or { "d1_*", "d2_*", "d3_*", "ep1_*", "ep2_*" }
local hollowFrac = args.hollowFrac or 0.3
local CLASSES = { func_movelinear = true, func_tracktrain = true, func_rotating = true, func_physbox = true,
	func_physbox_multiplayer = true }
local BSP = pba.BSP

local function polyVolume(polys)
	local v = 0
	for _, p in ipairs(polys) do
		for k = 2, #p - 1 do v = v + p[1]:Dot(p[k]:Cross(p[k + 1])) end
	end
	return math.abs(v) / 6
end

local function modelBounds(map, index)
	local f = file.Open("maps/" .. map .. ".bsp", "rb", "GAME")
	if not f then return nil end
	f:Seek(8)
	local L = {}
	for i = 0, 63 do L[i] = { ofs = f:ReadLong(), len = f:ReadLong() } f:Skip(8) end
	f:Seek(L[14].ofs + index * 48)
	local mn = Vector(f:ReadFloat(), f:ReadFloat(), f:ReadFloat())
	local mx = Vector(f:ReadFloat(), f:ReadFloat(), f:ReadFloat())
	f:Close()
	return mn, mx
end

local maps = {}
for _, pat in ipairs(patterns) do
	for _, m in ipairs((file.Find("maps/" .. pat .. ".bsp", "GAME"))) do maps[#maps + 1] = m:sub(1, -5) end
end
table.sort(maps)
local res = { maps = #maps, movers = 0, kinds = { empty = 0, hollow = 0, solid = 0, unreadable = 0 }, perMap = {}, hollow = {}, empty = {},
	trisMax = 0, msMax = 0 }
for mi, map in ipairs(maps) do
	job:progress(mi, #maps, map)
	local ents = {}
	local f = file.Open("maps/" .. map .. ".bsp", "rb", "GAME")
	if f then
		if f:Read(4) == "VBSP" then
			f:Seek(8)
			local ofs, len = f:ReadLong(), f:ReadLong()
			if ofs and len then
				f:Seek(ofs)
				ents = BSP.ParseEntities(f:Read(len) or "", CLASSES)
			end
		end
		f:Close()
	end
	local row = { movers = 0, hollow = 0, empty = 0 }
	for _, kv in ipairs(ents) do
		local model = kv.model
		if CLASSES[kv.classname] and model and model:sub(1, 1) == "*" then
			local index = tonumber(model:sub(2))
			res.movers, row.movers = res.movers + 1, row.movers + 1
			local t0 = SysTime()
			local brushes = BSP.ModelBrushes(map, index)
			local tris, vol = 0, 0
			if brushes then
				for _, br in ipairs(brushes) do
					local ps = BSP.BrushPolygons(br.planes)
					if #ps >= 4 then
						vol = vol + polyVolume(ps)
						for _, p in ipairs(ps) do tris = tris + #p - 2 end
					end
					job:step()
				end
			end
			local ms = (SysTime() - t0) * 1000
			res.msMax = math.max(res.msMax, ms)
			res.trisMax = math.max(res.trisMax, tris)
			local mn, mx = modelBounds(map, index)
			local sz = mx - mn
			local boxV = sz.x * sz.y * sz.z
			local frac = boxV > 0 and vol / boxV or 1
			local big2 = (sz.x > 64 and 1 or 0) + (sz.y > 64 and 1 or 0) + (sz.z > 64 and 1 or 0) >= 2
			local kind
			if not brushes then kind = "unreadable"
			elseif tris == 0 then kind = "empty"
			elseif frac < hollowFrac and big2 then kind = "hollow"
			else kind = "solid" end
			res.kinds[kind] = res.kinds[kind] + 1
			local item = { map = map, name = kv.targetname, cls = kv.classname, model = model, size = string.format("%.0fx%.0fx%.0f", sz.x, sz.y, sz.z),
				frac = math.Round(frac, 3), tris = tris, ms = math.Round(ms, 2) }
			if kind == "hollow" then row.hollow = row.hollow + 1 res.hollow[#res.hollow + 1] = item end
			if kind == "empty" then row.empty = row.empty + 1 res.empty[#res.empty + 1] = item end
		end
	end
	if row.movers > 0 then res.perMap[map] = row end
	job:step()
end
return res
