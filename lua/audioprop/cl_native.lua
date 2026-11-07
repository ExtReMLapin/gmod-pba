-- Optional native backend (gmcl_audioprop + Steam Audio, installed by hand in
-- garrysmod/lua/bin). When present it replaces two Lua estimates:
--   * world transmission and occlusion of the direct line (volumetric: smooth near edges,
--     per-band transmission -> loss and low-pass);
--   * (experimental, audioprop_native_paths 1) baked pathing around the world geometry.
-- Without the module, nothing changes: the Lua model runs as before.

local A = audioprop
local N = A.Native or {}
A.Native = N

local MODULE = "lua/bin/gmcl_audioprop_" .. (jit.arch == "x64" and "win64" or "win32") .. ".dll"
local SKIP_PREFIX = { "tools/toolsclip", "tools/toolsplayerclip", "tools/toolsnpcclip", "tools/toolstrigger",
	"tools/toolshint", "tools/toolsskip", "tools/toolsskybox", "tools/toolsfog", "tools/toolsoccluder" }

-- Steam Audio absorption (low, mid, high) per MAT_*; defaults from its material presets.
local ABSORB = {
	[MAT_CONCRETE] = { 0.05, 0.07, 0.08 }, [MAT_TILE] = { 0.03, 0.04, 0.07 }, [MAT_WOOD] = { 0.11, 0.07, 0.06 },
	[MAT_METAL] = { 0.20, 0.07, 0.06 }, [MAT_GLASS] = { 0.06, 0.03, 0.02 }, [MAT_DIRT] = { 0.15, 0.25, 0.35 },
	[MAT_GRASS] = { 0.11, 0.26, 0.60 }, [MAT_SAND] = { 0.15, 0.30, 0.45 }, [MAT_PLASTIC] = { 0.10, 0.10, 0.10 },
}

local function skipMaterial(name)
	for _, p in ipairs(SKIP_PREFIX) do if string.StartWith(name, p) then return true end end
	return false
end

--- Steam Audio material for a surfaceprop: transmission derived from audioprop's own wall
-- table at a typical wall thickness (16 units), split into bands (LF bonus, -10 dB HF).
local function saMaterial(surf, cfg)
	local idx = util.GetSurfaceIndex(surf or "default")
	local data = util.GetSurfaceData(idx >= 0 and idx or 0)
	local mat = data and data.material or MAT_CONCRETE
	local R = A.AC.WallLoss(mat, surf, 16) * cfg.trans_scale
	local tm = 10 ^ (-R / 20)
	return {
		absorption = ABSORB[mat] or { 0.10, 0.10, 0.10 },
		scattering = 0.05,
		transmission = { math.min(tm * 10 ^ (cfg.trans_lf_bonus / 20), 1), tm, tm * 10 ^ (-10 / 20) },
	}
end

--- Triangulated world (fan per brush surface) + material list. Returns verts, tris, matIdx, mats, mins, maxs.
function N.BuildWorld()
	local verts, tris, matIdx, mats, matOf = {}, {}, {}, {}, {}
	local mins, maxs = Vector(math.huge, math.huge, math.huge), Vector(-math.huge, -math.huge, -math.huge)
	for _, s in ipairs(game.GetWorld():GetBrushSurfaces() or {}) do
		local m = s:GetMaterial()
		local name = m and m:GetName() or ""
		if not s:IsSky() and not s:IsWater() and not skipMaterial(name) then
			local surf = m and m:GetString("$surfaceprop") or "default"
			local mi = matOf[surf]
			if not mi then
				mats[#mats + 1] = saMaterial(surf, A.cfg)
				mi = #mats - 1
				matOf[surf] = mi
			end
			local vs = s:GetVertices()
			local base = #verts / 3
			for _, v in ipairs(vs) do
				verts[#verts + 1], verts[#verts + 2], verts[#verts + 3] = v.x, v.y, v.z
				mins.x, mins.y, mins.z = math.min(mins.x, v.x), math.min(mins.y, v.y), math.min(mins.z, v.z)
				maxs.x, maxs.y, maxs.z = math.max(maxs.x, v.x), math.max(maxs.y, v.y), math.max(maxs.z, v.z)
			end
			for k = 2, #vs - 1 do
				tris[#tris + 1], tris[#tris + 2], tris[#tris + 3] = base, base + k - 1, base + k
				matIdx[#matIdx + 1] = mi
			end
		end
	end
	return verts, tris, matIdx, mats, mins, maxs
end

function N.Start()
	N.ready, N.pathsReady, N.err = false, false, nil
	if (A.cfg.native or 1) < 0.5 then return end
	if not file.Exists(MODULE, "GAME") then N.err = "module not installed" return end
	if not audioprop_native then
		local ok, err = pcall(require, "audioprop")
		if not ok or not audioprop_native then N.err = "require failed: " .. tostring(err) return end
	end
	local ok, err = audioprop_native.Init()
	if not ok then N.err = err return end
	local t0 = SysTime()
	local verts, tris, matIdx, mats, mins, maxs = N.BuildWorld()
	local nt = audioprop_native.LoadWorld(verts, tris, matIdx, mats)
	N.loadMs = (SysTime() - t0) * 1000
	N.tris, N.mins, N.maxs = nt, mins, maxs
	N.ready = nt > 0
	MsgN(string.format("[audioprop] native backend: Steam Audio %d, %d triangles, %d materials, %.0f ms",
		audioprop_native.Version(), nt, #mats, N.loadMs))
	if N.ready and (A.cfg.native_paths or 0) >= 0.5 then
		-- the probe graph is built in the background: bake once it is there
		timer.Create("audioprop_native_bake", 1, 120, function()
			if A.Probes and A.Probes.current then timer.Remove("audioprop_native_bake") N.Bake() end
		end)
	end
	if A.Paths then A.Paths.InvalidateCache() end
end

function N.Bake()
	local t0 = SysTime()
	-- probe positions: audioprop's own probe graph (inside the playable volume), thinned to
	-- the requested spacing
	local pr = A.Probes and A.Probes.current
	if not pr then N.err = "probe graph not ready" return end
	local step = math.max(math.Round(A.cfg.native_probe_spacing / pr.spacing), 1)
	local pts = {}
	for _, n in ipairs(pr.nodes) do
		if n.i % step == 0 and n.j % step == 0 then pts[#pts + 1] = n.pos end
	end
	local np, bytes = audioprop_native.BakePaths(pts, pr.spacing * step * 0.75)
	N.bakeMs, N.probes, N.bakeBytes = (SysTime() - t0) * 1000, np, bytes
	N.pathsReady = np > 0
	MsgN(string.format("[audioprop] native paths: %d probes baked in %.0f ms (%d KB)", np, N.bakeMs, bytes / 1024))
end

--- Direct line through the world: occlusion (1 = clear) and per-band transmission.
function N.Direct(S, L)
	if not N.ready then return nil end
	local r = audioprop_native.Direct({ S }, L, 16)
	return r and r[1]
end

--- Baked path from S to L: eq gains (low, mid, high) and arrival direction at L.
function N.Path(S, L)
	if not N.pathsReady then return nil end
	local r = audioprop_native.Paths({ S }, L)
	return r and r[1]
end

hook.Add("InitPostEntity", "audioprop_native", function() timer.Simple(1, N.Start) end)
if A.nativeLoaded then timer.Simple(0.5, N.Start) end
A.nativeLoaded = true
