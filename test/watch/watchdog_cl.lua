-- pba anomaly watchdog, client side (test tool, loaded by file into a test instance: lua_exec_file or
-- include). Runs from hooks and timers, never from a lua_job loop, and records anomalies in the global
-- PBA_WATCH_CL (read at the end by test/watch/sweep.py). Each detector keeps a count and a few samples
-- (sound, entity, map, position, time) so a report says what to reproduce.
-- Detectors (client):
--   stuck_once      a pba mirror of a non-looping line alive longer than its file (+ margin): stuck or looping
--   overlap_channel two pba mirrors of different lines alive at once on one entity's voice channel
--   mirror_step     a mirror's gain jumps > STEP_DB between two samples with no ramp (audible step)
--   voice_step      a module voice's gain jumps > STEP_DB between two Update calls < 0.5 s apart, outside a glide
--   voice_glide     a module voice glides > GLIDE_DB within 0.4 s (its target jumped: a path appearing / vanishing)
--   louder_vanilla  a module loop's sent gain > LOUD_DB above the engine's own law for its level (vanilla audible)
--   audible_vanilla_silent  same where vanilla plays nothing (law below ENGINE_CUT_DB): > LOUD_DB above that cut
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
local STEP_DB, LOUD_DB, VOICES_MAX, ONCE_MARGIN, GLIDE_DB, HITCH_S = 3, 6, 96, 3, 12, 0.15
local ENGINE_CUT_DB = -36 -- the engine's own law below this: vanilla plays nothing (startmovie wav, gm_flatgrass, levels 60-100:
-- audible down to -35.0 dB, digital silence from -38.4 dB, at volume 0.16 and 1 alike; the quietest steps are coarse: -29.4, -31.9, -35.4)
local JUMP_UNITS, JUMP_QUIET = 200, 1.5 -- a listener teleport (the sweeper's) changes paths for real: no step check right after
-- a teleport is also a listener faster than any walk or sprint (the sweeper's trigger centres can be < 200 u apart:
-- a Breencast mirror stepped 47 dB at a 'still' listener on d2_prison_04, 2026-11-13)
local JUMP_SPEED, JUMP_SLACK = 700, 8 -- u/s, u
local function jumped(a, b, dt) return a and b and a:Distance(b) > math.min(JUMP_UNITS, JUMP_SPEED * math.max(dt, 0) + JUMP_SLACK) end
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
		if id and id > 0 then
			W.voices[id] = { n = n, g = gain, t = RealTime(), steps = 0, pos = pos, first = true, by = "Play",
				L = pba and pba.ListenerPos and pba.ListenerPos() or nil }
		end
		return id
	end
	pba_native.Update = function(id, pos, gain, ...)
		local v = W.voices[id]
		if v and gain then
			local now = RealTime()
			-- the listener now, checked here: the sweeper's teleports happen between two timer ticks, and the
			-- voices re-evaluated in the frames before the next tick stepped for real (new paths) without the
			-- timer's jump mark yet (2026-11-13: most voice_step samples shared one time across many sounds)
			local L = pba and pba.ListenerPos and pba.ListenerPos() or nil
			if jumped(L, W.lastLU, now - (W.lastLUT or now)) then W.jumpRT = now end
			if L then W.lastLU, W.lastLUT = L, now end
			local moved = L and v.L and L:Distance(v.L) > JUMP_UNITS
			local c = debug.getinfo(2, "Sl")
			local by = c and ((string.match(c.short_src, "[^/\\]+$") or "?") .. ":" .. c.currentline) or "?"
			-- (same frame as the previous update: a re-evaluation restarting its glide sends the value heard, then the
			-- per-frame follower sends it again; that zero change is no neighbour. A frame longer than HITCH_S (the
			-- test instances share the machine: 0.2-0.5 s stalls) finishes a glide in one frame: no step of pba's)
			if now - v.t < 1e-3 then
				v.g, v.by = gain, by
				return update(id, pos, gain, ...)
			end
			local ok = v.g and v.g > 1e-3 and gain > 1e-3 and now - v.t < 0.5 and not moved and now - (W.jumpRT or -99) > JUMP_QUIET
				and CurTime() - (W.jumpT or -99) > JUMP_QUIET and RealFrameTime() < HITCH_S
			local d = ok and db(gain) - db(v.g) or 0
			local function glides(a, b) return a ~= 0 and b ~= 0 and (a > 0) == (b > 0) and math.abs(a) >= 0.3 * math.abs(b) end
			-- a step is decided one update later: a frame of a glide (continuous_ramp spreads a re-evaluation over
			-- update_interval, about 5 frames at a test instance's 20 fps: 3-8 dB per frame) has a neighbour moving
			-- the same way; a jump has none. (2026-11-13: most steps left after the teleport fix were glide frames)
			local cand = v.cand
			if cand then
				v.cand = nil
				if not glides(d, cand.db) then
					v.steps = v.steps + 1
					cand.nextDb = math.Round(d, 1)
					note("voice_step", tostring(v.n), cand)
				end
			end
			if math.abs(d) > STEP_DB and not glides(v.d or 0, d) then
				-- first: the first update after Play (the module jumps from the Play gain); by / prevBy: the
				-- callers of this update and the previous one (two drivers of one voice disagreeing)
				v.cand = { sound = tostring(v.n), fromG = math.Round(v.g, 4), toG = math.Round(gain, 4),
					db = math.Round(d, 1), pos = pos and tostring(pos) or nil, first = v.first or nil,
					dt = math.Round(now - v.t, 3), by = by, prevBy = v.by }
			end
			-- glide: the same-way changes summed; one over GLIDE_DB in at most 0.4 s is a level jump of the target
			-- (a path appearing / vanishing, a server volume change), smoothed but heard as a swell or a drop
			if ok and d ~= 0 and v.gs and (d > 0) == (v.gs > 0) and now - v.gt0 <= 0.4 then
				v.gs = v.gs + d
			else
				if v.gs and math.abs(v.gs) > GLIDE_DB then
					note("voice_glide", tostring(v.n), { sound = tostring(v.n), db = math.Round(v.gs, 1), secs = math.Round((v.gt1 or now) - v.gt0, 2),
						by = v.gby, pos = pos and tostring(pos) or nil })
				end
				v.gs, v.gt0, v.gby = ok and d ~= 0 and d or nil, now, by
			end
			v.gt1 = now
			v.d = ok and d or 0
			v.g, v.t, v.L, v.first, v.by = gain, now, L or v.L, nil, by
		end
		return update(id, pos, gain, ...)
	end
end

-- Every sound the client's engine plays on a face's voice channel drives its mouth: pba's mouth copies
-- (volume 0.001) and pba's own engine playback of a relayed line (cl_render vanilla(): the module could not
-- play it yet, e.g. a large file still loading) alike. Counted once the pba handler let it through. A mouth
-- copy for a speaker this client does not have (by index, pba_lipsync_unseen) has a NULL Entity in the hook:
-- pba tells it through pba.OnMouthCopy.
local function addCopy(i)
	W.copies[i] = W.copies[i] or {}
	table.insert(W.copies[i], math.Round(CurTime(), 2))
end
if pba then pba.OnMouthCopy = addCopy end
local function onSound(data, ret)
	local A = pba
	local ours = A and A.reemitting or (data and (data.Volume or 1) <= 0.002)
	if data and ret ~= false and ours and (data.Channel == CHAN_VOICE or data.Channel == CHAN_VOICE2) and IsValid(data.Entity) then
		addCopy(data.Entity:EntIndex()) -- (a copy noted twice, here and by OnMouthCopy: same timestamps)
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
	W.wrapped = function(data) local ret = W.orig(data) pcall(onSound, data, ret) return ret end
	hook.Add("EntityEmitSound", "pba", W.wrapped)
end
wrapHook()

timer.Create("pba_watch_cl", 0.1, 0, function()
	if (W.tick or 0) % 10 == 0 then wrapHook() end
	local A = pba
	if not A then return end
	local now = CurTime()
	local L = A.ListenerPos and (A.ListenerPos()) or LocalPlayer():EyePos()
	if jumped(L, W.lastL, now - (W.lastLT or now)) then W.jumpT = now end
	W.lastL, W.lastLT = L, now
	local quiet = now - (W.jumpT or -99) <= JUMP_QUIET
	W.tick = (W.tick or 0) + 1
	if W.tick % 3 ~= 0 then return end
	-- mirrors (pba.Loops.mirrors: "idx:chan:name")
	local LP = A.Loops
	local alive, byChan = {}, {}
	for key, m in pairs(LP and LP.mirrors or {}) do
		alive[key] = true
		-- (per mirror, not per key: a sound started again on the same entity, channel and name (a rock hitting
		-- the floor again, a scrape restarted) is a new mirror under the same key, a new start of the file)
		W.seenM = W.seenM or {}
		local first = W.seen[key]
		if not first or W.seenM[key] ~= m then first = now W.seen[key] = now W.seenM[key] = m end
		local name = m.name or ""
		local dur = 0
		if m.once then
			dur = A.SoundDuration and A.SoundDuration(bare(name)) or 0
			dur = dur / math.max((m.pitch or 100) / 100, 0.1)
			if dur > 0 and now - first > dur + ONCE_MARGIN then
				note("stuck_once", key, { sound = name, age = math.Round(now - first, 1), dur = math.Round(dur, 2), g = m.g, pos = m.pos and tostring(m.pos) or nil,
					native = m.nativeId ~= nil, patch = m.patch ~= nil, playing = m.patch and m.patch:IsPlaying() or nil,
					endIn = m.endT and math.Round(m.endT - RealTime(), 2) or nil, slicing = m.pbaSlice ~= nil or nil, client = m.client or nil })
			end
		end
		local idx, ch = string.match(key, "^(%d+):(%d+):")
		-- (only while each line is within its own file: a mirror lingering silent past its end is stuck_once's)
		-- (CHAN_AUTO 0 and CHAN_STATIC 6 never replace what the entity plays: lines overlap there in the engine too)
		-- (within its file: by its own end time when it has one, m.endT = file end + 0.5 s from its arrival; the
		-- first sight here lags the arrival by up to a tick, and a Breencast line starting as the previous one
		-- ends read as overlapping for one tick, d2_prison_04 2026-11-13)
		local within = not m.once or (m.endT and RealTime() < m.endT - 0.5) or (not m.endT and (dur <= 0 or now - first < dur))
		if idx and ch ~= "0" and ch ~= "6" and (ch == "2" or m.once) and within then
			local k = idx .. ":" .. ch
			byChan[k] = byChan[k] or {}
			table.insert(byChan[k], name .. "@" .. math.Round(now - first, 2))
		end
		local g = m.g
		local last = W.mg[key]
		-- (the listener where the last value was sampled: a far mirror's evaluation can land seconds after a
		-- teleport, out of the quiet window, and its new value then belongs to the new place, not a step)
		W.mgL, W.mgT = W.mgL or {}, W.mgT or {}
		local lastL = W.mgL[key]
		-- (or a teleport since that value: whatever its distance)
		local moved = (L and lastL and L:Distance(lastL) > JUMP_UNITS) or (W.mgT[key] and (W.jumpT or -99) >= W.mgT[key])
		if g and last and not quiet and not moved and g > 1e-3 and last > 1e-3 and not m.ramp and math.abs(db(g) - db(last)) > STEP_DB then
			note("mirror_step", name, { sound = name, fromG = math.Round(last, 3), toG = math.Round(g, 3), pos = m.pos and tostring(m.pos) or nil,
				native = m.nativeId ~= nil, once = m.once or nil, dsp = m.curDsp })
		end
		if g ~= last or not lastL then W.mgL[key], W.mgT[key] = L, now end
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
		-- louder than vanilla (module loops only). Compared: the gain last SENT to the module voice (the outermost
		-- Update wrap above: path losses, volume and pba_native_gain included, before the mix groups that the
		-- engine applies alike), not the law recomputed at the current distance (that hid a voice frozen at its
		-- near level while quiet: pba_native_quiet_law). Vanilla: AC.EngineGain x volume, which matches the real
		-- engine's output (startmovie recordings, gm_flatgrass, +-2 dB) while audible; below ENGINE_CUT_DB the
		-- engine plays nothing at all (recorded digital silence), where AC.EngineGain still says -40..-60 dB.
		-- Samples carry lawDb (the module's own law at that distance: the 1/r choice, pba_native_law_engine)
		-- and sentOverLawDb (> 0: the voice is louder than its own law, a bug, not the law choice).
		-- The source is the entity's centre (m.pos is where the sound started: a manhack 2000 u away from it), and
		-- nothing is judged right after a listener teleport (the voice still carries the old place's values).
		local v = m.nativeId and W.voices[m.nativeId]
		local S = IsValid(m.ent) and m.ent:WorldSpaceCenter() or m.pos
		if v and v.g and S and m.lvl and not quiet and A.Native and A.Native.Law and A.AC and L then
			local d = math.max(S:Distance(L), 1)
			local ng = math.max(A.cfg.native_gain or 1, 1e-6)
			local sent = v.g / ng
			local law = A.Native.Law(m.lvl)(d) * (m.g or 1) * (m.vol or 1)
			local eng = A.AC.EngineGain(d, m.lvl) * (m.vol or 1)
			local silent = db(eng) < ENGINE_CUT_DB
			local over = db(sent) - (silent and ENGINE_CUT_DB or db(eng))
			if over > LOUD_DB then
				note(silent and "audible_vanilla_silent" or "louder_vanilla", name, { sound = name, lvl = m.lvl, dist = math.floor(d),
					overDb = math.Round(over, 1), sentDb = math.Round(db(sent), 1), lawDb = math.Round(db(law), 1),
					engDb = math.Round(db(eng), 1), sentOverLawDb = math.Round(db(sent) - db(law), 1), g = m.g })
			end
		end
	end
<<<<<<< HEAD
	for k in pairs(W.seen) do if not alive[k] then W.seen[k] = nil W.mg[k] = nil if W.seenM then W.seenM[k] = nil end if W.mgL then W.mgL[k] = nil end end end
=======
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
>>>>>>> fix/l2-user-bugs
	for k, names in pairs(byChan) do
		local distinct = {}
		for _, n in ipairs(names) do distinct[string.match(n, "^(.*)@") or n] = true end
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
