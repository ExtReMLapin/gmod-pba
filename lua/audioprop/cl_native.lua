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
	-- displacements (terrain): not in GetBrushSurfaces; read from the BSP, one "ground"
	-- material (thick earth: no transmission)
	local dv, di = A.BSP.LoadDisplacements(game.GetMap())
	if dv and #di > 0 then
		mats[#mats + 1] = { absorption = { 0.15, 0.25, 0.35 }, scattering = 0.3, transmission = { 0.0001, 0.00003, 0.00001 } }
		local mi = #mats - 1
		local base = #verts / 3
		for i = 1, #dv, 3 do
			verts[#verts + 1], verts[#verts + 2], verts[#verts + 3] = dv[i], dv[i + 1], dv[i + 2]
			mins.x, mins.y, mins.z = math.min(mins.x, dv[i]), math.min(mins.y, dv[i + 1]), math.min(mins.z, dv[i + 2])
			maxs.x, maxs.y, maxs.z = math.max(maxs.x, dv[i]), math.max(maxs.y, dv[i + 1]), math.max(maxs.z, dv[i + 2])
		end
		for i = 1, #di do tris[#tris + 1] = base + di[i] end
		for _ = 1, #di / 3 do matIdx[#matIdx + 1] = mi end
		N.dispTris = #di / 3
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
	if N.ready then N.StartRender() end
	if N.ready and (A.cfg.native_paths or 0) >= 0.5 then
		-- the probe graph is built in the background: bake once it is there
		timer.Create("audioprop_native_bake", 1, 120, function()
			if A.Probes and A.Probes.current then timer.Remove("audioprop_native_bake") N.Bake() end
		end)
	end
	if A.Paths then A.Paths.InvalidateCache() end
end

function N.Bake()
	-- probe positions: audioprop's own probe graph (inside the playable volume), thinned until
	-- there are at most audioprop_native_max_probes of them (large open maps)
	local pr = A.Probes and A.Probes.current
	if not pr then N.err = "probe graph not ready" return end
	local step = math.max(math.Round(A.cfg.native_probe_spacing / pr.spacing), 1)
	local pts
	repeat
		pts = {}
		for _, n in ipairs(pr.nodes) do
			if n.i % step == 0 and n.j % step == 0 then pts[#pts + 1] = n.pos end
		end
		step = step + 1
	until #pts <= A.cfg.native_max_probes or step > 64
	local t0 = SysTime()
	N.pathsReady = false
	local ok, err = pcall(audioprop_native.BakePaths, pts, pr.spacing * (step - 1) * 0.75)
	if not ok then N.err = err return end
	N.probes = #pts
	-- the bake runs on a worker thread: poll it
	timer.Create("audioprop_native_bakepoll", 0.25, 0, function()
		if not audioprop_native then timer.Remove("audioprop_native_bakepoll") return end
		local st, info = audioprop_native.BakeStatus()
		if st == "ready" then
			timer.Remove("audioprop_native_bakepoll")
			N.pathsReady, N.bakeMs, N.bakeBytes = true, (SysTime() - t0) * 1000, info
			MsgN(string.format("[audioprop] native paths: %d probes baked in %.0f ms (%d KB)", N.probes, N.bakeMs, (info or 0) / 1024))
			if A.Paths then A.Paths.InvalidateCache() end
		elseif st == "error" then
			timer.Remove("audioprop_native_bakepoll")
			N.err = "bake failed: " .. tostring(info)
			MsgN("[audioprop] native paths: ", N.err)
		end
	end)
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

-- ------------------------------------------------------------------ native rendering

-- 3-band EQ (low / mid / high gain) per low-pass level: same intent as DSP presets 30/31
N.EQ = { [0] = { 1, 1, 1 }, { 1, 0.7, 0.4 }, { 1, 0.5, 0.2 }, { 0.9, 0.3, 0.08 }, { 0.8, 0.18, 0.03 } }
N.failed = N.failed or {}

function N.StartRender()
	N.render = false
	if not N.ready or (A.cfg.native_render or 0) < 0.5 or not audioprop_native.AudioStart then return end
	local ok, err = audioprop_native.AudioStart()
	if not ok then N.err = err MsgN("[audioprop] native audio: ", err) return end
	N.render = true
	MsgN("[audioprop] native rendering on (Steam Audio HRTF)")
end

function N.StopRender()
	if N.render and audioprop_native then audioprop_native.AudioStop() end
	N.render = false
end

local function cleanName(name)
	return string.lower(string.gsub(name or "", "^[%^%)%*#@<>!%?%$&~`+%%%(]+", ""))
end

--- Makes sure the module has decoded `name`. Returns true when playable natively.
function N.EnsureSound(name)
	local n = cleanName(name)
	if N.failed[n] then return false end
	if audioprop_native.HasSound(n) then return true, n end
	local data = file.Read("sound/" .. n, "GAME")
	if not data or #data > 8 * 1024 * 1024 then N.failed[n] = true return false end
	local secs = audioprop_native.LoadSound(n, data)
	if not secs then N.failed[n] = true return false end
	return true, n
end

--- Plays a voice natively. gain: linear, everything included. Returns true on success.
function N.PlayVoice(name, pos, gain, lp, pitch)
	if not N.render then return false end
	local ok, n = N.EnsureSound(name)
	if not ok then return false end
	local eq = N.EQ[math.Clamp(lp or 0, 0, 4)]
	local id = audioprop_native.Play(n, pos, gain * A.cfg.native_gain, eq[1], eq[2], eq[3], pitch or 100, false)
	return id and id > 0
end

hook.Add("Think", "audioprop_native_listener", function()
	if not N.render then return end
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	local ang = ply:EyeAngles()
	local master = GetConVar("volume"):GetFloat()
	if not system.HasFocus() and GetConVar("snd_mute_losefocus"):GetBool() then master = 0 end
	local eL, eR
	N.live, eL, eR = audioprop_native.SetListener(ply:EyePos(), ang:Forward(), ang:Up(), master)
	N.energyL, N.energyR = (N.energyL or 0) + (eL or 0), (N.energyR or 0) + (eR or 0)
end)

cvars.AddChangeCallback("audioprop_native_render", function(_, _, new)
	if tonumber(new) == 1 then N.StartRender() else N.StopRender() end
end, "audioprop_native")

hook.Add("ShutDown", "audioprop_native", function() N.StopRender() end)

hook.Add("InitPostEntity", "audioprop_native", function() timer.Simple(1, N.Start) end)
if A.nativeLoaded then timer.Simple(0.5, N.Start) end
A.nativeLoaded = true
