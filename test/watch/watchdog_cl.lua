-- pba anomaly watchdog, client side (test tool, loaded by file into a test instance: lua_exec_file or
-- include). Runs from hooks and timers, never from a lua_job loop, and records anomalies in the global
-- PBA_WATCH_CL (read at the end by test/watch/sweep.py). Each detector keeps a count and a few samples
-- (sound, entity, map, position, time) so a report says what to reproduce.
-- Detectors (client):
--   stuck_once      a pba mirror of a non-looping line alive longer than its file (+ margin): stuck or looping
--   overlap_channel two pba mirrors of different lines alive at once on one entity's voice channel
--   mirror_step     a mirror's gain jumps > STEP_DB between two samples with no ramp (audible step)
--   voice_step      a module voice's gain jumps > STEP_DB between two Update calls < 0.5 s apart
--   louder_vanilla  a module loop at the listener > LOUD_DB above the engine's own law for its level
--   voices_spike    the module plays more than VOICES_MAX voices
--   dead_npc_loop   a mirror of an NPC's loop alive more than DEAD_S (1 s) after the NPC died (health <= 0): the game
--                   switches a dying NPC's loops off at death (a shot manhack lingering with its engine on)
--   vehicle_silent  the player drives an engine vehicle (airboat, jeep) for more than SILENT_S with no mirror
--                   of any of its sounds (engine idle: always one while it runs; after a level transition the
--                   engine's C++ emitted nothing)
-- Mouth copies: pba drives a face's lip sync with a copy of the line at volume 0.001 on the face (cl_render
-- mouthCopy; the engine reads visemes from the voice channels it plays on an entity, Lua cannot read them:
-- GetFlexWeight stays 0 while a face talks, even in vanilla). They are recorded per entity for sweep.py to
-- match the server's speech events (mouth_missing).
local W = PBA_WATCH_CL or {}
PBA_WATCH_CL = W
W.anomalies = W.anomalies or {}
W.copies = W.copies or {}       -- entindex -> { CurTime() of each mouth copy }
W.voices = W.voices or {}       -- module voice id -> { n, g, t, steps }
W.seen = W.seen or {}           -- mirror key -> first seen CurTime()
W.mg = W.mg or {}               -- mirror key -> last gain
local STEP_DB, LOUD_DB, VOICES_MAX, ONCE_MARGIN = 3, 6, 96, 3
local JUMP_UNITS, JUMP_QUIET = 200, 1.5 -- a listener teleport (the sweeper's) changes paths for real: no step check right after
local SAMPLES = 6
local DEAD_S, SILENT_S = 1, 3
local ENGINE_VEHICLES = { prop_vehicle_airboat = true, prop_vehicle_jeep = true, prop_vehicle_jeep_old = true }
W.deadT = W.deadT or {}         -- mirror key -> CurTime() its NPC was first seen dead

local function db(x) return 20 * math.log10(math.max(x, 1e-9)) end
local function note(kind, key, sample)
	local a = W.anomalies[kind] or { count = 0, keys = {}, samples = {} }
	W.anomalies[kind] = a
	a.count = a.count + 1
	if not a.keys[key] then
		a.keys[key] = 0
		if #a.samples < SAMPLES then
			sample.map = game.GetMap()
			sample.t = math.Round(CurTime(), 2)
			sample.key = key
			a.samples[#a.samples + 1] = sample
		end
	end
	a.keys[key] = a.keys[key] + 1
end
W.note = note

local function bare(name) return (string.gsub(name or "", "^[%*%#%@%>%<%^%)%(%}%$%!%?%&%~%`%+%%]+", "")) end

-- module voices: gain steps between two updates (wrapped outermost, after cl_mix's own wrap)
if pba_native and not pba_native.pbaWatchWrapped then
	pba_native.pbaWatchWrapped = true
	local play, update = pba_native.Play, pba_native.Update
	pba_native.Play = function(n, pos, gain, ...)
		local id = play(n, pos, gain, ...)
		if id and id > 0 then W.voices[id] = { n = n, g = gain, t = RealTime(), steps = 0, pos = pos } end
		return id
	end
	pba_native.Update = function(id, pos, gain, ...)
		local v = W.voices[id]
		if v and gain then
			local now = RealTime()
			if v.g and v.g > 1e-3 and gain > 1e-3 and now - v.t < 0.5 and CurTime() - (W.jumpT or -99) > JUMP_QUIET then
				local d = db(gain) - db(v.g)
				if math.abs(d) > STEP_DB then
					v.steps = v.steps + 1
					note("voice_step", tostring(v.n), { sound = tostring(v.n), fromG = math.Round(v.g, 4), toG = math.Round(gain, 4),
						db = math.Round(d, 1), pos = pos and tostring(pos) or nil })
				end
			end
			v.g, v.t = gain, now
		end
		return update(id, pos, gain, ...)
	end
end

local function onSound(data)
	if data and data.Volume and data.Volume <= 0.002 and (data.Channel == CHAN_VOICE or data.Channel == CHAN_VOICE2) and IsValid(data.Entity) then
		local i = data.Entity:EntIndex()
		W.copies[i] = W.copies[i] or {}
		table.insert(W.copies[i], math.Round(CurTime(), 2))
	end
end
local function wrapHook()
	local t = hook.GetTable().EntityEmitSound
	local fn = t and t.pba
	if not fn then
		if not (t and t.pba_watch) then hook.Add("EntityEmitSound", "pba_watch", function(data) pcall(onSound, data) end) end
		return
	end
	if fn == W.wrapped then return end
	hook.Remove("EntityEmitSound", "pba_watch")
	W.orig = fn
	W.wrapped = function(data) pcall(onSound, data) return W.orig(data) end
	hook.Add("EntityEmitSound", "pba", W.wrapped)
end
wrapHook()

timer.Create("pba_watch_cl", 0.1, 0, function()
	if (W.tick or 0) % 10 == 0 then wrapHook() end
	local A = pba
	if not A then return end
	local now = CurTime()
	local L = A.ListenerPos and (A.ListenerPos()) or LocalPlayer():EyePos()
	if L and W.lastL and L:Distance(W.lastL) > JUMP_UNITS then W.jumpT = now end
	W.lastL = L
	local quiet = now - (W.jumpT or -99) <= JUMP_QUIET
	W.tick = (W.tick or 0) + 1
	if W.tick % 3 ~= 0 then return end
	-- mirrors (pba.Loops.mirrors: "idx:chan:name")
	local LP = A.Loops
	local alive, byChan = {}, {}
	for key, m in pairs(LP and LP.mirrors or {}) do
		alive[key] = true
		local first = W.seen[key]
		if not first then first = now W.seen[key] = now end
		local name = m.name or ""
		local dur = 0
		if m.once then
			dur = A.SoundDuration and A.SoundDuration(bare(name)) or 0
			dur = dur / math.max((m.pitch or 100) / 100, 0.1)
			if dur > 0 and now - first > dur + ONCE_MARGIN then
				note("stuck_once", key, { sound = name, age = math.Round(now - first, 1), dur = math.Round(dur, 2), g = m.g, pos = m.pos and tostring(m.pos) or nil })
			end
		end
		local idx, ch = string.match(key, "^(%d+):(%d+):")
		-- (only while each line is within its own file: a mirror lingering silent past its end is stuck_once's)
		if idx and (ch == "2" or m.once) and (not m.once or dur <= 0 or now - first < dur) then
			local k = idx .. ":" .. ch
			byChan[k] = byChan[k] or {}
			table.insert(byChan[k], name)
		end
		local g = m.g
		local last = W.mg[key]
		if g and last and not quiet and g > 1e-3 and last > 1e-3 and not m.ramp and math.abs(db(g) - db(last)) > STEP_DB then
			note("mirror_step", name, { sound = name, fromG = math.Round(last, 3), toG = math.Round(g, 3), pos = m.pos and tostring(m.pos) or nil })
		end
		W.mg[key] = g
		-- an NPC's loop playing on after its death
		local e = m.ent
		if IsValid(e) and e:IsNPC() and e:Health() <= 0 then
			W.deadT[key] = W.deadT[key] or now
			if now - W.deadT[key] > DEAD_S then
				note("dead_npc_loop", key, { sound = name, class = e:GetClass(), since = math.Round(now - W.deadT[key], 1) })
			end
		end
		-- census of loud sounds heard (report only: what the map played, for a human to compare with vanilla)
		if (m.lvl or 0) >= 100 and m.pos and L then
			W.census = W.census or {}
			local c = W.census[name] or { n = 0 }
			W.census[name] = c
			c.n = c.n + 1
			c.lvl = m.lvl
			local d = math.floor(m.pos:Distance(L))
			c.dmin = math.min(c.dmin or d, d)
			c.dmax = math.max(c.dmax or d, d)
			c.native = m.nativeId ~= nil
		end
		-- louder than the engine's law (module loops only)
		if m.nativeId and m.pos and m.lvl and A.Native and A.Native.Law and A.AC and L then
			local d = math.max(m.pos:Distance(L), 1)
			local ours = A.Native.Law(m.lvl)(d) * (m.g or 1) * (m.vol or 1)
			local eng = A.AC.EngineGain(d, m.lvl) * (m.vol or 1)
			local over = db(ours) - db(eng)
			if over > LOUD_DB then
				note("louder_vanilla", name, { sound = name, lvl = m.lvl, dist = math.floor(d), overDb = math.Round(over, 1), g = m.g })
			end
		end
	end
	for k in pairs(W.seen) do if not alive[k] then W.seen[k] = nil W.mg[k] = nil W.deadT[k] = nil end end
	-- a driven engine vehicle with no mirror of any of its sounds
	local ply = LocalPlayer()
	local veh = IsValid(ply) and ply:InVehicle() and ply:GetVehicle() or nil
	if IsValid(veh) and ENGINE_VEHICLES[veh:GetClass()] then
		local vi, any = veh:EntIndex(), false
		for _, m in pairs(LP and LP.mirrors or {}) do if m.idx == vi then any = true break end end
		if any then W.vehQuietT = nil else W.vehQuietT = W.vehQuietT or now end
		if W.vehQuietT and now - W.vehQuietT > SILENT_S then
			note("vehicle_silent", veh:GetClass(), { class = veh:GetClass(), since = math.Round(now - W.vehQuietT, 1), pos = tostring(veh:GetPos()) })
		end
	else
		W.vehQuietT = nil
	end
	for k, names in pairs(byChan) do
		local distinct = {}
		for _, n in ipairs(names) do distinct[n] = true end
		if table.Count(distinct) > 1 then note("overlap_channel", k, { names = table.concat(names, " + ") }) end
	end
	-- module voices count
	if pba_native and pba_native.Stats then
		local ok, s = pcall(pba_native.Stats)
		if ok and s and (s.voices or 0) > VOICES_MAX then note("voices_spike", "voices", { voices = s.voices }) end
	end
	-- forget dead voices
	if W.tick % 50 == 0 then
		local rt = RealTime()
		for id, v in pairs(W.voices) do if rt - v.t > 30 then W.voices[id] = nil end end
	end
end)

--- Summary for sweep.py (keys stripped, mouth histories only for the asked entities).
function W.Report(mouthFor)
	local out = { anomalies = {} }
	for kind, a in pairs(W.anomalies) do
		out.anomalies[kind] = { count = a.count, distinct = table.Count(a.keys), samples = util.TableToJSON(a.samples) }
	end
	out.mouth = util.TableToJSON(W.copies)
	out.census = util.TableToJSON(W.census or {})
	return out
end
function W.Reset() W.anomalies = {} W.copies = {} W.seen = {} W.mg = {} W.deadT = {} W.vehQuietT = nil end
return true
