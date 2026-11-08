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
local N = A.Native or {}
A.Native = N

local MODULE = "lua/bin/gmcl_pba_" .. (jit.arch == "x64" and "win64" or "win32") .. ".dll"
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

--- Steam Audio material for a surfaceprop: transmission derived from pba's own wall
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
		if N.Yield then N.Yield() end
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
	if (A.cfg.allow_native or 1) < 0.5 then N.err = "disabled by the server (pba_allow_native 0)" return end
	if not file.Exists(MODULE, "GAME") then N.err = "module not installed" return end
	if not pba_native then
		local ok, err = pcall(require, "pba")
		if not ok or not pba_native then N.err = "require failed: " .. tostring(err) return end
	end
	local ok, err = pba_native.Init()
	if not ok then N.err = err return end
	-- the world is gathered in a coroutine, 4 ms per frame (large maps: seconds of Lua work),
	-- then handed to the module in one call
	N.building = coroutine.create(function()
		local t0 = SysTime()
		local verts, tris, matIdx, mats, mins, maxs = N.BuildWorld()
		N.buildMs = (SysTime() - t0) * 1000
		return verts, tris, matIdx, mats, mins, maxs
	end)
	N.buildStart = SysTime()
end

hook.Add("Think", "pba_native_build", function()
	local co = N.building
	if not co then return end
	local deadline = SysTime() + 0.004
	local function yield() if SysTime() > deadline then coroutine.yield() end end
	N.Yield, A.BSP.Yield = yield, yield
	local ok, verts, tris, matIdx, mats, mins, maxs = coroutine.resume(co)
	N.Yield, A.BSP.Yield = nil, nil
	if not ok then
		N.building, N.err = nil, "world build failed: " .. tostring(verts)
		MsgN("[PBA] native backend: ", N.err)
		return
	end
	if coroutine.status(co) ~= "dead" then return end
	N.building = nil
	N.Finish(verts, tris, matIdx, mats, mins, maxs)
end)

