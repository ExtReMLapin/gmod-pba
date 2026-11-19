-- Optional native backend (gmcl_pba + Steam Audio, installed by hand in
-- garrysmod/lua/bin). Feature set (client options, Spawn menu > Utilities > pba):
--   * native rendering (HRTF or speakers, EQ, air absorption, directivity, delay);
--   * room reverb and per-source echoes (Steam Audio reflections, background thread);
--   * baked paths rendered as a sound field, bake kept on disk.
-- When present it also replaces two Lua estimates:
--   * world transmission and occlusion of the direct line (volumetric: smooth near edges,
--     per-band transmission -> loss and low-pass);
--   * (experimental, pba_native_paths 1) baked pathing around the world geometry.
-- Without the module, nothing changes: the Lua model runs as before.

local A = pba
if A.JitFile then A.JitFile("cl_native") end -- LuaJIT per file: pba_lua_interp (sh_config.lua)
local N = A.Native or {}
A.Native = N

local MODULE = "lua/bin/gmcl_pba_win64.dll" -- (64-bit only: N.InstallProblem)
-- Module compatibility. The Lua comes from the Workshop (updated by itself), the module is installed by hand: it
-- can be of another version. pba_native.ModuleVersion() -> version text (the addon's pba.VERSION it was built
-- from), API number (raised in native/src/pba_native.cpp, PBA_NATIVE_API, when a function changes). This Lua
-- accepts the API range N.API_MIN..N.API_MAX; any other module, or one without ModuleVersion (older than this
-- check), is left unused as if it were not installed. No automatic update.
N.API_MIN, N.API_MAX = 1, 3 -- (2: pausable voices, N.PauseFlag; a module of API 1 is used without the pause. 3: PhononLevel; a module of API 2 is used, its phonon.dll of unknown level: N.PhononFixed() = nil)

local UPDATE_HINT = "update gmcl_pba_win64.dll and phonon.dll in garrysmod/lua/bin with the ones of the PBA release matching the addon"