function N.Finish(verts, tris, matIdx, mats, mins, maxs)
	local t0 = SysTime()
	local nt = pba_native.LoadWorld(verts, tris, matIdx, mats)
	N.doors = {} -- the module released its dynamic objects with the old world
	N.loadMs = (SysTime() - t0) * 1000
	N.tris, N.mins, N.maxs = nt, mins, maxs
	N.ready = nt > 0
	MsgN(string.format("[PBA] native backend: Steam Audio %d, %d triangles, %d materials, gathered in %.0f ms over %.1f s, loaded in %.0f ms",
		pba_native.Version(), nt, #mats, N.buildMs or 0, SysTime() - (N.buildStart or SysTime()), N.loadMs))
	if N.ready then N.StartRender() end
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

-- 3-band EQ (low / mid / high gain) per low-pass level: same intent as DSP presets 30/31
N.EQ = { [0] = { 1, 1, 1 }, { 1, 0.7, 0.4 }, { 1, 0.5, 0.2 }, { 0.9, 0.3, 0.08 }, { 0.8, 0.18, 0.03 } }
N.failed = N.failed or {}

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
	N.ApplySettings()
	local st = pba_native.Stats and pba_native.Stats()
	MsgN("[PBA] native rendering on (Steam Audio, HRTF: ", st and st.hrtf or "default", ")")
end

--- Pushes the client options to the module (output mode, reflection levels and quality).
function N.ApplySettings()
	if not N.render or not pba_native.SetReflections then return end
	pba_native.SetOutputMode(A.cfg.native_out >= 0.5 and 1 or 0)
	pba_native.SetReflections(A.cfg.native_reverb, A.cfg.native_echo, A.cfg.native_rays)
end

N.hrtfCvar = N.hrtfCvar or CreateClientConVar("pba_native_hrtf", "", true, false,
	"SOFA HRTF file in data/pba/hrtf/ for native rendering (empty = Steam Audio default). Restart native rendering to apply.")
-- tells the server that this client renders echoes (loud server sounds are then relayed to it)
N.echoCvar = N.echoCvar or CreateClientConVar("pba_echo_want", "0", false, true, "Internal: native echoes active.")
N.allCvar = N.allCvar or CreateClientConVar("pba_native_all_want", "0", false, true, "Internal: every sound rendered natively.")

function N.StopRender()
	if N.render and pba_native then pba_native.AudioStop() end
	N.render = false
end

local function cleanName(name)
	return string.lower(string.gsub(name or "", "^[%^%)%*#@<>!%?%$&~`+%%%(]+", ""))
end

--- Makes sure the module has decoded `name`. Returns true, cleanName when playable natively;
-- false, nil, "pending" while a large file decodes on the module's worker thread.
function N.EnsureSound(name)
	local n = cleanName(name)
	if N.failed[n] then return false end
	if pba_native.HasSound(n) then return true, n end
	if pba_native.SoundPending and pba_native.SoundPending(n) then return false, nil, "pending" end
	if N.loading and N.loading[n] then
		-- the worker finished without a sound: undecodable
		N.loading[n] = nil
		N.failed[n] = true
		return false
	end
	local data = file.Read("sound/" .. n, "GAME")
	if not data or #data > 48 * 1024 * 1024 then N.failed[n] = true return false end
	if #data > 512 * 1024 and pba_native.LoadSoundAsync then
		pba_native.LoadSoundAsync(n, data)
		N.loading = N.loading or {}
		N.loading[n] = true
		return false, nil, "pending"
	end
	local secs = pba_native.LoadSound(n, data)
	if not secs then N.failed[n] = true return false end
	return true, n
end

-- Steam Audio's default air absorption model (per metre, low / mid / high)
local AIR = { 0.0002, 0.0017, 0.0182 }
local UNIT_M = 0.01905

--- EQ of a voice: low-pass level, times air absorption over `len` units of path.
function N.VoiceEQ(lp, len)
	local e = N.EQ[math.Clamp(lp or 0, 0, 4)]
	if (A.cfg.native_air or 0) < 0.5 or not len then return e[1], e[2], e[3] end
	local m = len * UNIT_M
	return e[1] * math.exp(-AIR[1] * m), e[2] * math.exp(-AIR[2] * m), e[3] * math.exp(-AIR[3] * m)
end

--- Dipole directivity of a weapon-like source towards L (1 in front, 1 - 2w behind).
function N.Directivity(ent, L)
	local w = A.cfg.native_dir or 0
	if w <= 0 or not IsValid(ent) then return 1 end
	local owner = ent
	if ent:IsWeapon() and IsValid(ent:GetOwner()) then owner = ent:GetOwner() end
	if not (owner:IsPlayer() or owner:IsNPC()) then return 1 end
	local fwd = owner:IsPlayer() and owner:GetAimVector() or owner:GetForward()
	local d = (L - owner:EyePos()):GetNormalized()
	return math.max((1 - w) + w * fwd:Dot(d), 0.05)
end

--- Plays a voice natively. gain: linear, everything included. opt: { len = path length (units),
-- sh = baked path field {w, sh1, sh2, sh3}, eq = {l, m, h} override, delay = seconds }.
-- Returns true on success.
function N.PlayVoice(name, pos, gain, lp, pitch, opt)
	if not N.render then return false end
	local ok, n = N.EnsureSound(name)
	if not ok then return false end
	opt = opt or {}
	local l, m, h = N.VoiceEQ(lp, opt.len)
	if opt.eq then l, m, h = l * opt.eq[1], m * opt.eq[2], h * opt.eq[3] end
	local sh = (A.cfg.native_path_fx or 0) >= 0.5 and opt.sh or nil
	local id = pba_native.Play(n, pos, gain * A.cfg.native_gain, l, m, h, pitch or 100, false, opt.delay or 0, sh)
	if id and id > 0 and opt.follow and IsValid(opt.follow.ent) then
		-- direct voice of a moving entity: follows it every frame like the engine does
		opt.follow.pitch = pitch or 100
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
function N.UpdateFollowers(L)
	local vL = N.ListenerVelocity()
	for id, f in pairs(N.follow) do
		local e = f.ent
		if not IsValid(e) then
			-- the entity is gone: the engine would stop its sound, so do we
			pba_native.StopVoice(id)
			N.follow[id] = nil
		else
			local S = A.SoundPos({ Entity = e })
			local d = S:Distance(L)
			local g = f.vol * A.AC.EngineGain(math.max(d, 1), f.lvl) * N.Directivity(e, L) * A.cfg.native_gain
			local l, m, h = N.VoiceEQ(0, d)
			local pitch = f.pitch * N.Doppler(S, velocityOf(e), L, vL)
			if not pba_native.Update(id, S, g, l, m, h, pitch) then N.follow[id] = nil end
		end
	end
end

--- Echoes of a loud sound (reflections only, on top of whatever plays the direct sound).
N.echoSkip = N.echoSkip or {}
local function skip(why) N.echoSkip[why] = (N.echoSkip[why] or 0) + 1 end

function N.Echo(data, pos)
	if not N.render or (A.cfg.native_echo or 0) <= 0 or not pba_native.Echo then return skip("off") end
	local lvl = data.SoundLevel or 75
	if lvl < A.cfg.native_echo_lvl then return skip("level") end
	local ok, n = N.EnsureSound(data.SoundName)
	if not ok then return skip("sound") end
	-- source strength = what the engine would play at 1 m (52.5 units); the impulse response
	-- carries the distance and the room
	local gain = (data.Volume or 1) * A.AC.EngineGain(52.5, lvl)
	local e = data.Entity
	local key = IsValid(e) and e:EntIndex() or (data.EntIndex or 0)
	pba_native.Echo(n, pos, gain * A.cfg.native_gain, key, data.Pitch or 100, 0)
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

local PROP_CLASSES = { prop_physics = true, prop_physics_multiplayer = true, prop_dynamic = true, prop_vehicle_jeep = true,
	prop_vehicle_airboat = true, prop_vehicle_prisoner_pod = false }
local PROP_MIN_SIZE, PROP_MAX = 64, 64 -- units (largest box dimension), objects
N.doors = N.doors or {}
N.dynSkip = N.dynSkip or setmetatable({}, { __mode = "k" }) -- entities not to look at again

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

function N.SyncDoors()
	if not N.ready or not pba_native.DynamicAdd or (A.cfg.native_doors or 0) < 0.5 then return end
	local seen, nProps = {}, 0
	local wantProps = (A.cfg.native_props or 0) >= 0.5
	for id in pairs(N.doors) do if N.doors[id].prop then nProps = nProps + 1 end end
	for _, e in ipairs(ents.GetAll()) do
		local cls = e:GetClass()
		local bk = brushKind(e, cls)
		local isMover = MOVER_CLASSES[cls] or bk == "mover"
		local isDoor, isProp = DOOR_CLASSES[cls] or bk == "door" or isMover, wantProps and PROP_CLASSES[cls]
		local id = e:EntIndex()
		if (isDoor or isProp) and id > 0 and not N.dynSkip[e] then
			seen[id] = true
			local d = N.doors[id]
			if d and d.ent ~= e then -- entity index reused by another entity: rebuild
				pba_native.DynamicRemove(id)
				N.doors[id], d = nil, nil
			end
			if not d then
				local mn, mx = e:OBBMins(), e:OBBMaxs()
				local sz = mx - mn
				local big = math.max(sz.x, sz.y, sz.z)
				if isDoor and big > 8 then
					local v, t = boxMesh(mn, mx)
					if isMover then
						-- lifts, bridges, shutters: usually metal or concrete
						pba_native.DynamicAdd(id, v, t, saMaterial("metal", A.cfg))
					else
						local tm = 10 ^ (-A.cfg.door_closed_db / 20)
						pba_native.DynamicAdd(id, v, t, { absorption = { 0.11, 0.07, 0.06 }, scattering = 0.05,
							transmission = { math.min(tm * 10 ^ (A.cfg.trans_lf_bonus / 20), 1), tm, tm * 0.3 } })
					end
					d = { ent = e }
					N.doors[id] = d
				elseif isProp and big >= PROP_MIN_SIZE and nProps < PROP_MAX then
					-- material from the physics surface: pba's wall table at the object's
					-- smallest dimension (hollow objects behave like thin walls)
					local phys = e:GetPhysicsObject()
					local surf = IsValid(phys) and phys:GetMaterial() or "default"
					local m = saMaterial(surf, A.cfg)
					local v, t = boxMesh(mn, mx)
					pba_native.DynamicAdd(id, v, t, m)
					d = { prop = true, ent = e }
					N.doors[id] = d
					nProps = nProps + 1
				else
					N.dynSkip[e] = true -- too small (or over the cap): not looked at again
				end
			end
			if d then
				local p, a = e:GetPos(), e:GetAngles()
				if not d.p or d.p ~= p or d.a ~= a then
					pba_native.DynamicMove(id, e:GetWorldTransformMatrix():ToTable())
					d.p, d.a = p, a
				end
			end
		end
	end
	for id, d in pairs(N.doors) do
		if not seen[id] or (d.prop and not wantProps) then
			pba_native.DynamicRemove(id)
			N.doors[id] = nil
		end
	end
	-- the module only commits when something changed (and retries itself after a running bake)
	pba_native.DynamicCommit()
end
timer.Create("pba_native_doors", 0.1, 0, function() N.SyncDoors() end)

hook.Add("Think", "pba_native_listener", function()
	if not N.render then return end
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	local ang = ply:EyeAngles()
	local master = GetConVar("volume"):GetFloat()
	if not system.HasFocus() and GetConVar("snd_mute_losefocus"):GetBool() then master = 0 end
	local eL, eR
	local L, vang = A.ListenerPos()
	L = L or ply:EyePos()
	ang = vang or ang
	N.live, eL, eR = pba_native.SetListener(L, ang:Forward(), ang:Up(), master)
	N.UpdateFollowers(L)
	-- single player menu: the engine pauses its sounds; the module's voices freeze too
	local paused = game.SinglePlayer() and gui.IsGameUIVisible() or false
	if paused ~= N.paused and pba_native.SetPaused then
		N.paused = paused
		pba_native.SetPaused(paused)
	end
	-- head under water: the engine applies its own water DSP to the sounds it plays; same for ours
	local uw = A.cfg.water >= 0.5 and bit.band(util.PointContents(L), CONTENTS_WATER) ~= 0
	if uw ~= N.underwater and pba_native.SetUnderwater then
		N.underwater = uw
		pba_native.SetUnderwater(uw and 1 or 0)
	end
	if A.Loops and A.Loops.FollowNative then A.Loops.FollowNative(L) end
	N.energyL, N.energyR = (N.energyL or 0) + (eL or 0), (N.energyR or 0) + (eR or 0)
end)

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
	if not N.render or not pba_native or not pba_native.RoomReverb then return end
	N.ApplySettings()
	local ok, l, m, h = pcall(pba_native.RoomReverb)
	if ok then N.rt = { l, m, h } end
end)

hook.Add("InitPostEntity", "pba_native", function() timer.Simple(1, N.Start) end)
if A.nativeLoaded then timer.Simple(0.5, N.Start) end
A.nativeLoaded = true