-- -> true, nil, version, api | false, message, version, api (mod: the module's table, pba_native)
function N.CheckModule(mod)
	if type(mod) ~= "table" then return false, "native module not loaded" end
	local range = N.API_MIN == N.API_MAX and tostring(N.API_MIN) or (N.API_MIN .. "-" .. N.API_MAX)
	if type(mod.ModuleVersion) ~= "function" then
		return false, string.format("native module not up to date: API %s expected, an older version (without a version number) is installed; %s (addon %s)",
			range, UPDATE_HINT, tostring(A.VERSION))
	end
	local ok, ver, api = pcall(mod.ModuleVersion)
	if not ok or type(api) ~= "number" then
		return false, string.format("native module version unreadable (%s); %s", tostring(ok and api or ver), UPDATE_HINT)
	end
	ver = tostring(ver)
	if api < N.API_MIN then
		return false, string.format("native module not up to date: API %s expected, API %d installed (module %s, addon %s); %s",
			range, api, ver, tostring(A.VERSION), UPDATE_HINT), ver, api
	end
	if api > N.API_MAX then
		return false, string.format("native module newer than the addon: API %s expected, API %d installed (module %s, addon %s); %s",
			range, api, ver, tostring(A.VERSION), UPDATE_HINT), ver, api
	end
	return true, nil, ver, api
end

local SKIP_PREFIX = { "tools/toolsclip", "tools/toolsplayerclip", "tools/toolsnpcclip", "tools/toolstrigger",
	"tools/toolshint", "tools/toolsskip", "tools/toolsskybox", "tools/toolsfog", "tools/toolsoccluder" }

-- Steam Audio absorption (low, mid, high) per MAT_*; defaults from its material presets.
local ABSORB = {
	[MAT_CONCRETE] = { 0.05, 0.07, 0.08 }, [MAT_TILE] = { 0.01, 0.02, 0.02 }, [MAT_WOOD] = { 0.11, 0.07, 0.06 },
	[MAT_METAL] = { 0.20, 0.07, 0.06 }, [MAT_GLASS] = { 0.06, 0.03, 0.02 }, [MAT_DIRT] = { 0.15, 0.25, 0.35 },
	[MAT_GRASS] = { 0.11, 0.26, 0.60 }, [MAT_SAND] = { 0.15, 0.30, 0.45 }, [MAT_PLASTIC] = { 0.10, 0.10, 0.10 },
	-- snow: porous, among the most absorbing outdoor grounds (fresh snow ~0.5-0.9 above 500 Hz in
	-- field measurements, packed snow less); a middle estimate. It fell back to 0.10 everywhere (an
	-- echoing snowfield, gm_snowhimsy)
	[MAT_SNOW] = { 0.30, 0.65, 0.85 },
	-- foliage: leaves absorb and scatter, more in the treble (estimate); vents: sheet metal like
	-- MAT_METAL; computers: plastic cases. They fell back to 0.10
	[MAT_FOLIAGE] = { 0.15, 0.35, 0.55 }, [MAT_VENT] = { 0.20, 0.07, 0.06 }, [MAT_COMPUTER] = { 0.10, 0.10, 0.10 },
}

-- Absorption by surfaceprop NAME (finer than MAT_*: GMod has no "fabric" or "foam" MAT_ type).
-- Steam Audio's own presets where one exists (carpet); others from usual room-acoustics tables.
local ABSORB_SURF = {
	carpet = { 0.24, 0.69, 0.73 },                                   -- Steam Audio preset "carpet"
	rubber = { 0.04, 0.04, 0.03 }, rubbertire = { 0.04, 0.04, 0.03 }, -- solid rubber reflects (rubber flooring)
	jeeptire = { 0.04, 0.04, 0.03 }, slidingrubbertire = { 0.04, 0.04, 0.03 },
	cardboard = { 0.12, 0.10, 0.10 },                                 -- estimate
	paper = { 0.10, 0.15, 0.20 },                                     -- estimate
	plaster = { 0.12, 0.06, 0.04 },                                   -- Steam Audio preset "plaster"
	brick = { 0.03, 0.04, 0.07 },                                     -- Steam Audio preset "brick"
	-- surfaceprops whose MAT_ type says the wrong thing acoustically (estimates from usual tables)
	cavern_rock = { 0.02, 0.03, 0.05 },                               -- typed MAT_FOLIAGE: bare rock
	gravel = { 0.25, 0.50, 0.65 },                                    -- typed MAT_CONCRETE: porous
	ceiling_tile = { 0.40, 0.70, 0.80 },                              -- typed MAT_DIRT: acoustic tiles
	hay = { 0.35, 0.70, 0.85 },                                       -- typed MAT_WOOD: loose fibre
	slime = { 0.01, 0.01, 0.02 },                                     -- typed MAT_SLOSH: liquid, like water
}
-- Models whose surfaceprop says nothing of their padding (couches declared "dirt", seats "metal").
-- Estimates (unoccupied upholstered seating, hay, a stack of tyres with its cavities).
local ABSORB_MODEL = {
	{ "couch", { 0.35, 0.65, 0.70 } }, { "sofa", { 0.35, 0.65, 0.70 } }, { "armchair", { 0.35, 0.65, 0.70 } },
	{ "mattress", { 0.35, 0.65, 0.70 } }, { "carseat", { 0.30, 0.55, 0.60 } }, { "_seat", { 0.30, 0.55, 0.60 } },
	{ "chair_office", { 0.25, 0.45, 0.50 } }, { "traincar_seats", { 0.30, 0.55, 0.60 } },
	{ "haybale", { 0.30, 0.60, 0.70 } }, { "tirestack", { 0.10, 0.15, 0.20 } },
}
local absorbCache = {}
-- returns the absorption and whether the model is padded (diffuse surface)
local function absorptionFor(model, surf, mat)
	if model then
		local a = absorbCache[model]
		if a == nil then
			a = false
			local m = string.lower(model)
			for _, e in ipairs(ABSORB_MODEL) do if string.find(m, e[1], 1, true) then a = e[2] break end end
			absorbCache[model] = a
		end
		if a then return a, true end
	end
	return ABSORB_SURF[string.lower(surf or "")] or ABSORB[mat] or { 0.10, 0.10, 0.10 }, false
end

--- The surfaceprop of an entity on the client: server props have no client physics object, so
-- the model's declared surfaceprop is read instead (was "default" for every prop).
local surfCache = {}
function N.SurfaceOf(e)
	local phys = e:GetPhysicsObject()
	if IsValid(phys) then return phys:GetMaterial() end
	local model = e:GetModel()
	if not model then return "default" end
	local s = surfCache[model]
	if not s then
		local info = util.GetModelInfo(model)
		s = info and info.SurfacePropName or "default"
		surfCache[model] = s
	end
	return s
end

local function skipMaterial(name)
	for _, p in ipairs(SKIP_PREFIX) do if string.StartWith(name, p) then return true end end
	return false
end

--- Steam Audio material for a surfaceprop: transmission derived from pba's own wall table at
-- `thick` units, split into bands (LF bonus, -10 dB HF). A world face does not know the brush it
-- bounds (GetBrushSurfaces gives faces, not brushes), so the world uses a typical wall (16 u); a
-- prop or mover is an oriented box, its thickness the box's smallest dimension (a 2 u sheet-metal
-- panel lets through ~12 dB more than a 64 u metal crate; the table's min / max still bound both).
N.WORLD_THICK = 16
local function saMaterial(surf, cfg, model, thick)
	local idx = util.GetSurfaceIndex(surf or "default")
	local data = util.GetSurfaceData(idx >= 0 and idx or 0)
	local mat = data and data.material or MAT_CONCRETE
	local R = A.AC.WallLoss(mat, surf, thick or N.WORLD_THICK) * cfg.trans_scale
	local tm = 10 ^ (-R / 20)
	local absorption, padded = absorptionFor(model, surf, mat)
	return {
		absorption = absorption,
		scattering = padded and 0.5 or (cfg.native_scattering or 0.25),
		transmission = { math.min(tm * 10 ^ (cfg.trans_lf_bonus / 20), 1), tm, tm * 10 ^ (-10 / 20) },
	}
end

--- A face of a grate, fence or grille brush (CONTENTS_GRATE, on either side of the face): sound
-- crosses it, and Steam Audio would bounce its reverb rays on it as on a wall (a fenced yard heard
-- as a closed room): left out of the scene, as pba's own traces leave grates out.
function N.IsGrateSurface(s)
	local v = s:GetVertices()
	if #v < 3 then return false end
	local c = Vector()
	for _, p in ipairs(v) do c:Add(p) end
	c:Div(#v)
	local n = (v[2] - v[1]):Cross(v[3] - v[1])
	if n:LengthSqr() < 1e-6 then return false end
	n:Normalize()
	return bit.band(bit.bor(util.PointContents(c + n * 0.5), util.PointContents(c - n * 0.5)), CONTENTS_GRATE) ~= 0
end

--- Triangulated world (fan per brush surface) + material list. Returns verts, tris, matIdx, mats, mins, maxs.
function N.BuildWorld()
	local verts, tris, matIdx, mats, matOf = {}, {}, {}, {}, {}
	local mins, maxs = Vector(math.huge, math.huge, math.huge), Vector(-math.huge, -math.huge, -math.huge)
	local withWater = (A.cfg.native_water or 1) >= 0.5
	for _, s in ipairs(game.GetWorld():GetBrushSurfaces() or {}) do
		local m = s:GetMaterial()
		local name = m and m:GetName() or ""
		if N.Yield then N.Yield() end
		local water = s:IsWater()
		if not s:IsSky() and (withWater or not water) and not skipMaterial(name) and not N.IsGrateSurface(s) then
			local surf = water and "pba_water" or (m and m:GetString("$surfaceprop") or "default")
			local mi = matOf[surf]
			if not mi then
				-- air / water interface: ~99.9 % of the energy reflected (impedance ratio ~3600),
				-- calm surface; transmission = pba's own interface loss (pba_water_db)
				mats[#mats + 1] = water and { absorption = { 0.01, 0.01, 0.02 }, scattering = 0.05,
					transmission = { 10 ^ (-(A.cfg.water_db or 24) / 20), 10 ^ (-(A.cfg.water_db or 24) / 20), 10 ^ (-(A.cfg.water_db or 24) / 20) } }
					or saMaterial(surf, A.cfg, nil, N.WORLD_THICK)
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
	-- displacements (terrain): not in GetBrushSurfaces; read from the BSP with their material name.
	-- Absorption follows the texture's $surfaceprop as for flat faces (earth when it has none);
	-- transmission stays thick earth for all (the ground does not let sound through). Blended
	-- textures (WorldVertexTransition): the main $surfaceprop only; $surfaceprop2 weighted by the
	-- per-vertex alpha would be a later refinement.
	local dv, di, dnames, dntris = A.BSP.LoadDisplacements(game.GetMap())
	if dv and #di > 0 then
		local groundT = { 0.0001, 0.00003, 0.00001 }
		local dispMi, dmi = {}, {}
		for k, name in ipairs(dnames) do
			local mi = dispMi[name]
			if not mi then
				local m = name ~= "" and Material(name) or nil
				local surf = m and not m:IsError() and m:GetString("$surfaceprop") or nil
				local key = "pba_disp:" .. (surf or "")
				mi = matOf[key]
				if not mi then
					if surf then
						local sm = saMaterial(surf, A.cfg, nil, N.WORLD_THICK)
						sm.transmission = groundT
						mats[#mats + 1] = sm
					else
						mats[#mats + 1] = { absorption = { 0.15, 0.25, 0.35 }, scattering = 0.3, transmission = groundT }
					end
					mi = #mats - 1
					matOf[key] = mi
				end
				dispMi[name] = mi
			end
			dmi[k] = mi
		end
		N.dispMats = dispMi -- material name -> scene material index (inspection)
		local base = #verts / 3
		for i = 1, #dv, 3 do
			verts[#verts + 1], verts[#verts + 2], verts[#verts + 3] = dv[i], dv[i + 1], dv[i + 2]
			mins.x, mins.y, mins.z = math.min(mins.x, dv[i]), math.min(mins.y, dv[i + 1]), math.min(mins.z, dv[i + 2])
			maxs.x, maxs.y, maxs.z = math.max(maxs.x, dv[i]), math.max(maxs.y, dv[i + 1]), math.max(maxs.z, dv[i + 2])
		end
		for i = 1, #di do tris[#tris + 1] = base + di[i] end
		for k = 1, #dmi do
			for _ = 1, dntris[k] do matIdx[#matIdx + 1] = dmi[k] end
		end
		N.dispTris = #di / 3
	end
	return verts, tris, matIdx, mats, mins, maxs
end

--- Why the module cannot be used on this install, or nil. arch: jit.arch; exists(path): file.Exists in GAME.
-- The module only exists in 64-bit: a 32-bit game (Steam's default branch) looks for a win32 build that is
-- never shipped and was told "not installed" even with gmcl_pba_win64.dll and phonon.dll in place.
function N.InstallProblem(arch, exists)
	if arch ~= "x64" then
		return "your game runs the 32-bit version of Garry's Mod: the Steam Audio module is 64-bit only. Start the 64-bit game (gmod_win64.exe: in Steam, the 64-bit launch option)"
	end
	if not exists(MODULE) then return "module not installed" end
	return nil
end

--- Is the phonon.dll in use the one with the reflection level fix (Steam Audio fork, pba-4: the reconstructed response
-- in the units of the direct sound; the DLLs before it are 8-11 dB too loud)? Measured by the module on the DLL itself
-- (pba_native.PhononLevel, after Init). true / false, or nil when unknown: no module, a module of API 2 without the
-- probe, a failed measurement. Kept in N.phononFixed / N.phononLevelDb: the reverb and echo levels sent to the module
-- depend on it (N.WetComp).
function N.PhononFixed()
	N.phononFixed, N.phononLevelDb = nil, nil
	if not (pba_native and pba_native.PhononLevel) then return nil end
	local ok, fixed, level = pcall(pba_native.PhononLevel)
	if not ok or type(fixed) ~= "boolean" then return nil end
	N.phononFixed, N.phononLevelDb = fixed, tonumber(level)
	return fixed
end

-- Probe level (pba_native.PhononLevel) of a DLL whose reflections come out at the level of the fixed one: an old DLL's
-- excess is its probe level minus this. Calibrated at the module's output, not taken from the fixed DLL's own probe
-- (-1.4 dB, pba-5): on pba_pipe the fork's pba.3 build (probe +10.0 dB) gave reflections 10.0 - 10.2 dB above pba-5
-- (echo of a mono shot at 95 and 140, slot reverb of a 140 shot; the slot reverb of quieter sounds 9.9 - 11.1 dB),
-- where the probe difference is 11.4 dB: -1.4 left that DLL about 1.2 dB under the fixed one, -0.2 within 1 dB.
N.PHONON_FIXED_DB = -0.2

--- Compensation of the phonon.dll in use, on the reverb and echo levels sent to the module (linear, <= 1): reverb, echo.
-- pba_native_reverb and pba_native_echo mean the same level on every DLL (1 = the physical level, measured on the fixed
-- one), so a player who has the new addon but an old phonon.dll (Steam Audio 4.8.1 as released, the fork's builds before
-- the level fix: reflections 8.5 - 10 dB over the physical level) does not get a reverb 11 dB too loud, and nothing
-- the player saved is rewritten for it (the next DLL update just switches the compensation off):
--  * fixed DLL: 1 (nothing to take off);
--  * old DLL, its level measured: its excess over the fixed DLL comes off both buses (the same response feeds both);
--  * unknown (a module of API 2 has no probe, or the probe failed): the previous release's levels, bus by bus (its default
--    over today's: the levels that module and its DLL were tuned for; the retune scaled saved values by the inverse).
function N.WetComp(fixed, levelDb)
	if fixed == true then return 1, 1 end
	if fixed == false and levelDb then
		local k = math.min(10 ^ (-(levelDb - N.PHONON_FIXED_DB) / 20), 1)
		return k, k
	end
	local r, e = 1, 1
	for _, m in ipairs(A.RETUNE or {}) do
		local c = A.CONFIG[m.name]
		if m.old and c and c[1] > 0 then
			if m.name == "native_reverb" then r = m.old / c[1] elseif m.name == "native_echo" then e = m.old / c[1] end
		end
	end
	return r, e
end

--- The reverb and echo levels for the module: the settings times the DLL compensation (N.WetComp).
function N.WetLevels()
	local kr, ke = N.WetComp(N.phononFixed, N.phononLevelDb)
	return (A.cfg.native_reverb or 1) * kr, (A.cfg.native_echo or 1) * ke
end

--- The warning about the phonon.dll in use (menu status line, console), or nil: an old DLL (measured), a module too old to
-- measure it. Nothing without a module.
function N.PhononWarning()
	if not pba_native then return nil end
	if N.phononFixed == true then return nil end
	if N.phononFixed == false and N.phononLevelDb then
		return string.format("Your phonon.dll is an old build: its reflections are %.0f dB too loud. PBA turns the reverb and echoes down to compensate, but update phonon.dll (with the module, from the PBA release).",
			N.phononLevelDb - N.PHONON_FIXED_DB)
	end
	if not pba_native.PhononLevel then
		return "Your Steam Audio module is older than this addon and cannot check its phonon.dll: reverb and echoes are kept at the previous release's levels. Update the module and phonon.dll."
	end
	return "The level of your phonon.dll could not be measured: reverb and echoes are kept at the previous release's levels."
end

--- The one-time retune of the saved reverb settings (A.MigrateRetune), and the warning about an old phonon.dll.
function N.Retune()
	if not A.MigrateRetune then return nil end
	local r = A.MigrateRetune(N.PhononFixed())
	N.retune = r
	local w = N.PhononWarning()
	if w then print("[PBA] " .. w) end
	return r
end

function N.Start()
	N.ready, N.pathsReady, N.err, N.outdated = false, false, nil, nil
	if (A.cfg.native or 1) < 0.5 then return end
	if (A.cfg.allow_native or 1) < 0.5 then N.err = "disabled by the server (pba_allow_native 0)" return end
	local problem = N.InstallProblem(jit.arch, function(p) return file.Exists(p, "GAME") end)
	if problem then N.err = problem return end
	if not pba_native then
		local ok, err = pcall(require, "pba")
		if not ok or not pba_native then N.err = "require failed: " .. tostring(err) return end
	end
	if N.WrapPlay then N.WrapPlay() end
	if A.Mix and A.Mix.Wrap then A.Mix.Wrap() end -- mix groups and ducking on every voice (cl_mix)
	local compatible, why, ver, api = N.CheckModule(pba_native)
	N.moduleVersion, N.moduleApi = ver, api
	if not compatible then
		N.err, N.outdated = why, true
		MsgC(Color(255, 90, 60), "[PBA] " .. why .. "\n")
		return
	end
	local ok, err = pba_native.Init()
	if not ok then N.err = err return end
	N.Retune()

	-- the world is gathered in a coroutine, 4 ms per frame (large maps: seconds of Lua work),
	-- then handed to the module in one call
	N.gathered = nil -- (a world held for calm: replaced by this build)
	N.building = coroutine.create(function()
		local t0 = SysTime()
		local verts, tris, matIdx, mats, mins, maxs = N.BuildWorld()
		-- the movers' shapes too, in the same frame budget (up to ~100 ms for a big one, measured)
		if N.PrecomputeMovers then N.PrecomputeMovers() end
		N.buildMs = (SysTime() - t0) * 1000
		return verts, tris, matIdx, mats, mins, maxs
	end)
	N.buildStart = SysTime()
end

hook.Add("Think", "pba_native_build", function()
	local co = N.building
	if not co then return end
	local held = N.gathered
	if held then
		-- the world gathered during a fight: its load into the module (one call, tens of ms) waits for calm
		if A.Sched and A.Sched.HoldLongStep and A.Sched.HoldLongStep() then return end
		local t1 = SysTime()
		N.building, N.gathered = nil, nil
		N.Finish(unpack(held, 1, 6))
		if A.Sched and A.Sched.NoteBuild then A.Sched.NoteBuild((SysTime() - t1) * 1000) end
		return
	end
	local t0 = SysTime()
	-- 4 ms per frame, less during a fight (pba_build_ms_combat, cl_sched)
	local bud = A.Sched and A.Sched.BuildBudget and A.Sched.BuildBudget("native") or 0.004
	if bud <= 0 then return end
	local deadline = t0 + bud
	local function yield() if SysTime() > deadline then coroutine.yield() end end
	N.Yield, A.BSP.Yield = yield, yield
	local ok, verts, tris, matIdx, mats, mins, maxs = coroutine.resume(co)
	N.Yield, A.BSP.Yield = nil, nil
	if A.Sched and A.Sched.NoteBuild then A.Sched.NoteBuild((SysTime() - t0) * 1000) end
	if not ok then
		N.building, N.err = nil, "world build failed: " .. tostring(verts)
		MsgN("[PBA] native backend: ", N.err)
		return
	end
	if coroutine.status(co) ~= "dead" then return end
	if A.Sched and A.Sched.HoldLongStep and A.Sched.HoldLongStep() then
		N.gathered = { verts, tris, matIdx, mats, mins, maxs } -- (N.building kept: still building)
		return
	end
	N.building = nil
	N.Finish(verts, tris, matIdx, mats, mins, maxs)
end)

function N.Finish(verts, tris, matIdx, mats, mins, maxs)
	local t0 = SysTime()
	-- the simulator is created with the current ray count (it fixes the ray directions)
	local wr, we = N.WetLevels()
	pba_native.SetReflections(wr, we, A.cfg.native_rays, A.cfg.native_bounces or 128)
	if pba_native.SetSimOptions then
		pba_native.SetSimOptions(A.cfg.native_scene or 1, A.cfg.native_threads or 0, A.cfg.native_reverb_window or 2.5, 512)
	end
	local nt = pba_native.LoadWorld(verts, tris, matIdx, mats)
	N.doors = {} -- the module released its dynamic objects with the old world
	N.worldGen = (N.worldGen or 0) + 1 -- others holding dynamic meshes (demo panels) re-add them
	N.loadMs = (SysTime() - t0) * 1000
	N.tris, N.mins, N.maxs, N.nMats = nt, mins, maxs, #mats
	N.ready = nt > 0
	MsgN(string.format("[PBA] native backend: module %s (API %d), Steam Audio %d, %d triangles, %d materials, gathered in %.0f ms over %.1f s, loaded in %.0f ms",
		tostring(N.moduleVersion), N.moduleApi or 0, pba_native.Version(), nt, #mats, N.buildMs or 0, SysTime() - (N.buildStart or SysTime()), N.loadMs))
	if N.ready then N.StartRender() end
	if N.ready then N.WantReverbBake() end
	if N.ready and not N.prewarm then N.Prewarm() end -- (StartRender started it)
	if N.ready and (A.cfg.native_paths or 0) >= 0.5 then
		-- the probe graph is built in the background: bake once it is there
		timer.Create("pba_native_bake", 1, 120, function()
			if A.Probes and A.Probes.current then timer.Remove("pba_native_bake") N.Bake() end
		end)
	end
	if A.Paths then A.Paths.InvalidateCache() end
end

local SA_CACHE_VERSION = 1
local function bakeCachePath() return "pba/" .. game.GetMap() .. "_sa.dat" end
local function bakeCacheKey(nProbes)
	local pr = A.Probes and A.Probes.current
	local hash = (pr and pr.hash) or "?"
	return string.format("pba-sa v%d %s %d %d %d\n", SA_CACHE_VERSION, hash, pba_native.Version(), nProbes,
		A.cfg.native_probe_spacing)
end

--- Disk cache of the bake (iplProbeBatchSave): first line = key, then the serialized batch.
function N.SaveBake(nProbes)
	if (A.cfg.native_cache or 1) < 0.5 or not pba_native.SavePaths then return end
	local bytes = pba_native.SavePaths()
	if not bytes then return end
	file.CreateDir("pba")
	file.Write(bakeCachePath(), bakeCacheKey(nProbes) .. bytes)
	N.bakeCached = #bytes
end

function N.LoadBake(nProbes)
	if (A.cfg.native_cache or 1) < 0.5 or not pba_native.LoadPaths then return false end
	local data = file.Read(bakeCachePath(), "DATA")
	if not data then return false end
	local key = bakeCacheKey(nProbes)
	if data:sub(1, #key) ~= key then return false end
	local t0 = SysTime()
	local n, err = pba_native.LoadPaths(data:sub(#key + 1))
	if not n then MsgN("[PBA] native paths cache rejected: ", err) return false end
	N.pathsReady, N.bakeMs, N.bakeBytes, N.fromCache = true, (SysTime() - t0) * 1000, #data - #key, true
	MsgN(string.format("[PBA] native paths: %d probes loaded from cache in %.0f ms", n, N.bakeMs))
	if A.Paths then A.Paths.InvalidateCache() end
	return true
end

function N.Bake()
	-- probe positions: pba's own probe graph (inside the playable volume), thinned until
	-- there are at most pba_native_max_probes of them (large open maps)
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
	N.probes = #pts
	if N.LoadBake(#pts) then return end
	local t0 = SysTime()
	N.pathsReady = false
	N.fromCache = false
	local ok, err = pcall(pba_native.BakePaths, pts, pr.spacing * (step - 1) * 0.75)
	if not ok then N.err = err return end
	N.probes = #pts
	-- the bake runs on a worker thread: poll it
	timer.Create("pba_native_bakepoll", 0.25, 0, function()
		if not pba_native then timer.Remove("pba_native_bakepoll") return end
		local st, info = pba_native.BakeStatus()
		if st == "ready" then
			timer.Remove("pba_native_bakepoll")
			N.pathsReady, N.bakeMs, N.bakeBytes = true, (SysTime() - t0) * 1000, info
			MsgN(string.format("[PBA] native paths: %d probes baked in %.0f ms (%d KB)", N.probes, N.bakeMs, (info or 0) / 1024))
			N.SaveBake(N.probes)
			if A.Paths then A.Paths.InvalidateCache() end
		elseif st == "error" then
			timer.Remove("pba_native_bakepoll")
			N.err = "bake failed: " .. tostring(info)
			MsgN("[PBA] native paths: ", N.err)
		end
	end)
end

--- Direct line through the world: occlusion (1 = clear) and per-band transmission.
function N.Direct(S, L)
	if not N.ready then return nil end
	local r = pba_native.Direct({ S }, L, 16)
	return r and r[1]
end

--- Baked path from S to L: eq gains (low, mid, high) and arrival direction at L.
function N.Path(S, L)
	if not N.pathsReady then return nil end
	local r = pba_native.Paths({ S }, L)
	return r and r[1]
end

-- ------------------------------------------------------------------ native rendering

-- 3-band EQ of a muffled voice (low / mid / high gain), continuous in the loss.
-- The voice's gain already holds its loss at pba_diff_freq (500 Hz, AC.Diffraction): the EQ only says how
-- much MORE (or less) the other bands lose, so the band holding diff_freq stays at exactly 1. The former
-- table per low-pass level (N.EQ, "same intent as DSP presets 30/31") counted the loss twice and stepped:
-- at level 4 the mid band got -15 dB on top of the -16 dB already in the gain, the low band was cut although
-- low frequencies bend round an edge best, and 10.9 -> 11.0 dB of loss dropped the high band 8 dB.
-- The tilt is pba's own diffraction law (Kurze-Anderson, AC.Diffraction): from the loss D at diff_freq the
-- Fresnel number is solved, then scaled to each band's frequency (N grows with f). Near the shadow boundary
-- (D = 0.5 dB) the high band loses ~7 dB more, deep in the shadow (D = 16 dB) ~15 dB more and the mid band
-- ~7 dB more (3 dB per octave at most); D = 0 is no filter at all.
-- Steam Audio's bands: low < 800 Hz < mid < 8 kHz < high; a band below diff_freq would gain (low
-- frequencies diffract more) but is held at 1: the module's EQ never boosts (a full-scale voice would clip).
N.BAND_HZ = { 400, 2500, 15000 } -- representative frequency of each band (Steam Audio's material bands)
N.BAND_EDGE = { 800, 8000 }
N.EQ = nil -- the former stepped table (autorefresh of a running game)
N.failed = N.failed or {}

local tanh = math.tanh
--- x of the Kurze-Anderson law (A = 20 log10(x / tanh x), x = sqrt(2 pi N)) giving a loss of `db` dB.
local function kaX(db)
	local G = 10 ^ (db / 20)
	if G <= 1.0000001 then return 0 end
	-- x / tanh x rises from 1 (x = 0) and lies between x and x + 1: bisection on [G - 1, G]
	local lo, hi = math.max(G - 1, 0), G
	for _ = 1, 40 do
		local mid = (lo + hi) * 0.5
		if mid / tanh(mid) < G then lo = mid else hi = mid end
	end
	return (lo + hi) * 0.5
end
N.KaX = kaX

--- Loss (dB at diff_freq) behind a voice's low-pass: its continuous loss lpDb (sh_paths: path.lpDb) when it
-- explains the level; a level set by a discrete cause (closed leaf, wall material, masking object, cap) or
-- given without a loss stands for its threshold lp<k>_db. The low-pass hysteresis (AC.LowpassHold) may keep
-- a level one above what lpDb gives, by at most lp_hyst_db: lpDb is still the loss then (no 3 dB jump when
-- the hold lets go).
function N.LowpassDb(lp, lpDb, cfg)
	cfg = cfg or A.cfg
	lp = math.Clamp(math.floor(lp or 0), 0, 4)
	local T = lp > 0 and (cfg["lp" .. lp .. "_db"] or 0) or 0
	if lpDb then
		local lvl = A.AC.LowpassLevel(lpDb, cfg)
		if lvl >= lp or (lvl == lp - 1 and lpDb >= T - (cfg.lp_hyst_db or 0)) then return math.max(lpDb, 0) end
		return math.max(lpDb, T)
	end
	return T
end

--- EQ (low, mid, high) of a loss of `db` dB at diff_freq, relative to that frequency (see above).
function N.TiltEQ(db, cfg)
	cfg = cfg or A.cfg
	if not db or not (db > 0) then return 1, 1, 1 end -- (not <= 0: a NaN loss is no loss either)
	db = math.min(db, 200) -- an infinite loss: the 200 dB one (the bands sit at their floor either way)
	local x0 = kaX(db)
	if x0 <= 0 then return 1, 1, 1 end
	local f0 = cfg.diff_freq or 500
	local a0 = x0 / tanh(x0) -- = 10^(db/20)
	local out = {}
	for b = 1, 3 do
		local lo, hi = N.BAND_EDGE[b - 1] or 0, N.BAND_EDGE[b] or math.huge
		local f = N.BAND_HZ[b]
		if f0 >= lo and f0 < hi then f = f0 end -- the band the gain is expressed in
		if f <= f0 then
			out[b] = 1
		else
			local x = x0 * math.sqrt(f / f0)
			out[b] = math.max(a0 * tanh(x) / x, 1e-3)
		end
	end
	return out[1], out[2], out[3]
end

--- EQ of a voice's low-pass: level lp, continuous loss lpDb when known (N.LowpassDb).
function N.LowpassEQ(lp, lpDb, cfg) return N.TiltEQ(N.LowpassDb(lp, lpDb, cfg), cfg) end

function N.StartRender()
	N.render = false
	if not N.ready or (A.cfg.native_render or 0) < 0.5 or not pba_native.AudioStart then return end
	local sofa
	local hname = N.hrtfCvar and N.hrtfCvar:GetString() or ""
	if hname ~= "" then
		sofa = file.Read("pba/hrtf/" .. hname, "DATA")
		if not sofa then MsgN("[PBA] HRTF file not found: data/pba/hrtf/", hname) end
	end
	local ok, err = pba_native.AudioStart(sofa)
	if not ok then N.err = err MsgN("[PBA] native audio: ", err) return end
	N.render = true
	N.paused = false -- (render::Start: not paused)
	N.ApplySettings()
	if N.Prewarm then N.Prewarm() end -- (a restart: the sounds decoded before were dropped)
	local st = pba_native.Stats and pba_native.Stats()
	MsgN("[PBA] native rendering on (Steam Audio, HRTF: ", st and st.hrtf or "default", ")")
end

-- a reflection level times N.wetScale, kept a hair above 0 when on: the reflection thread then keeps
-- simulating (no gap on surfacing)
local function wetLevel(v, k)
	if v <= 0 or k >= 1 then return v end
	return math.max(v * k, 1e-4)
end

--- Pushes the client options to the module (output mode, reflection levels and quality). The room reverb and
-- echo levels are compensated for the phonon.dll (N.WetLevels) and scaled by N.wetScale (0 with the head under water,
-- see the Think below).
function N.ApplySettings()
	if not N.render or not pba_native.SetReflections then return end
	pba_native.SetOutputMode(A.cfg.native_out >= 0.5 and 1 or 0)
	if pba_native.SetHrtfBlend then pba_native.SetHrtfBlend(A.cfg.native_hrtf_blend or 1) end -- (modules before this option: HRTF alone)
	-- the reading speed of a voice glides to each new pitch (Doppler of a fly-by), not a step per frame (module of 2026-11-18+)
	if pba_native.SetPitchGlide then pba_native.SetPitchGlide(A.cfg.native_pitch_glide or 30) end
	-- a voice's diffuse share changing is ramped over the block (module of 2026-11-19+; an older one steps)
	if pba_native.SetDiffuseSmooth then pba_native.SetDiffuseSmooth((A.cfg.native_diffuse_smooth or 1) >= 0.5) end
	-- at the voice cap, a new voice is ranked with the playing ones (module of 2026-11-19+; an older one always makes room)
	if pba_native.SetCapCompareNew then pba_native.SetCapCompareNew((A.cfg.native_cap_new or 1) >= 0.5) end
	-- a voice's direct EQ, once used, is applied at every block (module of 2026-11-19+; an older one skips it at 1)
	if pba_native.SetEqContinuous then pba_native.SetEqContinuous((A.cfg.native_eq_continuous or 1) >= 0.5) end
	-- a source slot bank the crossfade left is flushed, not reset (module of 2026-11-19+; an older one resets it)
	if pba_native.SetSlotBankFlush then pba_native.SetSlotBankFlush((A.cfg.native_slot_bank_flush or 1) >= 0.5) end
	local k = N.wetScale or 1
	local wr, we = N.WetLevels()
	pba_native.SetReflections(wetLevel(wr, k), wetLevel(we, k), A.cfg.native_rays,
		A.cfg.native_bounces or 128, A.cfg.native_diffuse_send or 1.5, A.cfg.native_diffuse_rt_ref or 1)
	-- a far moving source keeps its source reverb response over a fraction of its distance (module 1.2.0+)
	if pba_native.SetSourceNear then pba_native.SetSourceNear(A.cfg.native_src_near or 0.1) end
	-- each source reverb slot / echo rings with the long-window reverb time of its own position (newer modules)
	if pba_native.SetSourceLongRt then pba_native.SetSourceLongRt((A.cfg.native_source_long_rt or 1) >= 0.5) end
	-- a source slot not simulated yet hands its share to the room bus at the sound's level at the listener, not its 1 m power (newer modules)
	if pba_native.SetSlotFallback then pba_native.SetSlotFallback((A.cfg.native_slot_fallback or 1) >= 0.5) end
	-- output stage and decode resampling (newer modules; an older module keeps its soft clip and linear resampling)
	if pba_native.SetMixQuality then
		pba_native.SetMixQuality(math.floor((A.cfg.native_limiter or 1) + 0.5), (A.cfg.native_resample_hq or 1) >= 0.5, (A.cfg.native_limit_pre or 1) >= 0.5)
	end
	-- fade of a radio stream's start, underruns and end (modules since this option; an older one cuts to silence)
	if pba_native.SetStreamFade then pba_native.SetStreamFade(A.cfg.native_stream_fade or 5) end
end

N.hrtfCvar = N.hrtfCvar or CreateClientConVar("pba_native_hrtf", "", true, false,
	"SOFA HRTF file in data/pba/hrtf/ for native rendering (empty = Steam Audio default). Restart native rendering to apply.")
-- tells the server that this client renders echoes (loud server sounds are then relayed to it)
N.echoCvar = N.echoCvar or CreateClientConVar("pba_echo_want", "0", false, true, "Internal: native echoes active.")
N.allCvar = N.allCvar or CreateClientConVar("pba_native_all_want", "0", false, true, "Internal: every sound rendered natively.")
N.ownCvar = N.ownCvar or CreateClientConVar("pba_native_own_want", "0", false, true, "Internal: own sounds rendered natively too.")

function N.StopRender()
	if N.render and pba_native then pba_native.AudioStop() end
	N.render = false
	-- the module dropped every decoded sound (render::Stop): a decode started before (the map load prewarm,
	-- pba_native_predecode) is no longer pending nor loaded, and N.EnsureSound took it for an undecodable file
	-- (refused for 30 s, left to the engine: native_predecode red after a render restart). StartRender prewarms again.
	N.loading, N.prewarm = nil, nil
	N.wpnDone, N.wpnQueue = nil, nil -- (the weapons' sounds went with them: asked again)
	N.npcWpnDone, N.npcMapDone = nil, nil -- (the NPC weapons' too)
end

local function cleanName(name)
	return string.lower(A.SoundFile(name))
end

-- decodings started: on the main thread (LoadSound), on a worker (LoadSoundAsync), by the map load prewarm
N.decodes = N.decodes or { main = 0, async = 0, prewarm = 0 }

--- Makes sure the module has decoded `name`. Returns true, cleanName when playable natively;
-- false, nil, "pending" while a large file decodes on the module's worker thread.
function N.EnsureSound(name, now)
	-- a sentence: its words rendered into one sound (cl_sentences, pba_native_sentences)
	if A.IsSentence(name) then return A.Sentences.Ensure(name) end
	local n = cleanName(name)
	-- failures are retried after a while: a sound refused for lack of memory may fit later
	local f = N.failed[n]
	if f and (f == true or RealTime() - f < 30) then return false end
	if pba_native.HasSound(n) then
		if N.loading then N.loading[n] = nil end -- loaded: a later eviction must not look like a failure
		return true, n
	end
	if pba_native.SoundPending and pba_native.SoundPending(n) then return false, nil, "pending" end
	if N.loading and N.loading[n] then
		-- the worker finished without a sound: undecodable
		N.loading[n] = nil
		N.failed[n] = RealTime()
		return false
	end
	local data = file.Read("sound/" .. n, "GAME")
	-- an empty read (a file the game lists but cannot read, e.g. inside a mounted package) made
	-- LoadSound raise "no data" every loop update: left to the engine like an undecodable sound
	if not data or #data == 0 or #data > (A.cfg.native_file_mb or 48) * 1024 * 1024 then N.failed[n] = RealTime() return false end
	-- large files decode on a worker thread; with pba_native_predecode every file does (a burst's first sounds
	-- cost the main thread up to 12 ms each: perf bench S11), the first play of each left to the engine
	-- now: a spoken line played this frame (pba_native_line_decode): decoded here up to 1.5 MB (a short line is at
	-- most max_duration long: ~700 KB at 44 kHz, ~5 ms; a WAV decodes at ~7.5 ms per MB), so the module renders its
	-- first play like every other line (the Breencast's short lines, 340-660 KB, went to the engine's speaker
	-- preset while its long line, a mirror waiting for its decode, stayed native)
	local asyncAbove = now and 1536 * 1024 or (A.cfg.native_predecode or 1) >= 0.5 and 0 or 512 * 1024
	if #data > asyncAbove and pba_native.LoadSoundAsync then
		pba_native.LoadSoundAsync(n, data)
		N.loading = N.loading or {}
		N.loading[n] = true
		N.decodes.async = N.decodes.async + 1
		return false, nil, "pending"
	end
	N.decodes.main = N.decodes.main + 1
	local okLoad, secs, _, stereo = pcall(pba_native.LoadSound, n, data)
	if not okLoad or not secs then N.failed[n] = RealTime() return false end
	N.stereo[n] = stereo == true -- (nil from a module without stereo support: mono)
	return true, n
end

--- True while the module decodes `name` on a worker thread (no side effect: nothing is started, unlike
-- N.EnsureSound). A file refused as undecodable (N.failed) or already decoded is not pending.
function N.DecodePending(name)
	if not (pba_native and pba_native.SoundPending) or A.IsSentence(name) then return false end
	local n = cleanName(name)
	local f = N.failed[n]
	if f and (f == true or RealTime() - f < 30) then return false end
	return pba_native.SoundPending(n) and not pba_native.HasSound(n)
end

--- (pba_native_late_handover) What an engine copy of a followed short sound, started while its file was still
-- decoding, does now: "wait" (decoding goes on, or the copy has not started), "switch", offset (decoded: hand
-- it to the module, which plays from offset seconds into the sound; the offset is playback time, the module
-- scales it by the voice's pitch) or "drop", why (stay on the engine for good). Pure: the caller passes the
-- facts. on: the option, native rendering and the module's own rules allow it; cap: the module's Play takes
-- a start offset (pba_native.caps.playOffset: an older one would play the sound from its start, heard twice);
-- decode: "pending" | "ready" | "failed"; started: the engine copy has started; gone: it was stopped
-- (StopSound, channel cut, entity removed) or is no longer driven; now, t0 (when the copy started), tEnd (when
-- it ends), margin: seconds before its end from which a second voice is not worth it.
function N.LateVerdict(on, cap, decode, started, gone, now, t0, tEnd, margin)
	if not on then return "drop", "off" end
	if gone then return "drop", "gone" end
	if not cap then return "drop", "nocap" end
	if decode == "failed" then return "drop", "failed" end
	if now > tEnd - margin then return "drop", "ended" end
	if decode ~= "ready" or not started then return "wait" end
	return "switch", math.max(now - t0, 0)
end

--- (pba_early_line_takeover) What a line the engine started for this player before his client was ready (cl_loops
-- LP.TakeEarly) does now: "switch", offset (the module plays the rest from offset seconds of playback) or "drop", why
-- (it stays with the engine to its end). The hand-over rule of N.LateVerdict (the engine copy has started; the
-- module's file decode is the mirror's own wait): on, cap, now, t0 (its start), tEnd (its end), margin as there.
-- blocked: it reached the engine because the client was not ready (a line behind a wall, or any line before pba ran
-- here); else it was a clear line left to the engine while the module was not rendering yet, which is the module's
-- only when every sound is (allNative: pba_native_all).
function N.EarlyVerdict(on, cap, blocked, allNative, now, t0, tEnd, margin)
	if on and not blocked and not allNative then return "drop", "clear" end
	return N.LateVerdict(on, cap, "ready", true, false, now, t0, tEnd, margin)
end

-- ------------------------------------------------------------------ prewarm (pba_native_predecode)
-- At map load (module ready), the sounds a fight brings at once are decoded ahead on worker threads: the
-- explosion script, the breakables' scripts and the physics sounds (impacts, breaks, scrapes, bullet hits)
-- of the surfaces of the map's props and of the usual gibs. A coroutine, PREWARM_MS per frame on the main
-- thread (script lookups, file reads), at most PREWARM_INFLIGHT decodes running at once.
local PREWARM_MS, PREWARM_INFLIGHT = 0.5, 4
local PREWARM_SCRIPTS = { "BaseExplosionEffect.Sound", "BaseGrenade.Explode", "ExplosionCore.Wall" }
local PREWARM_SURFACES = { "metal", "metal_barrel", "metalpanel", "wood", "wood_crate", "wood_plank", "glass",
	"concrete", "plastic", "plastic_barrel", "dirt", "default" }
local SURFACE_SOUNDS = { "impactHardSound", "impactSoftSound", "breakSound", "bulletImpactSound",
	"scrapeRoughSound", "scrapeSmoothSound", "rollingSound", "strainSound" }
-- with pba_native_own the player's footsteps are the module's too: their first play on a fresh map would
-- otherwise be the engine's while the file decodes (dry, then the next steps with the room's reverb)
local STEP_SURFACES = { "concrete", "metal", "metalgrate", "metalpanel", "wood", "tile", "dirt", "gravel", "grass",
	"mud", "sand", "chainlink", "water", "wade", "ladder", "default" }
local STEP_SOUNDS = { "stepLeftSound", "stepRightSound" }

--- The wave files behind a sound script name (clean names); a name with no script is taken for a file.
local function scriptFiles(s, out, seen)
	local p = sound.GetProperties(s)
	local w = p and p.sound
	if type(w) == "string" then w = { w } end
	if type(w) ~= "table" then w = nil end
	if not w and type(s) == "string" and (string.find(s, "/", 1, true) or string.find(string.lower(s), "%.[wm][ap][v3]$")) then w = { s } end
	for _, f in ipairs(w or {}) do
		local n = type(f) == "string" and cleanName(f) or ""
		if n ~= "" and not seen[n] then seen[n] = true out[#out + 1] = n end
	end
end

--- Starts decoding `n` (a clean name) on a worker thread unless it is decoded, decoding or refused; true when
-- a decode started.
local function decodeAhead(n)
	if pba_native.HasSound(n) or pba_native.SoundPending(n) or N.failed[n] then return false end
	local data = file.Read("sound/" .. n, "GAME")
	if data and #data > 0 and #data <= (A.cfg.native_file_mb or 48) * 1024 * 1024 and pba_native.LoadSoundAsync(n, data) then
		N.loading = N.loading or {}
		N.loading[n] = true
		N.decodes.prewarm = N.decodes.prewarm + 1
		return true
	end
	return false
end

--- Decodes these files ahead (names as EmitSound takes them), for an entity that is about to make them play (the
-- metal pipe: the first clang of a fall would otherwise be the engine's, dry, while its file decodes). Returns the
-- number of decodes started; nothing without the module or with pba_native_predecode off.
function N.PrewarmFiles(files)
	if (A.cfg.native_predecode or 1) < 0.5 or not N.ready or not pba_native or not pba_native.LoadSoundAsync then return 0 end
	local started = 0
	for _, f in ipairs(files) do
		local n = cleanName(f)
		if n ~= "" and decodeAhead(n) then started = started + 1 end
	end
	return started
end

--- The wave files of the likely burst sounds of this map (clean names, each once).
function N.PrewarmList(yield)
	yield = yield or function() end
	local scripts, seen, out = {}, {}, {}
	for _, s in ipairs(PREWARM_SCRIPTS) do scripts[#scripts + 1] = s end
	-- the bullet whizzes (pba_native_whiz): their first play would be left to the engine while the file decodes
	if (A.cfg.native_whiz or 0) >= 0.5 and A.Whiz then
		for _, s in pairs(A.Whiz.SCRIPTS) do scripts[#scripts + 1] = s end
	end
	for _, s in ipairs(sound.GetTable() or {}) do
		if string.StartWith(string.lower(s), "breakable.") then scripts[#scripts + 1] = s end
		yield()
	end
	local surfs = {}
	for _, s in ipairs(PREWARM_SURFACES) do surfs[s] = true end
	for _, e in ipairs(ents.GetAll()) do
		-- (a snapshot walked over several frames: an entity removed meanwhile is NULL, skipped)
		local c = IsValid(e) and e:GetClass()
		if c and (string.StartWith(c, "prop_physics") or c == "func_breakable" or c == "func_physbox") then surfs[N.SurfaceOf(e)] = true end
		yield()
	end
	if (A.cfg.native_own or 1) >= 0.5 then
		for _, s in ipairs(STEP_SURFACES) do
			local d = util.GetSurfaceData(util.GetSurfaceIndex(s))
			if d then
				for _, k in ipairs(STEP_SOUNDS) do
					local v = d[k]
					if isstring(v) and v ~= "" then scripts[#scripts + 1] = v end
				end
			end
		end
	end
	for s in pairs(surfs) do
		local d = util.GetSurfaceData(util.GetSurfaceIndex(s))
		if d then
			for _, k in ipairs(SURFACE_SOUNDS) do
				local v = d[k]
				if isstring(v) and v ~= "" then scripts[#scripts + 1] = v end
			end
		end
	end
	for _, s in ipairs(scripts) do
		local p = sound.GetProperties(s)
		local w = p and p.sound
		if isstring(w) then w = { w } end
		for _, f in ipairs(istable(w) and w or {}) do
			local n = cleanName(f)
			if n ~= "" and not seen[n] then seen[n] = true out[#out + 1] = n end
		end
		yield()
	end
	return out
end

--- Starts the prewarm (pba_native_predecode 1, module loaded); a running one is restarted.
function N.Prewarm()
	N.prewarm = nil
	if (A.cfg.native_predecode or 1) < 0.5 or not N.ready or not pba_native.LoadSoundAsync then return end
	local pw = { started = 0, done = false, deadline = 0 }
	N.prewarm = pw
	pw.co = coroutine.create(function()
		local function yield() if SysTime() > pw.deadline then coroutine.yield() end end
		local list = N.PrewarmList(yield)
		pw.total = #list
		local inflight = {}
		for _, n in ipairs(list) do
			-- at most PREWARM_INFLIGHT decodes at once (a thread each)
			while true do
				for m in pairs(inflight) do if not pba_native.SoundPending(m) then inflight[m] = nil end end
				if table.Count(inflight) < PREWARM_INFLIGHT then break end
				coroutine.yield()
			end
			if decodeAhead(n) then
				inflight[n] = true
				pw.started = pw.started + 1
			end
			yield()
		end
		while next(inflight) do
			for m in pairs(inflight) do if not pba_native.SoundPending(m) then inflight[m] = nil end end
			coroutine.yield()
		end
	end)
end

hook.Add("Think", "pba_native_prewarm", function()
	local pw = N.prewarm
	if not pw or pw.done then return end
	if not N.ready then N.prewarm = nil return end
	if not A.Enabled() then return end -- (pba off: no work; resumed when on again)
	pw.deadline = SysTime() + PREWARM_MS / 1000
	local ok, err = coroutine.resume(pw.co)
	if not ok then
		pw.done, pw.err = true, tostring(err)
		ErrorNoHaltWithStack("[PBA] sound prewarm failed: " .. pw.err)
	elseif coroutine.status(pw.co) == "dead" then
		pw.done = true
	end
end)

-- ------------------------------------------------------------------ the player's weapons (pba_native_prewarm_weapons)
-- With pba_native_own the player's shots are the module's, but the first play of a sound not decoded yet goes to
-- the engine (pba_native_predecode): the first shot of each weapon after a map load sounded different. The
-- sound files of the weapons he holds are decoded ahead as soon as he has them (map load, pickup, give).
local WEAPON_POLL, WEAPON_PER_FRAME, WEAPON_INFLIGHT = 0.5, 2, 4

--- The sound script names of the player's use of a weapon, read from the text of its script (SoundData block of
-- scripts/weapon_<class>.txt: reload, empty, single_shot, double_shot, burst, special1, special2). The NPC
-- variants ("..._npc") are left out: the player never plays them (npc true: only those, what an NPC holding the
-- weapon plays). Each name once, in file order.
function N.ParseWeaponSounds(text, npc)
	local out, seen = {}, {}
	if type(text) ~= "string" then return out end
	text = string.gsub(text, "//[^\r\n]*", "")
	local _, e = string.find(string.lower(text), "\"?sounddata\"?%s*{")
	if not e then return out end
	local close = string.find(text, "}", e + 1, true) or #text + 1
	for k, v in string.gmatch(string.sub(text, e + 1, close - 1), "\"([^\"]*)\"%s*\"([^\"]*)\"") do
		if v ~= "" and (string.lower(string.sub(k, -4)) == "_npc") == (npc == true) and not seen[v] then seen[v] = true out[#out + 1] = v end
	end
	return out
end

--- The wave files (clean names) of a weapon class: its script's sounds (C++ weapons and any class with a
-- scripts/<class>.txt) and a SWEP's Primary.Sound / Secondary.Sound (strings, or a list of them; `wep`, the held
-- weapon, carries the values the SWEP set up at its creation, else the registered table).
-- npc true: the sounds of an NPC holding it (the script's *_npc entries; a SWEP's own sounds too, the NPC plays them).
function N.WeaponSoundFiles(class, wep, npc)
	local names = {}
	for _, s in ipairs(N.ParseWeaponSounds(file.Read("scripts/" .. class .. ".txt", "GAME"), npc)) do names[#names + 1] = s end
	local stored = weapons and weapons.GetStored and weapons.GetStored(class)
	for _, src in ipairs({ wep or false, stored or false }) do
		if src then
			for _, k in ipairs({ "Primary", "Secondary" }) do
				local t = src[k]
				local v = type(t) == "table" and t.Sound
				if type(v) == "string" then names[#names + 1] = v
				elseif type(v) == "table" then for _, x in ipairs(v) do if type(x) == "string" then names[#names + 1] = x end end end
			end
		end
	end
	local out, seen = {}, {}
	for _, s in ipairs(names) do if s ~= "" then scriptFiles(s, out, seen) end end
	return out
end

--- True when the weapons' sounds are decoded ahead: native own sounds, background decoding and the option on.
function N.WeaponPrewarmOn()
	return N.ready and pba_native and pba_native.LoadSoundAsync and A.NativeOwn()
		and (A.cfg.native_predecode or 1) >= 0.5 and (A.cfg.native_prewarm_weapons or 1) >= 0.5 or false
end

--- Queues the sound files of a weapon (its entity) for decoding ahead, once per class (until the module
-- drops its sounds). Returns the number of files queued.
function N.PrewarmWeapon(wep)
	if not N.WeaponPrewarmOn() or not IsValid(wep) then return 0 end
	local class = wep:GetClass()
	N.wpnDone = N.wpnDone or {}
	if N.wpnDone[class] then return 0 end
	N.wpnDone[class] = true
	local files = N.WeaponSoundFiles(class, wep)
	N.wpnQueue = N.wpnQueue or {}
	for _, n in ipairs(files) do N.wpnQueue[#N.wpnQueue + 1] = n end
	N.wpnStats = N.wpnStats or { weapons = 0, files = 0, started = 0 }
	N.wpnStats.weapons = N.wpnStats.weapons + 1
	N.wpnStats.files = N.wpnStats.files + #files
	return #files
end

local nextWeaponPoll = 0
hook.Add("Think", "pba_native_prewarm_weapons", function()
	if not N.ready then return end
	local now = RealTime()
	if now >= nextWeaponPoll then
		nextWeaponPoll = now + WEAPON_POLL
		local ply = LocalPlayer()
		if IsValid(ply) and N.WeaponPrewarmOn() then
			-- the weapon in his hands first (a held weapon: a pickup, a give, a map load, a switch)
			N.PrewarmWeapon(ply:GetActiveWeapon())
			for _, w in ipairs(ply:GetWeapons()) do N.PrewarmWeapon(w) end
		end
	end
	local q = N.wpnQueue
	if not q or #q == 0 or not (N.WeaponPrewarmOn() or N.NpcWeaponPrewarmOn()) then return end
	N.wpnInflight = N.wpnInflight or {}
	local busy = 0
	for m in pairs(N.wpnInflight) do
		if pba_native.SoundPending(m) then busy = busy + 1 else N.wpnInflight[m] = nil end
	end
	local started = 0
	while #q > 0 and started < WEAPON_PER_FRAME and busy < WEAPON_INFLIGHT do
		local n = table.remove(q, 1)
		if decodeAhead(n) then
			N.wpnInflight[n] = true
			started, busy = started + 1, busy + 1
			if N.wpnStats then N.wpnStats.started = N.wpnStats.started + 1 end
		end
	end
end)

-- a weapon picked up: decoded ahead at once, not at the next poll
hook.Add("HUDWeaponPickedUp", "pba_native_prewarm_weapons", function(wep) N.PrewarmWeapon(wep) end)

-- ------------------------------------------------------------------ the NPCs' weapons (pba_native_prewarm_npc_weapons)
-- The shots of a Combine soldier, a Metropolice or a rebel are other sources' sounds, played by the module like
-- every sound, but the first play of a file not decoded yet goes to the engine (pba_native_predecode): the first
-- shot of each NPC weapon was sharper than the next ones (no HRTF, no reverb). The player's prewarm leaves the
-- NPC variants out ("..._npc" entries of a weapon script), so these files were never decoded ahead. They are
-- queued (with the player's weapons': at most WEAPON_PER_FRAME decodes started a frame, WEAPON_INFLIGHT at once)
-- for the weapons listed by the map's NPCs (additionalequipment, read from the BSP entity lump: NPCs out of
-- view do not exist on the client yet) and for the weapons NPCs hold as they come into view (spawn menu,
-- npc_maker, a NPC entering the PVS): found by a short scan after an NPC or a weapon is created.
local NPC_POLL, NPC_SCAN_S = 0.2, 3

--- True when the NPC weapons' sounds are decoded ahead: the module, background decoding and the option on.
function N.NpcWeaponPrewarmOn()
	return N.ready and pba_native and pba_native.LoadSoundAsync
		and (A.cfg.native_predecode or 1) >= 0.5 and (A.cfg.native_prewarm_npc_weapons or 1) >= 0.5 or false
end

--- Queues the NPC sound files of a weapon class (`wep`, a held SWEP entity, gives its own sounds), once per class
-- (until the module drops its sounds). Returns the number of files queued.
function N.PrewarmNpcWeapon(class, wep)
	if not N.NpcWeaponPrewarmOn() or type(class) ~= "string" or class == "" then return 0 end
	N.npcWpnDone = N.npcWpnDone or {}
	if N.npcWpnDone[class] then return 0 end
	N.npcWpnDone[class] = true
	local files = N.WeaponSoundFiles(class, wep, true)
	N.wpnQueue = N.wpnQueue or {}
	for _, n in ipairs(files) do N.wpnQueue[#N.wpnQueue + 1] = n end
	N.npcWpnStats = N.npcWpnStats or { weapons = 0, files = 0, mapWeapons = 0, mapMs = 0 }
	N.npcWpnStats.weapons = N.npcWpnStats.weapons + 1
	N.npcWpnStats.files = N.npcWpnStats.files + #files
	return #files
end

--- The weapon classes the map's NPCs are given (additionalequipment of the entity lump), queued once per map
-- load / render start. Returns the number of classes found (nil when the lump cannot be read).
function N.PrewarmMapNpcWeapons()
	local t0 = SysTime()
	local list = A.BSP.EntityValues(game.GetMap(), "additionalequipment")
	if not list then return nil end
	for _, c in ipairs(list) do N.PrewarmNpcWeapon(string.lower(c)) end
	N.npcWpnStats = N.npcWpnStats or { weapons = 0, files = 0, mapWeapons = 0, mapMs = 0 }
	N.npcWpnStats.mapWeapons = #list
	N.npcWpnStats.mapMs = (SysTime() - t0) * 1000
	return #list
end

--- The weapons held by the NPCs that exist now on the client: queued.
function N.ScanNpcWeapons()
	for _, w in ipairs(ents.GetAll()) do
		if IsValid(w) and w:IsWeapon() then
			local o = w:GetOwner()
			if IsValid(o) and o:IsNPC() then N.PrewarmNpcWeapon(w:GetClass(), w) end
		end
	end
end

local nextNpcPoll = 0
hook.Add("Think", "pba_native_prewarm_npc_weapons", function()
	if not N.ready then return end
	local now = RealTime()
	if now < nextNpcPoll or not N.NpcWeaponPrewarmOn() then return end
	nextNpcPoll = now + NPC_POLL
	if not N.npcMapDone then
		N.npcMapDone = true
		N.PrewarmMapNpcWeapons()
		N.ScanNpcWeapons()
	elseif N.npcScanUntil and now < N.npcScanUntil then
		N.ScanNpcWeapons()
	end
end)

-- an NPC or a weapon created (a spawn, a NPC coming into view): its owner is known a few frames later, so the
-- scan runs for a few seconds
hook.Add("OnEntityCreated", "pba_native_prewarm_npc_weapons", function(e)
	if not N.ready or not IsValid(e) then return end
	local c = e:GetClass()
	if string.sub(c, 1, 4) == "npc_" or string.sub(c, 1, 7) == "weapon_" or e:IsNPC() or e:IsWeapon() then
		N.npcScanUntil = RealTime() + NPC_SCAN_S
	end
end)

cvars.AddChangeCallback("pba_native_predecode", function(_, _, new)
	if tonumber(new) == 1 then N.Prewarm() else N.prewarm = nil end
end, "pba_native")

-- ------------------------------------------------------------------ stereo files
-- The module keeps both channels of a stereo file (pba_native.SetVoiceStereo). Source reads some of them
-- as two variants, by the sound characters in front of the name (public/soundchars.h):
--   "^" distance variant: left = near, right = far, crossfaded with the distance (240 -> 1320 u, the range
--       the engine copies follow too: A.DistVariantPos);
--   "<" directional: left = front facing, right = rear facing, mixed by the source's facing;
--   ">" Doppler: left = incoming, right = outgoing;
-- and plays the other stereo files as stereo ("(" spatialised stereo, or none). Summed to mono (the module
-- before), a "^" gunshot carried its far tail at 2 m and its near crack at 2000 u, and a stereo file lost
-- its width. pba_native_stereo 0: the old mono downmix. pba_native_stereo_width: the stereo image kept
-- around the spatialised centre, near the source only (full up to 240 u, none past 1320 u: far away both
-- channels come from the same point).
N.stereo = N.stereo or {} -- clean name -> true (two different channels), false (mono); nil: not known
local DV_MIN, DV_MAX = 240, 1320

--- Channel mix (sel: 1 left, -1 right, 0 both) and stereo width of a voice playing `name` (with its sound
-- characters) heard `d` units away. ent, S, L: the source entity and positions (for "<" and ">").
function N.StereoMix(name, d, ent, S, L)
	if (A.cfg.native_stereo or 1) < 0.5 then return 0, 0 end
	name = name or ""
	local pre = string.sub(name, 1, #name - #A.SoundFile(name))
	local far = math.Clamp(((d or 0) - DV_MIN) / (DV_MAX - DV_MIN), 0, 1)
	if string.find(pre, "^", 1, true) then return 1 - 2 * far, 0 end
	if string.find(pre, "<", 1, true) then
		if not (IsValid(ent) and S and L) or ent:IsWorld() then return 0, 0 end
		local u = L - S
		if u:LengthSqr() < 1 then return 0, 0 end
		u:Normalize()
		return math.Clamp(ent:GetForward():Dot(u), -1, 1), 0 -- front facing the listener: the left channel
	end
	if string.find(pre, ">", 1, true) then
		if not (S and L) then return 0, 0 end
		local u = L - S
		if u:LengthSqr() < 1 then return 0, 0 end
		u:Normalize()
		local closing = (N.VelocityOf(ent) - N.ListenerVelocity()):Dot(u)
		if math.abs(closing) < 1 then return 0, 0 end
		return closing > 0 and 1 or -1, 0
	end
	return 0, (A.cfg.native_stereo_width or 0) * (1 - far)
end

--- Sends the stereo mix of voice id (st: a table the last values are kept on, so a followed voice sends only
-- changes). Mono files (known from their decoding) cost nothing.
function N.ApplyStereo(id, name, d, ent, S, L, st)
	if not (id and pba_native.SetVoiceStereo) then return end
	local n = string.lower(A.SoundFile(name or ""))
	if N.stereo[n] == false then return end
	local sel, w = N.StereoMix(name, d, ent, S, L)
	if st then
		if st.stSel == nil and sel == 0 and w == 0 then return end -- (the module's defaults)
		if st.stSel and math.abs(st.stSel - sel) < 0.02 and math.abs(st.stW - w) < 0.02 then return end
		st.stSel, st.stW = sel, w
	elseif sel == 0 and w == 0 then
		return
	end
	pba_native.SetVoiceStereo(id, sel, w)
end

-- Steam Audio's default air absorption model (per metre, low / mid / high)
local AIR = { 0.0002, 0.0017, 0.0182 }
local UNIT_M = 0.01905

-- Widest spread between the strongest and the weakest band of an EQ asked of the module (dB). Steam Audio's 3-band EQ is a
-- cascade (low shelf, peak, high shelf): the DirectEffect floors every band at 1/16 of the strongest (-24 dB) and the
-- path effect, which does not, bleeds across bands once the gains are deep (measured: asking 40-60 dB between bands
-- gave 10-25 dB errors in bands nobody asked about). So PBA never asks for more than 30 dB between bands. What is
-- cut beyond that (the highs of a source 300 m away, -48 dB of air) is not: they stay 30 dB under the strongest band.
N.EQ_RANGE_DB = 30
--- The EQ (l, m, h) with every band raised to at most N.EQ_RANGE_DB under the strongest one; inside the range, untouched.
-- A band the module can take: Steam Audio's path effect divides by its mid band (0/0 = NaN), and a math.max / math.min with a
-- NaN lets it through. Not a number or infinite: 1 (no filtering, the level is the gain's business); else at least 1e-4
-- (-80 dB, under every floor of the EQ's makers; the module bounds it again at its boundary).
local function saneBand(x)
	if x ~= x or x == math.huge or x == -math.huge then return 1 end
	return x < 1e-4 and 1e-4 or x
end
function N.ClampEQRange(l, m, h)
	l, m, h = saneBand(l), saneBand(m), saneBand(h)
	local floor = math.max(l, m, h) * 10 ^ (-N.EQ_RANGE_DB / 20)
	return math.max(l, floor), math.max(m, floor), math.max(h, floor)
end

--- EQ of a voice: its low-pass (level lp, continuous loss lpDb when the caller has it: N.LowpassEQ), times
-- air absorption over `len` units of path.
function N.VoiceEQ(lp, len, lpDb)
	local l, m, h = N.LowpassEQ(lp, lpDb)
	if (A.cfg.native_air or 0) < 0.5 or not len then return N.ClampEQRange(l, m, h) end
	local d = len * UNIT_M
	return N.ClampEQRange(l * math.exp(-AIR[1] * d), m * math.exp(-AIR[2] * d), h * math.exp(-AIR[3] * d))
end

--- Shooter of a weapon emission and its aim now, or nil when the sound is not one. A weapon emission: the
-- sound's entity is a weapon (a SWEP's self:EmitSound), or it was emitted on the weapon channel (CHAN_WEAPON:
-- the shot of an NPC or player emitted on the shooter itself). Footsteps, voices and pain sounds of the same
-- player are not: a voice heard -8 dB from behind, swinging as the speaker turned, was the dipole applied to
-- every player and NPC sound (audit).
function N.WeaponAim(ent, chan)
	if not IsValid(ent) then return nil end
	local owner
	if ent:IsWeapon() then
		owner = ent:GetOwner()
	elseif chan == CHAN_WEAPON then
		owner = ent
	end
	if not (IsValid(owner) and (owner:IsPlayer() or owner:IsNPC())) then return nil end -- a weapon on the floor
	return owner, owner:IsPlayer() and owner:GetAimVector() or owner:GetForward()
end

-- Largest dipole weight: Steam Audio's dipole is |(1 - w) + w cos(theta)|^p, which turns negative (a rear lobe, a figure of
-- eight at w = 1) above 0.5; 0.5 is a cardioid, silent straight behind. The slider stops there (pba_native_dir), and a
-- value saved before the cap is held to it here.
N.DIR_MAX = 0.5

--- Dipole directivity of a weapon emission towards L (1 in front, 1 - 2w behind, floor 0.05); 1 for any
-- other sound. chan: the sound's channel; aim: the aim taken when the sound was emitted (a shot does not
-- swing round when the shooter turns while its tail plays); without it, the aim now.
function N.Directivity(ent, L, chan, aim)
	local w = math.min(A.cfg.native_dir or 0, N.DIR_MAX)
	if w <= 0 or not L then return 1 end
	local owner, now = N.WeaponAim(ent, chan)
	if not owner then return 1 end
	-- the listener's own shots (pba_native_own: centered on him): he is the shooter, not behind the muzzle
	if LocalPlayer and owner == LocalPlayer() and A.NativeOwn and A.NativeOwn() and A.HearsFromSelf(owner) then return 1 end
	local d = (L - owner:EyePos()):GetNormalized()
	return math.max((1 - w) + w * (aim or now):Dot(d), 0.05)
end

-- A microphone's speaker copy (SND_SPEAKER: Breencast jumbotrons, TVs): the engine runs it through
-- its speaker DSP preset; the module plays the bare file, so a small loudspeaker's band (bass and
-- treble cut, low / mid / high gains) stands for it.
N.SPEAKER_EQ = { 0.25, 1, 0.35 }

-- Reverb of natively rendered sounds: one rule for every sound (one-shots, loops, other addons' streams).
-- A sound has a source power and a distance law; only the law depends on the kind of sound (the full
-- version's physical law N.Law(lvl) for the game's sounds, the channel's own law for a stream, which its
-- addon chose). Everything else is derived the same way, never from how loud the game makes the direct:
--  * direct  = power x law(path length) x the path's losses;
--  * source reverb (pba_native.SourceReflect, a pool of slots shared by position: reflections simulated
--    FROM the source: its room, what spills out of its openings, a street's facades) = the source's power,
--    its level at 1 m (N.SlotSend: never more than the direct a 1/r law would give times d / 1 m, so a loud
--    source clipped at full scale does not get a reverb louder than what is heard);
--  * the listener's room (listener-centric reverb, the module's room bus) = what ENTERS the listener's space
--    by an opening or a wall: the energy at that entry point = power x law(source -> entry) x the losses on
--    the way (N.EntrySend), times a share growing with how much of the clear line's energy the arrivals lost (N.ShadowShare: the
--    slot alone in clear sight, the room bus growing into the shadow, never a switch). Without a slot (pool full, an
--    older module) a voice falls back to the room bus at its gain (the 1.0 behaviour).
-- History of the shortcuts this replaces (each one gave cliffs): the send following the direct gain (dry
-- far sources), a one-trace enclosure guess (17 dB under an overhang), the room fed only through walls (a
-- small room reached by openings: no reverb at all), a x distance factor on the room send (with a flat
-- stream law the reverb depended on where the entry point lay: 16 dB in 80 u on gm_melancholia's stairs).
N.REF_UNITS = 52.49 -- 1 m

-- Distance law of the full version (user's decision, 2026-11-09): a natively rendered voice falls like a
-- real sound, 1/r from 1 m (-6 dB per doubling), not by the engine's much gentler law (a sound of level 75
-- loses ~3 dB from 1 m to 5.5 m in the engine, 15 dB in reality; a stream is flat up to its fade distance).
-- With the engine's law the reverb could not be both physical and sensible (kept at a real balance, a
-- radio got LOUDER walking away). Scale: the game's own gain at 1 m. Loud sources keep their headroom: a
-- level above the engine's full scale (pba_fullscale_db) stays at full scale until spreading brings it down
-- (a level 140 gunshot is full scale up to ~300 m). Light (engine rendering) keeps the engine's law, and
-- other addons' BASS streams the law their channel was given (cl_streams).
-- pba_native_law_engine (0..1, parity audit C-9) moves it toward the engine's own law, in dB: for levels
-- 80-110 the 1/r law is 10-20 dB under the engine's (a level 85 machine at 500 u: -19.6 dB against -0.7 dB),
-- so sounds placed for the engine (distant ambience, a soundscape's far battle) fade much sooner and gunfire
-- (full scale in both) dominates. 0 = 1/r (default), 1 = the engine's gain (AC.EngineGain), in between the
-- dB interpolation of the two. Everything derived from the law (reverb sends, entry points) follows it.
local function spread(lvl, d)
	local AC = A.AC
	lvl = lvl or 75
	local fs = A.cfg.fullscale_db or 90
	local g = AC.EngineGain(N.REF_UNITS, lvl) * 10 ^ (math.max(lvl - fs, 0) / 20) * N.REF_UNITS / math.max(d or 0, N.REF_UNITS)
	local k = A.cfg.native_law_engine or 0
	if k <= 0 then return g end
	local e = AC.EngineGain(math.max(d or 0, 1), lvl)
	if k >= 1 then return e end
	return g ^ (1 - k) * e ^ k
end
--- Direct gain (before volume and native_gain) of a source of level lvl at distance d in clear sight.
function N.PhysClear(lvl, d) return math.min(spread(lvl, d), 1) end
--- Direct gain of a path voice: gEng = its engine-law gain (path losses included) at path length len,
-- rawLossDb = the voice's own loss before any headroom (v.rawLossDb, sh_paths). The real spreading is
-- applied with that loss. The headroom is already in spread() (a loud source above full scale), so the
-- raw loss must be used: the path model takes the headroom off the loss (AC.Headroom, ~48 dB for a level
-- 140 gunshot at 10 m), and a 49.5 dB wall then reached gEng as "no loss" (clamped to 0 dB): recovered
-- from gEng, the shot came out at full scale instead of -20 dB.
-- Without rawLossDb (an older caller), the loss is recovered from gEng as before (exact while the headroom
-- did not absorb all of it).
function N.PhysPath(gEng, len, lvl, rawLossDb)
	local AC = A.AC
	local d = math.max(len or 0, N.REF_UNITS)
	if rawLossDb then return math.min(spread(lvl, d) * 10 ^ (-math.max(rawLossDb, 0) / 20), 1) end
	local eng = math.max(AC.EngineGain(d, lvl or 75), 1e-6)
	local ratio = math.min(gEng / eng, 1)
	local loss = ratio >= 0.999 and 1 or ratio * 10 ^ (-AC.Headroom(lvl or 75, d, A.cfg.fullscale_db or 90) / 20)
	return math.min(spread(lvl, d) * loss, 1)
end
--- Source slot send (before volume and native_gain) of a source of level lvl at distance d: its power, the
-- 1 m level (a real balance against a 1/r direct); while the direct is clipped at full scale (a loud source
-- near) no more than the clipped direct times d / 1 m, so the reverb never outgrows what is heard.
function N.PhysSrcSend(lvl, d)
	return N.SlotSend(N.Law(lvl), d, spread(lvl, N.REF_UNITS)) * N.LoudWet(lvl)
end
--- Reverb share kept by a sound of level lvl (pba_native_loud_dry): the module's own rule to keep gunfire and
-- explosions sharp, not the engine's (the engine's dsp_db_min / dsp_db_mixdrop, the values of the current room
-- preset, lower the room mix of the sounds BELOW db_min: a quiet sound is dried, a loud one never is; measured on
-- the engine's recorded mix, so those convars are not read here). The module's reverb of a loud sound is physical
-- (fed at its 1 m power): in the open an SMG shot at 300 u got as much reflected energy as direct sound (+1.4 dB,
-- mostly the ground, rendered as Steam Audio's noise-built response), heard as muddled. Nothing up to
-- native_loud_dry_from (ordinary sounds, a 95 dB metal bang included, keep all of theirs), then a ramp in dB over
-- native_loud_dry_range levels down to native_loud_dry_db dB (a step only when the range is 0). Applied to every
-- reverb send of the sound (source slot, listener room, room bus without a slot), never to its direct sound.
function N.LoudWet(lvl)
	local cfg = A.cfg
	if (cfg.native_loud_dry or 0) < 0.5 then return 1 end
	local over = (lvl or 75) - (cfg.native_loud_dry_from or 95)
	if over <= 0 then return 1 end
	local range = cfg.native_loud_dry_range or 15
	local t = range > 0 and math.min(over / range, 1) or 1
	return 10 ^ (-(cfg.native_loud_dry_db or 20) * t / 20)
end
--- 1/r from 1 m without a sound level (full scale at 1 m). Not the law of other addons' BASS streams: they keep
-- the channel's own (cl_streams, bassGain: the addon chose the range; a radio set to Set3DFadeDistance(1e6)
-- came out 14 dB weaker at 5 m with this one).
function N.PhysStream(d) return N.REF_UNITS / math.max(d or 0, N.REF_UNITS) end
--- The full version's law of a sound of level lvl (clipped at full scale), as a function of distance.
function N.Law(lvl) return function(d) return math.min(spread(lvl, d), 1) end end
--- Source slot send for a law at the source-listener distance d: the source's power (its level at 1 m
-- before any clipping, power1m, default law(1 m)), but never more than the clipped direct x d / 1 m: equal
-- for an unclipped 1/r law; a loud source clipped at full scale near gets a reverb that grows as its direct
-- stops being clipped (a far gunshot keeps a strong echo); a flat law (a stream heard everywhere alike)
-- gives its 1 m level, never a reverb growing with the distance.
function N.SlotSend(law, d, power1m)
	d = math.max(d or 0, N.REF_UNITS)
	return math.min(power1m or law(N.REF_UNITS), law(d) * d / N.REF_UNITS)
end
--- A voice's linear path losses: its raw loss (before any headroom) when known, else recovered from its
-- engine-law gain.
function N.LossLin(v, lvl)
	if v.rawLossDb then return 10 ^ (-math.max(v.rawLossDb, 0) / 20) end
	local len = math.max(v.len or 0, N.REF_UNITS)
	return math.min((v.gain or 0) / math.max(A.AC.EngineGain(len, lvl or 75), 1e-6), 1)
end
--- Listener-room send of a path voice: the energy where it enters the listener's space (its apparent
-- position: the last opening, or the wall it comes through) = law(source -> entry) x the path's losses,
-- times the square root of N.ShadowShare (pba_native_room_shadow).
--- Share (energy, 0..1) of an arrival's entering energy the listener's room bus renders, from how much of
-- the clear line's energy the arrivals lost (dB: the set's, P.ShadowOf, or one arrival's own): growing
-- linearly in dB from none in clear sight to all of it at pba_native_room_shadow_db (20 dB: behind a wall,
-- round a sharp corner). The source's reverb slot renders what the source's own reflections bring wherever
-- the listener stands, in clear sight and round a jamb alike; the room bus is there for what they miss (the
-- far side of walls, small rooms reached by openings where the slot's rays find nothing: gm_melancholia),
-- and that grows with the shadow. Before, the room bus went from nothing (clear line) to the full entering
-- energy (a route bending 0 degrees round a door jamb, 0 dB): rp_downtown's radio, heard outside its room's
-- doorway, switched its reverb up by 16 dB in one 4 u step (doorway_lateral, native_send_continuity).
function N.ShadowShare(lossDb)
	if (A.cfg.native_room_shadow or 1) < 0.5 then return 1 end
	local full = math.max(A.cfg.native_room_shadow_db or 20, 1e-3)
	return math.Clamp((lossDb or 0) / full, 0, 1)
end
--- Share (energy, 0..1) of the entering flux the listener's room bus renders for an arrival through an opening
-- (pba_native_room_open_area): the power that enters is the flux at the entry times the opening's area, and
-- the room bus takes its input as a source's level at 1 m, i.e. that power over 4 pi (1 m)^2. A doorway
-- (48 x 96 u) gives 0.13 (-8.8 dB). Before, the full flux at the entry: the listener's room reverb came out
-- 16-20 dB above the source slot's reverb at the same spot (rp_downtown, outside the radio room). An arrival
-- through a wall (transmission) enters over the whole wall: 1. 0 = off (1 for every arrival).
function N.OpeningShare(v)
	local a = A.cfg.native_room_open_area or 0
	if a <= 0 or not v then return 1 end
	local o = math.min(a / (4 * math.pi * N.REF_UNITS * N.REF_UNITS), 1)
	-- a transmission enters over its wall (1), but the part of it that went over the wall's edge (P.AddEdge:
	-- edgeShare) through the opening beside it, like a route
	if v.kind == "transmission" then return 1 - (v.edgeShare or 0) * (1 - o) end
	-- a voice holding a way through a floor (P.ThroughRoute): the share of it still entering over the wall
	if v.entryWall then return v.entryWall + (1 - v.entryWall) * o end
	return o
end
function N.EntrySend(law, v, L, lossLin)
	local entry = math.max(v.entryLen or ((v.len or 0) - (v.pos and v.pos:Distance(L) or 0)), N.REF_UNITS)
	-- the loss of the whole set of arrivals (v.shadowDb, P.ShadowOf) when the voice comes from a result, else
	-- this arrival's own
	local l = math.Clamp(lossLin or 1, 0, 1)
	local sh = N.ShadowShare(v.shadowDb or (l > 0 and -20 * math.log10(l) or 300))
	return law(entry) * l * math.sqrt(sh * N.OpeningShare(v))
end
--- One sound rendered by ONE native voice (a loop, a stream): its voices together. Gain and diffuse share in
-- power, the listener-room send in power (N.EntrySend each), and (pba_native_voice_mix) the apparent position
-- and the spectrum mixed by energy too: direction weighted by energy at the energy-weighted distance (as
-- P.SelectVoices merges members), the high-band loss by band energy (AC.MixTilt). The former rule took the
-- first voice's position and filter: where two voices were near the same level and swapped order, the loop
-- jumped by up to 177 degrees and 12.6 dB of low-pass in one 4 u step (rp_downtown, the radio heard in the
-- street: the transmission at the wall beside the listener against the route through the doorway).
-- law: the sound's distance law (N.Law(lvl), a stream's own). lvl: for N.PhysPath / N.LossLin.
function N.MixVoices(voices, L, lvl, law, gainOf)
	local p, dp, pt = 0, 0, 0
	local sum, dist, tilts = Vector(0, 0, 0), 0, {}
	for _, v in ipairs(voices) do
		local g = gainOf and gainOf(v) or N.PhysPath(v.gain, v.len, lvl, v.rawLossDb)
		local e = g * g
		p, dp = p + e, dp + (v.diffuse or 0) * e
		local s = N.EntrySend(law, v, L, N.LossLin(v, lvl))
		pt = pt + s * s
		local d = v.pos - L
		local dl = d:Length()
		if dl > 1e-3 then sum:Add(d * (e / dl)) dist = dist + dl * e end
		tilts[#tilts + 1] = e
		tilts[#tilts + 1] = v.lpDb or A.AC.LevelDb(v.lp or 0)
	end
	local v1 = voices[1]
	local m = { gain = math.sqrt(p), diffuse = dp / math.max(p, 1e-12), send = math.sqrt(pt),
		pos = v1.pos, lp = v1.lp, lpDb = v1.lpDb }
	if (A.cfg.native_voice_mix or 0) >= 0.5 and #voices > 1 and p > 0 then
		if sum:LengthSqr() > 1e-12 then m.pos = L + sum:GetNormalized() * (dist / p) end
		m.lpDb = A.AC.MixTiltList(tilts)
		m.lp = A.AC.LowpassLevel(m.lpDb)
	end
	return m
end
--- The listener-room send of a voice whose source reverb slot comes and goes (continuity review C9): the
-- entering part when the voice has its slot, its whole gain when it has none (the room bus stands in for the
-- slot), faded over SLOT_FADE_S instead of switched (a slot is a resource: getting or losing one is an event in
-- time, not a step in space). o: the voice's record (o.slotW, o.slotT kept on it). pba_native_slot_fade 0: switched.
local SLOT_FADE_S = 0.3
function N.SlotFadeSend(o, bound, entry, gain)
	local target = bound and 0 or 1
	if (A.cfg.native_slot_fade or 1) < 0.5 or not o.slotW then
		o.slotW, o.slotT = target, RealTime()
	else
		local now = RealTime()
		local step = (now - (o.slotT or now)) / SLOT_FADE_S
		o.slotT = now
		if o.slotW < target then o.slotW = math.min(o.slotW + step, target) else o.slotW = math.max(o.slotW - step, target) end
	end
	return (1 - o.slotW) * (entry or 0) + o.slotW * (gain or 0)
end
--- Binds a voice to a source reverb slot (call on every update, at least every 0.5 s). Returns true when
-- the voice has a slot (then the room bus must only get the transmission part).
-- wet: the voice's wet share (N.LoudWet), with pba_native_slot_fallback_wet the cap of what the voice hands the room bus while
-- its slot is simulated (its gain x wet, what a voice without a slot gets; a module before 2026-11-19 ignores it)
function N.BindSource(id, S, srcSend, wet)
	if not (id and pba_native.SourceReflect) then return false end
	if (A.cfg.native_slot_fallback_wet or 1) < 0.5 then wet = nil end
	local slot = pba_native.SourceReflect(id, S, srcSend, N.ProbeLift(S) or 0, wet)
	return slot ~= nil and slot >= 0
end

local PROBE_M, PROBE_HEIGHT = 52.49, 1.0 -- units per metre; height (m) above the floor the slot's long-window reverb time is estimated at
local probeCache, probeStamp = {}, 0
--- Metres above S at which the module estimates the reverb time of the source reverb slot at S (pba_native_source_long_rt, else nil
-- = the module estimates at S): the estimate is meaningless within ~0.5 m of a floor (a pipe, a footstep, a dropped prop: 0.1 s in
-- the high band, 20 s in the mid one, in a hall that rings 1.4 / 5.8 s), and the reverb time of a room does not depend on where
-- in it it is measured. A sound near the floor is lifted to PROBE_HEIGHT above it, never more than under 45 % of the headroom (a low
-- ceiling, a table). Cached per 0.6 m cell for 5 s: one source's updates cost no trace.
function N.ProbeLift(S)
	if (A.cfg.native_source_long_rt or 1) < 0.5 then return nil end
	local now = RealTime()
	if now - probeStamp > 5 then probeCache, probeStamp = {}, now end
	local key = math.floor(S.x / 32) .. "," .. math.floor(S.y / 32) .. "," .. math.floor(S.z / 32)
	local c = probeCache[key]
	if c ~= nil then return c or nil end
	local up = Vector(0, 0, 1)
	local down = util.TraceLine({ start = S, endpos = S - up * PROBE_M * PROBE_HEIGHT, mask = MASK_SOLID_BRUSHONLY })
	local lift = false
	if down.Hit and not down.StartSolid then
		local h = down.Fraction * PROBE_HEIGHT -- metres above the floor
		local ceil = util.TraceLine({ start = S, endpos = S + up * PROBE_M * 2, mask = MASK_SOLID_BRUSHONLY })
		local head = ceil.Hit and ceil.Fraction * 2 or 2
		local l = math.min(PROBE_HEIGHT - h, 0.45 * head)
		if l >= 0.05 then lift = l end
	end
	probeCache[key] = lift
	return lift or nil
end

--- Plays a voice natively. gain: linear, everything included. opt: { len = path length (units),
-- srcPos, srcSend = the source's true position and its slot send (N.PhysSrcSend x volume, before
-- native_gain): the voice takes a source reverb slot (one voice per sound: the dominant one);
-- roomSend = its listener-room send (N.EntrySend x volume, before native_gain) for a path voice;
-- sh = baked path field {w, sh1, sh2, sh3}, eq = {l, m, h} override, delay = seconds, diffuse = share
-- of the energy arriving diffuse (module: less direct, more room reverb, blurred direction),
-- lpDb = the voice's continuous loss behind lp (path.lpDb: N.LowpassDb), follow = { ent, vol, lvl, chan }
-- to follow a moving entity, wet = share of the reverb kept (N.LoudWet) for the room bus without a slot,
-- mix = the sound's mix groups (A.Mix.GroupsOf: the engine's mix value and ducking, cl_mix) }.
-- Returns true on success.
-- a spoken line (the engine's channel stealing never takes CHAN_VOICE, CHAN_STREAM nor CHAN_VOICE2, REVERSE.md
-- section 6): the module's voice cap drops it last (pba_native.Play, last argument; pba_native_protect_lines)
function N.ProtectLine(chan)
	return (A.cfg.native_protect_lines or 1) >= 0.5 and (chan == CHAN_VOICE or chan == CHAN_STREAM or chan == CHAN_VOICE2) or nil
end

-- The engine pauses the sounds emitted with SND_SHOULDPAUSE while the game is paused (single player, escape menu)
-- and resumes them after; the others keep playing. The module does the same for a voice played with the pausable
-- flag (pba_native.Play, argument after protect; Echo's last one): -> true | nil. Needs the module of API 2 (before
-- it, SetPaused froze every voice); pba_native_pause.
function N.PauseSupported() return (N.moduleApi or 0) >= 2 and pba_native ~= nil and pba_native.SetPaused ~= nil end
function N.PauseFlag(flags)
	return (A.cfg.native_pause or 1) >= 0.5 and N.PauseSupported() and bit.band(flags or 0, SND_SHOULDPAUSE or 128) ~= 0 or nil
end

--- True for the listener's own sound (his footsteps, his weapon's shots, his voice and pain: the entity is him or a
-- weapon he holds) when the module plays it (pba_native_own) and leaves its direct path unspatialised
-- (pba_native_own_direct): the engine does not spatialise the listener's own sounds, and the HRTF at 1 unit
-- coloured and softened them (the module's Play flag `own`; a module without it ignores it). nil otherwise.
function N.OwnDirect(ent, chan)
	if (A.cfg.native_own_direct or 1) < 0.5 or not (A.NativeOwn and A.NativeOwn()) or not IsValid(ent) then return nil end
	local lp = LocalPlayer()
	if not IsValid(lp) or not A.HearsFromSelf(lp) then return nil end -- (through a camera his sounds are spatialised like anybody's)
	if ent == lp then return true end
	local _, owner = A.ShotWeapon(ent, chan)
	return owner == lp or nil
end

local OWN_STREAM_IN, OWN_STREAM_OUT = 4, 16 -- units: a stream joins the listener's own within 4, leaves them beyond 16

--- True when a radio stream of another addon is the listener's own sound: its owner put it on his body (the position it
-- sets is his origin, his centre or his eyes: a boombox he carries, a worn speaker), so the engine would not spatialise
-- it, and the HRTF at a few units only jitters its direction. Same options as N.OwnDirect (pba_native_own_direct,
-- pba_native_own, his view is his own). `was`: it was his own already (hysteresis: it leaves beyond OWN_STREAM_OUT, so a
-- stream the owner jostles by a few units does not flip back and forth). The module fixes the flag for the life of a
-- voice: cl_streams.lua gives a new voice when the answer changes.
function N.OwnStream(pos, was)
	if not pos or (A.cfg.native_own_direct or 1) < 0.5 or not (A.NativeOwn and A.NativeOwn()) then return false end
	local lp = LocalPlayer()
	if not IsValid(lp) or not A.HearsFromSelf(lp) then return false end
	local lim = was and OWN_STREAM_OUT or OWN_STREAM_IN
	lim = lim * lim
	if pos:DistToSqr(lp:GetPos()) <= lim or pos:DistToSqr(lp:WorldSpaceCenter()) <= lim then return true end
	local L = A.ListenerPos()
	return L ~= nil and pos:DistToSqr(L) <= lim
end

function N.PlayVoice(name, pos, gain, lp, pitch, opt)
	if not N.render then return false end
	opt = opt or {}
	local ok, n = N.EnsureSound(name, opt.line and (A.cfg.native_line_decode or 1) >= 0.5)
	if A.IsSentence(name) then A.Sentences.Note(name, ok) end -- (the ledger of pba_sentences_report)
	if not ok then return false end
	local l, m, h = N.VoiceEQ(lp, opt.len, opt.lpDb)
	if opt.eq then l, m, h = l * opt.eq[1], m * opt.eq[2], h * opt.eq[3] end
	local sh = (A.cfg.native_path_fx or 0) >= 0.5 and opt.sh or nil
	local g = gain * A.cfg.native_gain
	-- reverb sends (see "Reverb of natively rendered sounds" above): the listener's room only for what
	-- comes through walls; the air-borne reverb from the source's slot. The listener is A.ListenerPos, as
	-- everywhere else (looking through a camera, the eye position put the wall 'behind' the wrong ear)
	local L = A.ListenerPos()
	local roomSend
	if opt.roomSend then roomSend = opt.roomSend * A.cfg.native_gain
	elseif opt.srcPos or opt.noRoom then roomSend = 0 end
	-- "#" (dry mix): the engine runs no DSP on it, no room reverb; the module gives it none either
	local srcPos = opt.srcPos
	if N.DryMix(name) then roomSend, srcPos = 0, nil end
	local id
	if A.Mix and opt.mix then id = A.Mix.Play(opt.mix, n, pos, g, l, m, h, pitch or 100, false, opt.delay or 0, sh, opt.diffuse or 0, roomSend, opt.offset, opt.protect, opt.pausable, opt.own)
	else id = pba_native.Play(n, pos, g, l, m, h, pitch or 100, false, opt.delay or 0, sh, opt.diffuse or 0, roomSend, opt.offset, opt.protect, opt.pausable, opt.own) end
	if id and id > 0 and A.NoteRendered then A.NoteRendered(name, g) end -- (pba_silent_handback)
	if id and id > 0 and srcPos and L then
		if not N.BindSource(id, srcPos, (opt.srcSend or gain) * A.cfg.native_gain, opt.wet) and not opt.roomSend then
			pba_native.Update(id, pos, g, l, m, h, pitch or 100, nil, g * (opt.wet or 1)) -- no slot: the room bus at its gain
		end
	end
	if id and id > 0 and L then
		N.ApplyStereo(id, name, opt.len or pos:Distance(L), opt.follow and opt.follow.ent, opt.srcPos or pos, L, opt.follow)
	end
	if id and id > 0 and opt.follow and IsValid(opt.follow.ent) then
		-- direct voice of a moving entity: follows it every frame like the engine does
		opt.follow.pitch = pitch or 100
		opt.follow.name = name
		opt.follow.eq = opt.eq -- a speaker's EQ, kept at every update (pba_native_speaker_follow)
		-- a weapon emission keeps the aim it was fired with (N.Directivity) while it follows the shooter
		if opt.follow.aim == nil then
			local _, aim = N.WeaponAim(opt.follow.ent, opt.follow.chan)
			opt.follow.aim = aim or false
		end
		N.follow[id] = opt.follow
	end
	return id and id > 0 and id or false
end

-- Doppler shift between a moving source and listener: f' = f (c + vL.u) / (c - vS.u), u = unit
-- vector source -> listener, c = 343 m/s in units. Clamped to half / double pitch.
local SPEED_UNITS = 343 / 0.01905
function N.Doppler(S, vS, L, vL)
	if (A.cfg.native_doppler or 0) < 0.5 then return 1 end
	local u = L - S
	local d = u:Length()
	if d < 1 then return 1 end
	u:Mul(1 / d)
	local k = (SPEED_UNITS - vL:Dot(u)) / math.max(SPEED_UNITS - vS:Dot(u), 1)
	return math.Clamp(k, 0.5, 2)
end

local function velocityOf(e)
	if not IsValid(e) then return vector_origin end
	local p = e.GetParent and e:GetParent()
	if IsValid(p) then e = p end -- welded / parented to a vehicle: its motion
	return e:GetVelocity()
end
N.VelocityOf = velocityOf

--- Listener velocity: the vehicle when driving, else the player.
function N.ListenerVelocity()
	local ply = LocalPlayer()
	if not IsValid(ply) then return vector_origin end
	local veh = ply.GetVehicle and ply:GetVehicle()
	if IsValid(veh) then
		local p = veh:GetParent()
		return (IsValid(p) and p or veh):GetVelocity()
	end
	return ply:GetVelocity()
end

-- voices bound to an entity (clear line): position and distance law updated every frame
N.follow = N.follow or {}

-- Every voice the module starts (pba_native.Play), for stopsound: the engine stops all its channels,
-- the module's voices must stop too (A.StopAllSounds). Ids of ended voices are harmless to stop;
-- entries are dropped after a while (long sounds are mirrors, which keep their own id).
N.started = N.started or {}
function N.WrapPlay()
	if not pba_native or pba_native.pbaPlayWrapped then return end
	local play = pba_native.Play
	pba_native.pbaPlayWrapped = true
	pba_native.Play = function(...)
		local id = play(...)
		if id and id > 0 then N.started[id] = RealTime() end
		return id
	end
end
N.WrapPlay()
timer.Create("pba_native_started_gc", 10, 0, function()
	local now = RealTime()
	for id, t in pairs(N.started) do if now - t > 120 then N.started[id] = nil end end
end)

--- Stops every voice the module plays (streams of BASS channels excepted: stopsound leaves them).
function N.StopAllVoices()
	if not pba_native then return end
	for id in pairs(N.started) do pba_native.StopVoice(id) end
	N.started = {}
	table.Empty(N.follow)
end
function N.UpdateFollowers(L)
	local vL = N.ListenerVelocity()
	for id, f in pairs(N.follow) do
		local e = f.ent
		if not IsValid(e) then
			-- the entity is gone: the engine plays its sound to the end where it was, so do we
			N.follow[id] = nil
		else
			local S = A.SoundPos({ Entity = e, Channel = f.chan })
			local d = S:Distance(L)
			local g = f.vol * N.PhysClear(f.lvl, d) * N.Directivity(e, L, f.chan, f.aim or nil) * A.cfg.native_gain
			local l, m, h = N.VoiceEQ(0, d)
			if f.eq and (A.cfg.native_speaker_follow or 1) >= 0.5 then l, m, h = l * f.eq[1], m * f.eq[2], h * f.eq[3] end
			local pitch = f.pitch * N.Doppler(S, velocityOf(e), L, vL)
			-- clear line: the reverb is the source slot's (bound at Play), kept alive while the voice lives
			if not pba_native.Update(id, S, g, l, m, h, pitch) then N.follow[id] = nil
			elseif f.name then N.ApplyStereo(id, f.name, d, e, S, L, f) end
		end
	end
end

--- Echoes of a loud sound (reflections only, on top of whatever plays the direct sound). enginePlays:
-- the engine plays this one (the player's own sounds, an echo-only relay), never the module. own: the
-- local player's own sound: never echoed here (with pba_native_own the module plays it and its source reverb
-- slot reflects it; the engine-played way had odd, short echoes and was removed).
N.echoSkip = N.echoSkip or {}
local function skip(why) N.echoSkip[why] = (N.echoSkip[why] or 0) + 1 end

--- A "#" sound (dry mix) the module renders without reverb: no source slot, no room send, no echoes, as
-- the engine runs no DSP on it (pba_native_dry_prefix).
function N.DryMix(name) return (A.cfg.native_dry_prefix or 1) >= 0.5 and A.IsDryMix(name) end

--- True when the module plays the local player's own sounds too (pba_native_own, with pba_native_all).
function A.NativeOwn()
	return N.render and (A.cfg.native_all or 0) >= 0.5 and (A.cfg.native_own or 1) >= 0.5 and A.Enabled() or false
end

--- Source strength of the echoes of a sound (before the engine's mix value, native_gain and pba_native_echo): its volume
-- times the source slot's send at the source-listener distance.
function N.EchoGain(data, pos)
	local L = A.ListenerPos()
	return (data.Volume or 1) * N.PhysSrcSend(data.SoundLevel or 75, (pos and L) and pos:Distance(L) or 0)
end

function N.Echo(data, pos, enginePlays, own)

	if not N.render or (A.cfg.native_echo or 0) <= 0 or not pba_native.Echo then return skip("off") end
	if own then return skip("own") end
	if N.DryMix(data.SoundName) then return skip("dry") end
	-- every sound played by the module ("all native"): its reflections come from its source reverb slot;
	-- echoes too would simulate the same reflections twice (audit). The ones the engine plays have no slot:
	-- without their echoes the player's own gunfire had no reflections at all
	if not enginePlays and (A.cfg.native_all or 0) >= 0.5 and pba_native.SourceReflect then return skip("slot") end
	local lvl = data.SoundLevel or 75
	if lvl < A.cfg.native_echo_lvl then return skip("level") end
	local ok, n = N.EnsureSound(data.SoundName)
	if not ok then return skip("sound") end
	-- source strength = the source's power, as its reverb slot has it (N.PhysSrcSend at the source-listener distance:
	-- its level at 1 m with the headroom of a loud level above full scale, never more than the clipped direct x d / 1 m,
	-- the loud-dry share): the echo and the slot reverb come from the same law, so their scales (pba_native_echo,
	-- pba_native_reverb) are comparable. It was the engine's gain at 1 m alone: no headroom, no loud-dry share, so a
	-- loud shot's echo did not follow its reverb with distance (100 m: +20 dB over a slot's). The impulse response carries
	-- the distance and the room.
	local gain = N.EchoGain(data, pos)
	local e = data.Entity
	-- the engine's mix value of this sound (cl_mix): its reverb is the sound's, scaled as the sound is
	if A.Mix then gain = gain * A.Mix.Value(A.Mix.GroupsOf(data.SoundName, IsValid(e) and e or data.EntIndex, data.Channel, lvl)) end
	local key = IsValid(e) and e:EntIndex() or (data.EntIndex or 0)
	-- a weapon emission: the echoes are louder where the shooter aims (same rule as N.Directivity: an NPC's
	-- shout or a player's footstep is not aimed)
	local w = math.min(A.cfg.native_dir or 0, N.DIR_MAX)
	local aim = nil
	if w > 0 then local _, a = N.WeaponAim(e, data.Channel) aim = a end
	-- (a relayed sound's own start time, A.SoundTimeDelay: its echoes start with it)
	local id = pba_native.Echo(n, pos, gain * A.cfg.native_gain, key, data.Pitch or 100, math.max(data.Delay or 0, 0), aim, aim and w or 0, N.PauseFlag(data.Flags))
	-- the channel mix of the sound as heard from here, the one its source slot would get (one input for the reflections of a
	-- sound): the far channel of a "^" sound only from 1320 u. It was the far channel at any distance ("reflections arrive
	-- from afar"), but the far channel is a recording of the shot far away, already weaker (npc_smg1_fire1: -11 dB), and the
	-- simulated response adds the distance again: an echo 11 dB under the slot reverb of the same sound at the same setting.
	if id and id > 0 then
		local L = A.ListenerPos()
		N.ApplyStereo(id, data.SoundName, (pos and L) and pos:Distance(L) or 0, e, pos, L)
	end
	N.echoes = (N.echoes or 0) + 1
end

-- ------------------------------------------------------------------ doors in the scene
-- Doors are instanced into the Steam Audio scene (one oriented box per door, moved with it):
-- reflections, echoes and baked-path validation then see a closed door. The direct sound keeps
-- pba's own door model (sh_doors), the world occlusion still ignores entities.
local DOOR_CLASSES = { prop_door_rotating = true, func_door = true, func_door_rotating = true }
-- other moving brush geometry of real maps (RP: garage doors, lifts, bridges, rotating parts)
local MOVER_CLASSES = { func_movelinear = true, func_tracktrain = true, func_rotating = true, func_physbox = true,
	func_physbox_multiplayer = true, func_brush = false }
-- large props (containers, vehicles, crates...) reflect sound too: same mechanism, capped
-- on the client, engine brush entities report their CLIENT class ("class C_BaseToggle" for a
-- func_door, ...): recognised by pattern on brush models ("*N")
local CLIENT_DOOR_PATTERNS = { "C_BaseDoor", "C_BaseToggle", "C_BasePropDoor" }
local CLIENT_MOVER_PATTERNS = { "MoveLinear", "TrackTrain", "FuncRotating", "PhysBox" }
local function brushKind(e, cls)
	if cls:sub(1, 6) ~= "class " then return nil end
	local m = e:GetModel()
	if not m or m:sub(1, 1) ~= "*" then return nil end
	for _, pat in ipairs(CLIENT_MOVER_PATTERNS) do if string.find(cls, pat, 1, true) then return "mover" end end
	for _, pat in ipairs(CLIENT_DOOR_PATTERNS) do if string.find(cls, pat, 1, true) then return "door" end end
	return nil
end

--- Shapes of the movers present (N.MoverHull, cached per map and model), computed while the world is built: in its
-- coroutine, spread over frames. One found later is computed when the door sync first sees it.
function N.PrecomputeMovers()
	if (A.cfg.native_movers_brushes or 1) < 0.5 then return end
	local t0 = SysTime()
	for _, e in ipairs(ents.GetAll()) do
		if N.Yield then N.Yield() end
		if IsValid(e) then
			local cls = e:GetClass()
			local m = e:GetModel()
			if m and m:sub(1, 1) == "*" and (MOVER_CLASSES[cls] or brushKind(e, cls) == "mover") then N.MoverHull(m) end
		end
	end
	N.moverPrecomputeMs = (SysTime() - t0) * 1000
end

local PROP_CLASSES = { prop_physics = true, prop_physics_multiplayer = true, prop_dynamic = true, prop_vehicle_jeep = true,
	prop_vehicle_airboat = true, prop_vehicle_prisoner_pod = false }
local PROP_MIN_SIZE = 64 -- units (largest box dimension); the count is capped by pba_native_props_max
-- Which props are in the scene is re-decided every PROP_RANK_S: the cap keeps those that matter most
-- to the listener NOW. Before, the first pba_native_props_max props of ents.GetAll() got in and every
-- later one was skipped for good: on an RP map with 300 props, the container next to the player could
-- be left out for the session while crates 5000 u away reflected.
local PROP_RANK_S = 2
-- pba_native_props_calm: seconds between two scene commits made for props alone (doors commit at once)
local PROP_COMMIT_S = 1
-- a prop in the scene keeps its place against one only slightly more relevant (no swapping back and
-- forth of two props at the same distance; each swap re-commits the scene)
local PROP_KEEP = 1.5
N.doors = N.doors or {}
-- entities not to look at again (too small). Recreated on load: the former code also put the props over
-- the cap here, for good (autorefresh of a running game must give them their chance)
N.dynSkip = setmetatable({}, { __mode = "k" })
N.propInfo = setmetatable({}, { __mode = "k" }) -- entity -> { mn, mx, big, thick, area }

local function boxMesh(mn, mx)
	local v = {}
	for i = 0, 7 do
		local x = bit.band(i, 1) == 0 and mn.x or mx.x
		local y = bit.band(i, 2) == 0 and mn.y or mx.y
		local z = bit.band(i, 4) == 0 and mn.z or mx.z
		v[#v + 1], v[#v + 2], v[#v + 3] = x, y, z
	end
	-- 12 triangles (6 faces)
	local t = { 0, 2, 1, 1, 2, 3, 4, 5, 6, 5, 7, 6, 0, 1, 4, 1, 5, 4, 2, 6, 3, 3, 6, 7, 0, 4, 2, 2, 4, 6, 1, 3, 5, 3, 7, 5 }
	return v, t
end

N.BoxMesh = boxMesh
local MOVED_NEAR2 = 1024 * 1024 -- units: dynamic objects whose motion re-evaluates the continuous sounds
-- pba_native_scene_far_m: a door, mover or prop farther than that from the listener sends its move once it has rested
-- FAR_REST_S (or after FAR_MAX_S of motion). Every scene commit restarts Steam Audio's accumulated reflections of every
-- source (and the source slots' listener anchor): a door swinging or a car driving 40 m off committed the scene at every
-- 0.1 s sync, and the reverb's averages never converged (srcAnchorMoves ~4/s with the listener still)
local FAR_REST_S, FAR_MAX_S = 0.3, 5
local UNITS_PER_M = 1 / 0.01905
-- Spinners: an object that has moved at every sync for pba_native_spin_s (3 s) without its centre leaving a
-- AMBIENT_RADIUS2 (16 u) circle turns in place for ever (a ceiling fan, a radar, a windmill): its place in the
-- scene is refreshed every AMBIENT_PERIOD s only, and it no longer empties the path cache. Each refresh is a scene
-- commit, and the invalidation restarted the far slicer's waiting jobs: rp_hunter_cathedral's four fans cost 10
-- commits and 10 invalidations a second (test/perf/ambient_movers.lua). Anything that travels (a door, a lift, a
-- vehicle, a rolling prop) leaves the circle and keeps the 0.1 s sync.
local AMBIENT_RADIUS2, AMBIENT_PERIOD = 16 * 16, 2
-- (pba_native_spin_s: the seconds of it, 3 by default; 0 = off)

--- Box facts of a door, mover or prop: bounds, largest and smallest dimension (the smallest is the
-- thickness sound crosses: saMaterial), mean face area (its acoustic size for the ranking). hull: a prop's
-- collision model (N.PropHull), whose bounds then replace the entity's.
local function boxInfo(e, hull)
	local mn, mx = e:OBBMins(), e:OBBMaxs()
	if hull then mn, mx = hull.mn, hull.mx end
	local sz = mx - mn
	return { mn = mn, mx = mx, big = math.max(sz.x, sz.y, sz.z), thick = math.max(math.min(sz.x, sz.y, sz.z), 1),
		area = (sz.x * sz.y + sz.y * sz.z + sz.x * sz.z) / 3, hull = hull }
end

-- Collision models of the props, per model and scale: { v, t, mn, mx, tris } in the entity's frame, false = none.
-- A prop entered the scene as its bounding box (OBBMins / OBBMaxs), which for a model is its render bounds: for a
-- hollow model (a shelf: 4 % of its box) or an animated one (models/props_silo/rocket_hatch.mdl: 290 x 301 x
-- 1230 u of bounds, a 28 x 44 x 28 u collision) the box sealed the open space inside it, and a source standing
-- there (Kleiner in ep2_outland_11) had no reverb at all. The collision model is what the game's own traces and
-- players see as solid. A model with no collision model at all (no .phy) is solid to nothing: it stays out of the
-- scene (second return value true). ep2_outland_11's lift doors (models/props_silo/silo_elevator_door.mdl, no .phy,
-- 72 x 146 x 87 u of render bounds holding both leaves open and shut) filled half the cabin each and sealed it;
-- the doors players bump into are func_door brushes of their own.
N.hullCache = N.hullCache or {}
local HULL_TRIS_MAX = 768 -- above: one box per convex part (12 triangles each), still the parts' own volumes
function N.PropHull(model, scale)
	if not model or model == "" or model:sub(1, 1) == "*" then return nil end
	scale = scale or 1
	local key = model .. "@" .. scale
	local c = N.hullCache[key]
	if c == "none" then return nil, true end
	if c ~= nil then return c or nil end
	if string.EndsWith(model, ".mdl") and not file.Exists(model:sub(1, -5) .. ".phy", "GAME") then
		N.hullCache[key] = "none"
		return nil, true
	end
	local hull = false
	local ok, cs = pcall(ents.CreateClientProp, model)
	if ok and IsValid(cs) then
		cs:PhysicsInit(SOLID_VPHYSICS)
		local po = cs:GetPhysicsObject()
		local convexes = IsValid(po) and po:GetMeshConvexes() or nil
		cs:Remove()
		if convexes and #convexes > 0 then
			local n = 0
			for _, cv in ipairs(convexes) do n = n + math.floor(#cv / 3) end
			local v, t = {}, {}
			local mn = Vector(math.huge, math.huge, math.huge)
			local mx = -mn
			local function grow(p)
				mn.x, mn.y, mn.z = math.min(mn.x, p.x), math.min(mn.y, p.y), math.min(mn.z, p.z)
				mx.x, mx.y, mx.z = math.max(mx.x, p.x), math.max(mx.y, p.y), math.max(mx.z, p.z)
			end
			for _, cv in ipairs(convexes) do
				if n <= HULL_TRIS_MAX then
					for i = 1, #cv - #cv % 3 do
						local p = cv[i].pos * scale
						grow(p)
						v[#v + 1], v[#v + 2], v[#v + 3] = p.x, p.y, p.z
						t[#t + 1] = #v / 3 - 1
					end
				elseif #cv > 0 then
					local a = Vector(math.huge, math.huge, math.huge)
					local b = -a
					for i = 1, #cv do
						local p = cv[i].pos * scale
						grow(p)
						a.x, a.y, a.z = math.min(a.x, p.x), math.min(a.y, p.y), math.min(a.z, p.z)
						b.x, b.y, b.z = math.max(b.x, p.x), math.max(b.y, p.y), math.max(b.z, p.z)
					end
					local bv, bt = boxMesh(a, b)
					local base = #v / 3
					for i = 1, #bv do v[#v + 1] = bv[i] end
					for i = 1, #bt do t[#t + 1] = bt[i] + base end
				end
			end
			if #t >= 3 then hull = { v = v, t = t, mn = mn, mx = mx, tris = #t / 3 } end
		end
	end
	N.hullCache[key] = hull
	return hull or nil
end

-- Shapes of the moving brushes (lifts, shutters, trains), per map and brush model: { v, t, mn, mx, tris,
-- thick, brushes } in the entity's frame; false = no brush that stops sound (only clips, grates, water);
-- nil = the BSP could not be read (the caller keeps the box). A mover entered the scene as its bounding box,
-- a sealed box: ep2_outland_11's lift_2 (playerclip brushes around a prop cabin) shut the player and the lift's
-- own sound in a 2.3 x 2.4 x 3.8 m box whose reverb jumped from sample to sample as the cabin went down the
-- shaft. Its solid brushes are what players and traces collide with, and what sound reflects from; a brush
-- of clip, grate or water contents stops neither sound nor traces, and is left out.
N.moverCache = N.moverCache or {}
local MOVER_TRIS_MAX = 4096 -- above: one box per brush (12 triangles each), still the brushes' own volumes
function N.MoverHull(model)
	if not model or model:sub(1, 1) ~= "*" or not A.BSP or not A.BSP.ModelBrushes then return nil end
	local index = tonumber(model:sub(2))
	if not index then return nil end
	local key = game.GetMap() .. model
	local c = N.moverCache[key]
	if c == "box" then return nil end
	if c ~= nil then return c or nil, c == false end
	local brushes = A.BSP.ModelBrushes(game.GetMap(), index)
	if not brushes then -- unreadable: the caller keeps the box
		N.moverCache[key] = "box"
		return nil
	end
	local polys, n = {}, 0
	for _, b in ipairs(brushes) do
		local ps = A.BSP.BrushPolygons(b.planes)
		if #ps >= 4 then
			polys[#polys + 1] = ps
			for _, p in ipairs(ps) do n = n + #p - 2 end
		end
	end
	if #polys == 0 then
		N.moverCache[key] = false
		return nil, true
	end
	local v, t, thick = {}, {}, {}
	local mn = Vector(math.huge, math.huge, math.huge)
	local mx = -mn
	for _, ps in ipairs(polys) do
		local a = Vector(math.huge, math.huge, math.huge)
		local b = -a
		for _, p in ipairs(ps) do
			for _, q in ipairs(p) do
				a.x, a.y, a.z = math.min(a.x, q.x), math.min(a.y, q.y), math.min(a.z, q.z)
				b.x, b.y, b.z = math.max(b.x, q.x), math.max(b.y, q.y), math.max(b.z, q.z)
			end
		end
		mn.x, mn.y, mn.z = math.min(mn.x, a.x), math.min(mn.y, a.y), math.min(mn.z, a.z)
		mx.x, mx.y, mx.z = math.max(mx.x, b.x), math.max(mx.y, b.y), math.max(mx.z, b.z)
		local sz = b - a
		thick[#thick + 1] = math.max(math.min(sz.x, sz.y, sz.z), 1)
		if n <= MOVER_TRIS_MAX then
			for _, p in ipairs(ps) do
				local base = #v / 3
				for _, q in ipairs(p) do v[#v + 1], v[#v + 2], v[#v + 3] = q.x, q.y, q.z end
				for k = 2, #p - 1 do t[#t + 1], t[#t + 2], t[#t + 3] = base, base + k - 1, base + k end
			end
		else
			local bv, bt = boxMesh(a, b)
			local base = #v / 3
			for i = 1, #bv do v[#v + 1] = bv[i] end
			for i = 1, #bt do t[#t + 1] = bt[i] + base end
		end
	end
	-- the thickness sound crosses (saMaterial): the median brush's smallest dimension (a 2 u wall panel, not
	-- the whole cabin's 120 u; one thin rail does not make a solid train a sheet)
	table.sort(thick)
	local hull = { v = v, t = t, mn = mn, mx = mx, tris = #t / 3, brushes = #polys, thick = thick[math.ceil(#thick / 2)] }
	N.moverCache[key] = hull
	return hull
end

--- N.MoverHull without the wait: hull, empty as it gives them once known; nil, nil, true while it is computed. A
-- mover first seen after the world build (one spawned or networked later) is queued and computed in the background
-- (pba_native_movers Think, 2 ms per frame): reading and clipping a big one costs ~60 ms (ep2_outland_11b's strider
-- sled, 83 brushes), a hitch if done in the door sync. It enters the scene once ready.
N.moverQueue = N.moverQueue or {}
function N.MoverHullAsync(model)
	local c = model and N.moverCache[game.GetMap() .. model]
	if c ~= nil or not model or model:sub(1, 1) ~= "*" then return N.MoverHull(model) end
	N.moverQueue[model] = true
	return nil, nil, true
end

hook.Add("Think", "pba_native_movers", function()
	if not N.moverCo then
		local m = next(N.moverQueue)
		if not m then return end
		N.moverQueue[m] = nil
		N.moverCo = coroutine.create(function() N.MoverHull(m) end)
	end
	local deadline = SysTime() + 0.002
	local function yield() if SysTime() > deadline then coroutine.yield() end end
	local prevN, prevB = N.Yield, A.BSP.Yield
	N.Yield, A.BSP.Yield = yield, yield
	local ok, err = coroutine.resume(N.moverCo)
	N.Yield, A.BSP.Yield = prevN, prevB
	if not ok then MsgN("[PBA] mover shape failed: ", tostring(err)) end
	if not ok or coroutine.status(N.moverCo) == "dead" then N.moverCo = nil end
end)

--- Surfaceprop of a moving brush (lift, shutter, func_physbox): brush models ("*N") have no model info and
-- usually no client physics object, so the face on top is traced (only this entity) for the surfaceprop of
-- its texture. Unknown ("default" or nothing hit): metal, what lifts and shutters usually are (the former
-- choice for every mover: a wooden func_physbox crate rang like a steel plate).
local function moverSurface(e, info)
	local s = N.SurfaceOf(e)
	if s and s ~= "default" then return s end
	local c = e:WorldSpaceCenter()
	local tr = util.TraceLine({ start = c + Vector(0, 0, (info.mx - info.mn):Length() * 0.5 + 8), endpos = c,
		filter = function(x) return x == e end, ignoreworld = true })
	if tr.Hit and tr.Entity == e and tr.SurfaceProps and tr.SurfaceProps >= 0 then
		local name = util.GetSurfacePropName(tr.SurfaceProps)
		if name and name ~= "" and name ~= "default" then return name end
	end
	return "metal"
end

--- Acoustic relevance of a prop to the listener: its cross-section over the squared distance (the solid
-- angle it fills, what its reflections and its shadow scale with). The distance is floored at 128 u so
-- the prop under the player's feet does not outrank everything around by orders of magnitude.
local function propScore(e, info, L)
	if not L then return info.area end
	local d = math.max(e:WorldSpaceCenter():Distance(L), 128)
	return info.area / (d * d)
end

local function addProp(e, id, info)
	-- material from the physics surface: pba's wall table at the object's smallest dimension
	-- (hollow objects behave like thin walls)
	local m = saMaterial(N.SurfaceOf(e), A.cfg, e:GetModel(), info.thick)
	local v, t
	if info.hull then v, t = info.hull.v, info.hull.t else v, t = boxMesh(info.mn, info.mx) end
	pba_native.DynamicAdd(id, v, t, m)
	local d = { prop = true, ent = e }
	N.doors[id] = d
	return d
end

local function removeDyn(id)
	pba_native.DynamicRemove(id)
	N.doors[id] = nil
end

--- True while the module has work to do: pba on, or voices of its own still playing out after pba was switched
-- off (they keep their listener until they end). pba off and silent: no listener, no door sync, no settings
-- pushed (the perf bench measured up to 25 ms per frame of door / prop sync with pba_enable 0).
function N.Busy()
	return A.Enabled() or (N.live or 0) > 0
end

function N.SyncDoors()
	if not N.ready or not pba_native.DynamicAdd or (A.cfg.native_doors or 0) < 0.5 then return end
	if not A.Enabled() then return end -- caught up when pba is switched on again (the sync diffs the scene)
	local seen, nProps = {}, 0
	local wantProps = (A.cfg.native_props or 0) >= 0.5
	local cap = A.cfg.native_props_max or 64
	local now = RealTime()
	-- pba_native_props_calm: every change of the props (add, move, remove) is held during a fight and for
	-- PROP_COMMIT_S after the last commit made for them. A commit rebuilds the whole world scene (about 18 ms
	-- on d1_canals_01, measured), and an explosion's flying barrels and debris asked for one every 0.1 s.
	-- The props are sent where they came to rest, once the fight is over. Doors are never held.
	local hold = wantProps and (A.cfg.native_props_calm or 1) >= 0.5
		and (now < (N.propCommitT or 0) or (A.Sched and A.Sched.InCombat and A.Sched.InCombat()))
	local propSent = false
	-- pba_native_props_add_ms: the props entering the scene this sync stop once their DynamicAdd calls took that
	-- long (the first always enters); the others enter at the next syncs, which the calm hold then does not wait for
	local addMs = A.cfg.native_props_add_ms or 3
	local addSpent, addCut = 0, false
	-- pba_native_props_rank_keep: once a ranking found more props than the cap, the props entering before the next one are
	-- its winners only (the fill below put in whichever came first in ents.GetAll(), losers included, which the next
	-- ranking took out again: props in and out every 2 s with nothing moving, a DynamicAdd and a commit each time)
	if not wantProps then N.propWinners = nil end
	local winners = (A.cfg.native_props_rank_keep or 1) >= 0.5 and N.propWinners or nil
	local rerank = wantProps and not hold and now >= (N.propRankT or 0)
	if rerank then N.propRankT = now + PROP_RANK_S end
	local cands = rerank and {} or nil
	-- a door, mover or large prop that moved near the listener changes paths and occlusion: the
	-- continuous sounds re-evaluate (reeval_adaptive; P.ReevalDue watches the world version)
	local L, moved = A.ListenerPos(), false
	local function near(p) return L and p and p:DistToSqr(L) < MOVED_NEAR2 end
	local farM = A.cfg.native_scene_far_m or 20
	local farR2 = farM > 0 and L and (farM * UNITS_PER_M) ^ 2 or nil
	local function track(e, id, d)
		local p, a = e:GetPos(), e:GetAngles()
		local movingNow = d.sp and (d.sp ~= p or d.sa ~= a)
		-- sustained spin in place (see pba_native_spin_s): counted over the syncs, whatever was sent
		if d.sp and (d.sp ~= p or d.sa ~= a) then
			local c = e:WorldSpaceCenter()
			if (d.run or 0) == 0 or c:DistToSqr(d.c0) > AMBIENT_RADIUS2 then d.run, d.c0 = 1, c else d.run = d.run + 1 end
		else
			d.run = 0
		end
		d.sp, d.sa = p, a
		local spinS = A.cfg.native_spin_s or 3
		if spinS > 0 and d.run >= spinS * 10 then
			if d.tSent and now - d.tSent < AMBIENT_PERIOD then return end
			if d.prop and hold then return end
			d.tSent = now
			pba_native.DynamicMove(id, e:GetWorldTransformMatrix():ToTable())
			d.p, d.a = p, a
			return
		end
		if not d.p or d.p ~= p or d.a ~= a then
			if farR2 and d.p and p:DistToSqr(L) > farR2 then
				-- far from the listener: sent once it rests (or after FAR_MAX_S of motion), not at every sync
				if movingNow or not d.farLast then d.farLast = now end
				d.farT0 = d.farT0 or now
				if now - d.farLast < FAR_REST_S and now - d.farT0 < FAR_MAX_S then return end
			end
			d.farT0, d.farLast = nil, nil
			if d.prop then
				if hold then return end -- sent once the fight is over, where it came to rest
				propSent = true
			end
			pba_native.DynamicMove(id, e:GetWorldTransformMatrix():ToTable())
			if d.p and near(p) then moved = true end
			d.p, d.a = p, a
		end
	end
	for id in pairs(N.doors) do if N.doors[id].prop then nProps = nProps + 1 end end
	local skip = N.dynSkip
	for _, e in ipairs(ents.GetAll()) do
		-- (an entity that is neither a door, a mover nor a prop class stays one: seen once, then skipped. Every
		-- entity of the map went through GetClass and the brush test at each sync: 1.5 ms of 764 entities, ten times a second)
		local cls = skip[e] ~= true and e:GetClass() or nil
		local bk = cls and brushKind(e, cls)
		local isMover = cls and (MOVER_CLASSES[cls] or bk == "mover")
		local isDoor, isProp = cls and (DOOR_CLASSES[cls] or bk == "door" or isMover), cls and wantProps and PROP_CLASSES[cls]
		if cls and not isDoor and not PROP_CLASSES[cls] then skip[e] = true end
		local id = cls and e:EntIndex()
		if (isDoor or isProp) and id > 0 and not N.dynSkip[e] and not (hold and not isDoor and N.doors[id]
			and N.doors[id].ent ~= e) then -- held: an index reused by a new prop waits for the end of the hold
			local d = N.doors[id]
			if d and d.ent ~= e then -- entity index reused by another entity: rebuild
				if d.prop then nProps = nProps - 1 end
				removeDyn(id)
				d = nil
			end
			local info = N.propInfo[e]
			if not info then
				-- a prop takes the shape of its collision model (pba_native_props_hull), a mover its solid brushes
				-- (pba_native_movers_brushes), a door its box (a closed door is a slab: the box is its shape)
				local hull, empty, pending
				if isMover and (A.cfg.native_movers_brushes or 1) >= 0.5 then
					hull, empty, pending = N.MoverHullAsync(e:GetModel())
				elseif not isDoor and (A.cfg.native_props_hull or 1) >= 0.5 then
					hull, empty = N.PropHull(e:GetModel(), e:GetModelScale())
				end
				info = boxInfo(e, hull)
				if hull and hull.thick then info.thick = hull.thick end
				-- a mover of clip, grate or water brushes only, a prop with no collision model: nothing sound
				-- reflects from, out of the scene
				info.empty = empty
				-- (a shape still being computed: not remembered, asked again at the next sync)
				if not pending then N.propInfo[e] = info end
				info.pending = pending
			end
			if info.pending then
				if d then seen[id] = true end -- (not in the scene yet)
			elseif info.empty then
				N.dynSkip[e] = true
			elseif isDoor then
				seen[id] = true
				if not d and info.big > 8 then
					local v, t
					if info.hull then v, t = info.hull.v, info.hull.t else v, t = boxMesh(info.mn, info.mx) end
					if isMover then
						-- lifts, bridges, shutters: their texture's surfaceprop, at the box's thickness
						pba_native.DynamicAdd(id, v, t, saMaterial(moverSurface(e, info), A.cfg, nil, info.thick))
					else
						local tm = 10 ^ (-A.cfg.door_closed_db / 20)
						pba_native.DynamicAdd(id, v, t, { absorption = { 0.11, 0.07, 0.06 }, scattering = 0.05,
							transmission = { math.min(tm * 10 ^ (A.cfg.trans_lf_bonus / 20), 1), tm, tm * 0.3 } })
					end
					d = { ent = e }
					N.doors[id] = d
				elseif not d then
					N.dynSkip[e] = true -- a sliver: not looked at again
				end
			elseif info.big < PROP_MIN_SIZE then
				N.dynSkip[e] = true -- too small to matter: not looked at again
			else
				if d then
					seen[id] = true
				elseif nProps < cap and not hold and not (winners and not winners[id]) then
					if addMs > 0 and addSpent >= addMs then
						addCut = true -- (this sync's share is spent: at the next one)
					else
						-- room left under the cap: in at once (the next ranking may swap it out)
						local t0 = SysTime()
						d = addProp(e, id, info)
						addSpent = addSpent + (SysTime() - t0) * 1000
						nProps = nProps + 1
						seen[id] = true
						propSent = true
					end
				end
				if cands then cands[#cands + 1] = { e = e, id = id, info = info, s = propScore(e, info, L) * (d and PROP_KEEP or 1) } end
			end
			if d then track(e, id, d) end
		end
	end
	-- unseen (gone, no longer a candidate, props switched off): out of the scene
	for id, d in pairs(N.doors) do
		if (not seen[id] and not (hold and d.prop)) or (d.prop and not wantProps) then
			if d.prop and near(d.p) then moved = true end
			if d.prop then propSent = true end
			removeDyn(id)
		end
	end
	-- ranking: the `cap` most relevant props are in the scene, the others out (swapped). Outs first, so
	-- the scene never holds more than `cap` props.
	if cands and #cands <= cap then N.propWinners = nil end -- (every candidate fits: no ranking to keep)
	if cands and #cands > cap then
		table.sort(cands, function(a, b) return a.s > b.s end)
		N.propWinners = {}
		for i = 1, cap do N.propWinners[cands[i].id] = true end
		for i = cap + 1, #cands do
			local c = cands[i]
			local d = N.doors[c.id]
			if d and d.prop then
				if near(d.p) then moved = true end
				removeDyn(c.id)
				propSent = true
			end
		end
		for i = 1, cap do
			local c = cands[i]
			if not N.doors[c.id] then
				if addMs > 0 and addSpent >= addMs then
					addCut = true
				else
					local t0 = SysTime()
					local d = addProp(c.e, c.id, c.info)
					addSpent = addSpent + (SysTime() - t0) * 1000
					track(c.e, c.id, d)
					if near(d.p) then moved = true end
					propSent = true
				end
			end
		end
	end
	-- (props left for the next syncs: no calm hold before them, they come in at the next sync)
	if propSent and (A.cfg.native_props_calm or 1) >= 0.5 then N.propCommitT = addCut and now or now + PROP_COMMIT_S end
	-- the module only commits when something changed (and retries itself after a running bake)
	pba_native.DynamicCommit()
	if moved and A.Paths then A.Paths.InvalidateCache() end
end
timer.Create("pba_native_doors", 0.1, 0, function() N.SyncDoors() end)

--- Master volume of the module's output: volume x volume_sfx, what the engine applies to every sound it plays
-- but voice chat (its channel mixing) and what GMod gives BASS's global stream volume, so other addons'
-- streams too (gmod_audio SetGlobalVolume, measured). pba_native_volume_sfx 0: volume alone.
local cvVolume, cvVolumeSfx = GetConVar("volume"), GetConVar("volume_sfx")
function N.MasterVolume()
	local m = cvVolume:GetFloat()
	if (A.cfg.native_volume_sfx or 1) >= 0.5 and cvVolumeSfx then m = m * cvVolumeSfx:GetFloat() end
	return m
end

--- Single player menu: the game is paused, the engine pauses the sounds it emitted with SND_SHOULDPAUSE and keeps
-- the others playing; the module's voices played with the pausable flag freeze the same way. Think does not run
-- during that pause (nor does a timer), a render hook does: this runs from PreRender.
function N.UpdatePause()
	if not N.render or not pba_native or not pba_native.SetPaused then return end
	local paused = (A.cfg.native_pause or 1) >= 0.5 and N.PauseSupported() and game.SinglePlayer() and gui.IsGameUIVisible() or false
	if paused ~= (N.paused or false) then
		N.paused = paused
		pba_native.SetPaused(paused)
	end
end
hook.Add("PreRender", "pba_native_pause", function() N.UpdatePause() end)

hook.Add("Think", "pba_native_listener", function()
	if not N.render or not N.Busy() then return end
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	local ang = ply:EyeAngles()
	local master = N.MasterVolume()
	if not system.HasFocus() and GetConVar("snd_mute_losefocus"):GetBool() then master = 0 end
	local eL, eR
	local L, vang = A.ListenerPos()
	if not L then return end
	ang = vang or ang
	N.live, eL, eR = pba_native.SetListener(L, ang:Forward(), ang:Up(), master)
	-- what follows its entity every frame (clear voices, native mirrors): the scheduler's frame pass
	if A.Sched then A.Sched.Frame(L) else N.UpdateFollowers(L) end
	-- head under water: the engine applies its own water DSP to the sounds it plays; same for ours
	local uw = A.cfg.water >= 0.5 and A.InWater(L)
	if uw ~= N.underwater and pba_native.SetUnderwater then
		N.underwater = uw
		pba_native.SetUnderwater(uw and 1 or 0)
	end
	-- the engine swaps its room DSP for dsp_water while the head is under water: the module's room reverb and
	-- echoes, simulated in the air, fade out (~0.15 s) and come back on surfacing (native_water_reverb)
	local wetTo = (uw and (A.cfg.native_water_reverb or 1) >= 0.5) and 0 or 1
	local k = N.wetScale or 1
	if k ~= wetTo then
		local step = FrameTime() / 0.15
		k = wetTo < k and math.max(wetTo, k - step) or math.min(wetTo, k + step)
		N.wetScale = k
		N.ApplySettings()
	end
	N.energyL, N.energyR = (N.energyL or 0) + (eL or 0), (N.energyR or 0) + (eR or 0)
end)

-- the ray count fixes the simulator's ray directions: a new count rebuilds the scene (seconds);
-- so do the options read when the simulator is created
for _, cv in ipairs({ "rays", "scene", "threads", "reverb_window", "scattering", "water" }) do
	cvars.AddChangeCallback("pba_native_" .. cv, function()
		-- also while the demo map holds the module aside (modes A / B): the scene must be current when it comes back
		if (N.ready or N.pba_demoHeld) and not N.building then N.Start() end
	end, "pba_native_" .. cv .. "_rebuild")
end

--- Room reverb time baked at the probe positions (pba_native_baked_reverb): once the probe graph
-- exists, on the same points as the paths (worker thread in the module).
function N.WantReverbBake()
	timer.Remove("pba_native_revbake")
	if (A.cfg.native_baked_reverb or 0) < 0.5 or not pba_native.BakeReverb or (A.cfg.native_reverb_window or 0) <= 0.5 then return end
	timer.Create("pba_native_revbake", 1, 120, function()
		local pr = A.Probes and A.Probes.current
		if not (pr and N.ready) then return end
		timer.Remove("pba_native_revbake")
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
		local ok, err = pcall(pba_native.BakeReverb, pts, pr.spacing * (step - 1) * 0.75)
		if not ok then MsgN("[PBA] reverb bake: ", err) return end
		N.revBake = "baking"
		timer.Create("pba_native_revbakepoll", 0.5, 0, function()
			if not pba_native then timer.Remove("pba_native_revbakepoll") return end
			local st, info = pba_native.ReverbBakeStatus()
			if st == "baking" then return end
			timer.Remove("pba_native_revbakepoll")
			N.revBake = st
			MsgN(string.format("[PBA] reverb bake: %s, %d probes, %.1f s %s", st, #pts, SysTime() - t0, info or ""))
		end)
	end)
end
-- turned on: bake now; off: the baked data goes with a rebuild
cvars.AddChangeCallback("pba_native_baked_reverb", function(_, _, new)
	if not (N.ready or N.pba_demoHeld) or N.building then return end
	if tonumber(new) == 1 then N.WantReverbBake() else N.Start() end
end, "pba_native_baked_reverb")

cvars.AddChangeCallback("pba_native_render", function(_, _, new)
	if tonumber(new) == 1 then N.StartRender() else N.StopRender() end
end, "pba_native")

-- paths switched on during the game: bake (or load the cache) now; off: back to the probe graph
cvars.AddChangeCallback("pba_native_paths", function(_, _, new)
	if tonumber(new) == 1 then
		if N.ready and not N.pathsReady and A.Probes and A.Probes.current then N.Bake() end
	else
		N.pathsReady = false
	end
	if A.Paths then A.Paths.InvalidateCache() end
end, "pba_native")

cvars.AddChangeCallback("pba_native", function(_, _, new)
	if tonumber(new) == 1 then
		N.Start()
	else
		N.StopRender()
		N.building = nil
		N.ready, N.pathsReady = false, false
	end
	if A.Paths then A.Paths.InvalidateCache() end
end, "pba_native")

hook.Add("ShutDown", "pba_native", function() N.StopRender() end)

-- reflections run on the module's own thread; keep its settings and the server flag in sync
timer.Create("pba_native_reverb", 0.5, 0, function()
	-- the server may forbid the native backend at any time (replicated, polled)
	if (A.cfg.allow_native or 1) < 0.5 and (N.ready or N.building) then
		N.StopRender()
		N.building, N.ready, N.pathsReady = nil, false, false
		N.err = "disabled by the server (pba_allow_native 0)"
		if A.Paths then A.Paths.InvalidateCache() end
	elseif (A.cfg.allow_native or 1) >= 0.5 and not N.ready and not N.building
		and N.err == "disabled by the server (pba_allow_native 0)" then
		N.Start()
	end
	local want = N.render and (A.cfg.native_echo or 0) > 0 and A.Enabled() or false
	if N.echoCvar and N.echoCvar:GetBool() ~= want then RunConsoleCommand("pba_echo_want", want and "1" or "0") end
	local all = N.render and (A.cfg.native_all or 0) >= 0.5 and A.Enabled() or false
	if N.allCvar and N.allCvar:GetBool() ~= all then RunConsoleCommand("pba_native_all_want", all and "1" or "0") end
	local own = all and (A.cfg.native_own or 1) >= 0.5
	if N.ownCvar and N.ownCvar:GetBool() ~= own then RunConsoleCommand("pba_native_own_want", own and "1" or "0") end
	if not N.Busy() then return end -- pba off and silent: nothing to keep in sync (pushed again once on)
	-- limits apply whatever renders (decoding also serves echoes)
	if N.ready and pba_native and pba_native.SetLimits then pba_native.SetLimits(A.cfg.native_max_voices or 64, A.cfg.native_mem_mb or 512) end
	if not N.render or not pba_native or not pba_native.RoomReverb then return end
	N.ApplySettings()
	local ok, l, m, h = pcall(pba_native.RoomReverb)
	if ok then N.rt = { l, m, h } end
end)

A.OnInitPostEntity("pba_native", function() timer.Simple(1, N.Start) end)
if A.nativeLoaded then timer.Simple(0.5, N.Start) end
A.nativeLoaded = true
