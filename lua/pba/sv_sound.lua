-- The server's sound object (refactor step 12): every sound born on the server goes through ONE decision,
-- in three parts.
--   Classify : what the sound is. "follow" (a loop, a long one-shot or a patch start: sv_loops mirrors it),
--              "followStop" (the stop of a followed one), "briefTaken" (a change of a brief sound pba took
--              over: dropped), "engineDriven" (a physics friction loop: its lifecycle stays the engine's),
--              "stop" (a stop event), "brief" (a short sound), nil (left to the engine untouched). The loop
--              stage may also ask for a side step first (snd.pre: "stopAll", "capped", "loopStop").
--   Audience : what each player gets. "relay" (his client computes the paths), "clear" (the original
--              re-emitted unchanged), "muffled" (re-emitted by the engine with a preset and a gain: over the
--              relay budget, beyond lod_dist behind a wall, not ready, or a physics loop behind a wall), "far"
--              (beyond lod_dist, clear line), "mirror" (a followed sound's subscriber), nil (not his).
--   Dispatch : the emissions: engine re-emissions per group, captions, the relay message, the mirrors.
-- sv_relay keeps the network plumbing (name dictionary, pba_snd body, stops, channel rule, brief registry,
-- scenes); sv_loops keeps the followed sounds' registry and their enders (movers, chargers, vehicles,
-- constraints, CSoundPatch / LoopingSound detours, cap, release).

local A = pba
A.Sound = A.Sound or {}
local S = A.Sound
local LP = A.Loops
local band = bit.band
local STOP_LOOPING = SND_STOP_LOOPING or 32
-- A player whose pba client runs says so (sv_relay A.ClientReady)
local clientReady = function(ply) return A.ClientReady(ply) end

-- ------------------------------------------------------------------ classify

--- The loop stage (former LP.Handle head): fills snd.idx / key / l / once / dur / pre; returns "follow",
-- "followStop", "briefTaken" or nil (the brief stage decides).
local function loopStage(data, snd)
	if A.cfg.loops < 0.5 then return end
	local e = data.Entity
	-- players' own loops (underwater ambience...) are started and stopped by the engine's C++
	-- code: that StopSound never reaches Lua, a mirror would play forever. Left to the engine.
	-- Exception: a long ONE-SHOT of a player who does not hear from himself (a camera, see A.HearsFromSelf): the
	-- engine spatialises his sounds from the camera like anybody's, and a one-shot ends by itself (the mirror is
	-- bounded by the file's length), so it is followed and muffled like any long sound (pba_long_player_camera).
	-- A sound already followed stays followed (its updates and its stop), whatever he hears from by then.
	if IsValid(e) and e:IsPlayer() then
		-- (only the control events of a sound — stop, change — look up the key: a player's plain sounds are hot)
		local ctl = band(data.Flags or 0, SND_STOP + STOP_LOOPING + SND_CHANGE_VOL + SND_CHANGE_PITCH) ~= 0
		local followed = ctl and LP.active[e:EntIndex() .. ":" .. (data.Channel or 0) .. ":" .. data.SoundName]
		if not followed and (ctl or (A.cfg.long_player_camera or 1) < 0.5 or A.HearsFromSelf(e) or A.IsLooping(data.SoundName)) then
			return
		end
	end
	-- same for the loops of a weapon a player holds: the gravity gun's hold loop is a CSoundPatch on the
	-- weapon, faded and destroyed by its C++ (weapon_physcannon); a mirror rendered it to its holder as
	-- a foreign source and could outlive the destroy
	if IsValid(e) and e:IsWeapon() then
		local o = e:GetOwner()
		if IsValid(o) and o:IsPlayer() then return end
	end
	local idx = IsValid(e) and e:EntIndex() or 0
	local key = idx .. ":" .. (data.Channel or 0) .. ":" .. data.SoundName
	local l = LP.active[key]
	local flags = data.Flags or 0
	snd.idx, snd.key, snd.l = idx, key, l
	-- SND_STOP_LOOPING ("stop all looping sounds on the entity") comes on any name (common/null.wav)
	if band(flags, STOP_LOOPING) ~= 0 and idx ~= 0 then snd.pre = "stopAll" return end
	-- left to the engine by the cap: its changes are noted, the engine keeps it
	if LP.capped[key] then snd.pre = "capped" return end
	local once, dur = false, 0
	if not l then
		if A.IsLooping(data.SoundName) then
			-- engine-driven physics loops (scraping / rolling friction): their envelope lives in the physics
			-- engine and its end never reaches Lua. Followed as a mirror that ends with the prop's scraping
			-- (pba_phys_loops_mirror, LP.PhysEnded), else left to the engine (muffled behind a wall)
			if LP.IsPhysicsLoop(data.SoundName, e, data.OriginalSoundName) then
				if (A.cfg.phys_loops_mirror or 1) < 0.5 or not IsValid(e) or e:IsWorld() then return end
				snd.phys = true
			end
		else
			once, dur = LP.IsLong(data)
			-- a change of a brief sound still playing: not a new patch (audit B-8). Taken over by pba:
			-- dropped; played by the engine: its change is the engine's
			if not once and A.BriefPlaying then
				local playing, took = A.BriefPlaying(data)
				if playing then
					if took then return "briefTaken" end
					return
				end
			end
			if not once then once, dur = LP.IsPatchStart(data) end
			if not once then return end
		end
	end
	-- stop events carry no sound level: test them first (SND_STOP_LOOPING ends a loop the same way)
	if band(flags, SND_STOP + STOP_LOOPING) ~= 0 then
		if LP.Following(idx, data.SoundName) then return "followStop" end
		snd.pre = "loopStop" -- (forgets the released and capped ones of that name)
		return
	end
	if not l and (data.SoundLevel or 75) <= 0 then return end -- 2D loops: leave to the engine
	snd.once, snd.dur = once, dur
	return "follow"
end

--- The brief stage (former relay head): "engineDriven", "stop", "brief" or nil. A sentence is carried by
-- its name, on a copy of the table (snd.data): the engine's own is passed on to every later EntityEmitSound
-- hook, and played as they leave it: they must still see "invalid.wav".
local function briefStage(snd)
	local data = snd.data
	if LP.EngineDriven and LP.EngineDriven(data) then return "engineDriven" end
	-- a stop event (some engine paths do send one): same relay as StopSound
	if band(data.Flags or 0, SND_STOP) ~= 0 then return "stop" end
	local sentence = data.SoundName == "invalid.wav" and (A.cfg.sentences or 0) >= 0.5 and (data.OriginalSoundName or "") ~= ""
	if sentence then
		local d = {}
		for k, v in pairs(data) do d[k] = v end
		d.SoundName = "!" .. data.OriginalSoundName
		-- (on the world: where EmitSentence was told to play it)
		local e = d.Entity
		if not d.Pos and isvector(A.sentencePos) and not (IsValid(e) and not e:IsWorld()) then d.Pos = A.sentencePos end
		snd.data, snd.sentence = d, true
	end
	if not A.Eligible(snd.data) then return end
	return "brief"
end

--- What sound `data` is (no side effect): its kind (see the header) and the sound object, whose fields the
-- audience and the dispatch read.
function S.Classify(data)
	local snd = { data = data }
	snd.kind = loopStage(data, snd)
	if not snd.kind then snd.kind = briefStage(snd) end
	return snd.kind, snd
end

--- The loop stage's side step: a SND_STOP_LOOPING stops every followed loop of the entity, a capped loop's
-- change is noted, a stop forgets the released / capped entries of that name. The brief stage follows.
local function runPre(snd)
	local p = snd.pre
	if p == "stopAll" then LP.Stop(snd.idx, nil)
	elseif p == "capped" then LP.NoteCapped(snd.key, snd.data)
	elseif p == "loopStop" then LP.Stop(snd.idx, snd.data.SoundName) end
end

--- The loop stage's own kinds. True when the sound is pba's (the engine's original is suppressed).
local function takeLoop(kind, snd)
	if kind == "follow" then return LP.Take(snd.data, snd) end
	if kind == "followStop" then return LP.Stop(snd.idx, snd.data.SoundName) end
	return kind == "briefTaken"
end

--- Handles an EntityEmitSound table if it belongs to a loop or a long sound (the loop stage only). Returns
-- true when taken over. (The timer's take-over of capped loops, AdoptAmbients, tests.)
function LP.Handle(data)
	local snd = { data = data }
	local kind = loopStage(data, snd)
	runPre(snd)
	return takeLoop(kind, snd) == true
end

-- ------------------------------------------------------------------ audience


-- (fallback: a partial autorefresh may reload this file before sh_core)
--- Token bucket of one player: `rate` per second, burst one second. `key`: the player field holding
-- the bucket, so relays and echo-only relays have separate budgets (a battle's loud gunfire must not
-- eat the budget that keeps the gunfire behind a wall muffled). `stat`: counter of the misses.
local function takeToken(st, key, rate, stat)
	local now = CurTime()
	local b = st[key]
	if not b or now < b.t then
		-- (a bucket from a clock that went back: start full rather than owe thousands of tokens)
		b = { tok = rate, t = now }
		st[key] = b
	end
	local t = math.min(rate, b.tok + (now - b.t) * rate)
	b.t = now
	if t < 1 then
		b.tok = t
		A.stats[stat] = (A.stats[stat] or 0) + 1
		return false
	end
	b.tok = t - 1
	return true
end

--- Relay budget of one player (pba_relay_rate per second), so a huge firefight cannot flood the
-- network. Out of tokens, a player behind a wall is NOT given the original (it would play at full
-- volume through the wall: near the cap, gunfire behind a wall flipped between muffled and 20-30 dB
-- louder shot to shot); he gets it re-emitted by the engine, muffled (see muffleFor).
local function relayToken(ply)
	return takeToken(A.PState(ply), "relayBucket", A.cfg.relay_rate or 80, "relayCapped")
end

--- Echo-only relay budget: its own bucket (same rate). Out of tokens the player only misses the
-- client-side echo tail, he still hears the direct sound: never louder, just drier.
local function echoToken(ply)
	return takeToken(A.PState(ply), "echoBucket", A.cfg.relay_rate or 80, "echoCapped")
end

--- Engine muffling for a blocked player over budget (P.MuffleFor): DSP preset and volume factor.
local function muffleFor(walls) return A.Paths.MuffleFor(walls) end

-- Per-(player, sound name) relay quota (pba_relay_name_rate). One sound name from many sources (thirty gibs
-- breaking concrete, 13-18 impacts a second each, sweep 2026-11-14 d2_coast_05) ate the whole budget: the few
-- different sounds of that second (the wall crashing, a boulder, a spark) got no relay. Past its quota a name
-- takes no token: it is muffled by the engine from the verdict of a recent relay of that name that was close
-- (same wall, no new trace), or by one trace when none is.
local NAME_VERDICTS = 4       -- recent verdicts kept per (player, name)
local NAME_SRC_U2 = 256 * 256 -- a verdict serves a source this close to the one it was made for
local NAME_EAR_U2 = 128 * 128 -- ... and an ear this close
local NAME_AGE_S = 2          -- ... for this long
local NAME_MAX = 256          -- names kept per player (the table starts over beyond)

local function nameState(ply, name)
	local st = A.PState(ply)
	local t = st.nameQ
	if not t or t.n >= NAME_MAX then
		t = { n = 0 }
		st.nameQ = t
	end
	local s = t[name]
	if not s then
		s = { v = {}, nxt = 1 }
		t[name] = s
		t.n = t.n + 1
	end
	return s
end

local function nearVerdict(e, pos, eye)
	local dx, dy, dz = e.x - pos.x, e.y - pos.y, e.z - pos.z
	if dx * dx + dy * dy + dz * dz > NAME_SRC_U2 then return false end
	dx, dy, dz = e.ex - eye.x, e.ey - eye.y, e.ez - eye.z
	return dx * dx + dy * dy + dz * dz <= NAME_EAR_U2
end

--- Notes the walls found between `pos` and `eye` for a sound of the name state `ns` (the verdict a later
-- sound of that name reuses past its quota): refreshes the verdict of that place, else takes the oldest slot.
local function noteVerdict(ns, pos, eye, walls)
	local v, e = ns.v
	for i = 1, #v do
		if nearVerdict(v[i], pos, eye) then e = v[i] break end
	end
	if not e then
		if #v < NAME_VERDICTS then
			e = {}
			v[#v + 1] = e
		else
			e = v[ns.nxt]
			ns.nxt = ns.nxt % NAME_VERDICTS + 1
		end
	end
	e.x, e.y, e.z, e.ex, e.ey, e.ez = pos.x, pos.y, pos.z, eye.x, eye.y, eye.z
	e.t, e.walls, e.dsp, e.gain = CurTime(), walls, nil, nil
end

--- The verdict (DSP preset, gain) of a recent relay of this name near `pos` / `eye`; nil when none.
local function reuseVerdict(ns, pos, eye)
	local now = CurTime()
	local v = ns.v
	for i = 1, #v do
		local e = v[i]
		if e.walls and now - e.t <= NAME_AGE_S and nearVerdict(e, pos, eye) then
			if not e.dsp then e.dsp, e.gain = muffleFor(e.walls) end
			return e.dsp, e.gain
		end
	end
end

-- Footsteps of other players: the engine sends the server's footstep only to the players of the PAS
-- outside the stepping player's PVS (CBasePlayer::PlayStepSound: RemoveRecipientsByPVS); the players
-- who see him generate the footstep on their own client. PlayerFootstep runs right before that
-- emission: the stepping player is noted for this tick, and the players whose PVS holds him are left
-- out (relaying to them too doubled every step).
-- The footstep itself, by its name (pba_step_by_name): his gunshot or pain cry in the same tick is not one, and was left
-- out for every witness too (nothing played it for them: ~1 shot in 20 while running).
hook.Add("PlayerFootstep", "pba_step", function(ply, _, _, snd)
	A.stepPly, A.stepTick = ply, engine.TickCount()
	A.stepFiles = isstring(snd) and snd ~= "" and A.StopFiles(snd) or nil
end)

local function stepper(data)
	local e = data.Entity
	if IsValid(e) and e:IsPlayer() and A.stepPly == e and A.stepTick == engine.TickCount() then
		if (A.cfg.step_by_name or 1) >= 0.5 then
			local f = A.stepFiles
			if not f or not (A.StopReaches(f, data.SoundName) or A.StopReaches(f, data.OriginalSoundName)) then return nil end
		end
		return e
	end
end

--- True when entity e's sound, made during `predicted`'s command, is one his client predicts itself: the
-- engine leaves him out of it (the suppressed host of a filter using prediction rules: what he and what he
-- holds emit in shared code). Another entity's sound made during his command (an NPC his bullet hits, a
-- window it breaks) is sent to him as to anyone.
local function predictedBy(e, predicted)
	if not IsValid(predicted) then return false end
	if (A.cfg.predicted_exact or 1) < 0.5 then return true end
	if not IsValid(e) then return false end
	return e == predicted or e:GetOwner() == predicted
end

--- True when ply's module plays his own sounds too (userinfo pba_native_own_want, with pba_native_all).
local function wantsOwn(ply)
	return A.cfg.native_relay >= 0.5 and A.cfg.allow_native >= 0.5 and ply:GetInfoNum("pba_native_own_want", 0) >= 1
end

--- Fills what the audience of an engine-driven or brief sound reads, once per sound. False: no position.
local function prepare(snd)
	local data = snd.data
	local pos = A.SoundPos(data)
	if not pos then return false end
	local lvl = data.SoundLevel or 75
	-- the whole audible radius, not just lod_dist: once the original is suppressed for someone, every
	-- player the engine would have sent it to must get it back. A 140 dB explosion is heard to 9000 u;
	-- a player at 7000 u (beyond lod_dist 6000) lost it as soon as one player near it was behind a wall.
	local radius, lod = A.AudibleRadius(lvl), A.cfg.lod_dist
	snd.pos, snd.lvl, snd.r2, snd.lod2 = pos, lvl, radius * radius, lod * lod
	if snd.kind == "engineDriven" then
		snd.srcObj = data.Entity
		return true
	end
	-- the object the sound comes from (an impact on the world inside its object): not its own wall
	snd.srcObj = A.Paths.SourceObject(pos, data.Entity)
	local predicted = GetPredictionPlayer()
	snd.predicted = predicted
	-- singleplayer has no prediction: the engine sends the player his own sounds from here, and his
	-- client never sees them (no echoes on his own gunfire)
	local sp = game.SinglePlayer()
	-- one rule for "the player's own sound", singleplayer or multiplayer (mp_own): everything the server plays
	-- on a player, in or outside his command (his weapon, pain, fall damage, his suit's HEV lines), is his
	-- own: the engine plays it on him, clear. Those of his command in multiplayer go to nobody (his client
	-- predicts them, below)
	snd.own = (A.cfg.mp_own or 1) >= 0.5
	-- the player whose command made the sound, when his client predicts it (nobody otherwise)
	snd.skip = not sp and predictedBy(data.Entity, predicted) and predicted or nil
	snd.step = not sp and stepper(data)
	return true
end

-- where the walls of a sound are traced from: the nearest point outside the solid (P.FreeSource: a camera in its
-- ceiling, a muzzle in the wall an NPC leans on, a position exactly on a face), found once per sound
local function wallsFrom(snd)
	local p = snd.wpos
	if not p then p = A.Paths.FreeSource(snd.pos) snd.wpos = p end
	return p
end

--- What player ply gets of sound snd: "relay" | "clear" | "muffled", dsp, gain | "far" | "mirror" | nil (see
-- the header). Audience by distance, not PAS: a sealed room is outside the PAS (the engine would not send the
-- sound at all) but its sound still transmits through the walls. A brief sound's relay takes a token of the
-- player's budget. scale: a mirror's leaving hysteresis.
function S.Audience(snd, ply, scale)
	local kind = snd.kind
	-- a followed sound (sv_loops entry): every player in range gets the mirror, the engine cannot resume midway
	if kind == "mirror" or snd.subs then
		-- (pba_loops_ready) not before his client runs: a start sent while he joins is lost and he would stay
		-- subscribed to nothing; once ready, the 0.5 s timer (sv_loops) has him join it as a player entering its range
		if (A.cfg.loops_ready or 1) >= 0.5 and not clientReady(ply) then return nil end
		return LP.InRange(snd, ply, scale) and "mirror" or nil
	end
	local pos, data = snd.pos, snd.data
	if kind == "engineDriven" then
		-- re-emitted by the engine in place, muffled per player behind a wall (no path search, no relay)
		local eye = A.PlayerEar(ply)
		local d2 = eye:DistToSqr(pos)
		if d2 > snd.r2 then return nil end
		if A.ClientOff and A.ClientOff(ply) then return "clear" end -- (pba off on his side: untouched)
		local walls = d2 <= snd.lod2 and A.Paths.Walls(wallsFrom(snd), eye, 1, snd.srcObj) or nil
		if walls and #walls > 0 then
			local dsp, gain = muffleFor(walls)
			return "muffled", dsp, gain
		end
		return "clear"
	end
	-- brief
	local e = data.Entity
	-- his own sound: the engine plays it on him, untouched, unless his module plays it like every other sound
	-- (pba_native_own: the relay below, as for a native-all player's clear sound)
	-- (not through a camera: the engine spatialises his sounds from there, so they take the path of any sound)
	local ownEar = snd.own and ply ~= snd.skip and e == ply and A.HearsFromSelf(ply)
	if ownEar and not wantsOwn(ply) then return "clear" end
	-- his own sound for his module (pba_native_own): no wall to look for between him and himself, and no
	-- relay budget or per-name quota (an SMG's 13 shots a second hit the quota: the shots over it went to
	-- the engine and the next relayed shot cut them on the weapon channel)
	if ownEar then return "relay" end
	local step = snd.step
	if ply == snd.skip or (step and ply ~= step and ply:TestPVS(step)) then return nil end
	local eye = A.PlayerEar(ply)
	local d2 = eye:DistToSqr(pos)
	if d2 > snd.r2 then return nil end
	-- pba off on his side (pba_cl_enable 0, pba_relay_cl_enable): the engine's sound, untouched
	if A.ClientOff and A.ClientOff(ply) then return "far" end
	if d2 > snd.lod2 or not clientReady(ply) then
		-- too far for a path search (or his pba client not running): the cheap muffle of an over-budget
		-- player when the line is blocked (pba_far_muffle; it was heard through the wall as in plain sight)
		local walls = (A.cfg.far_muffle or 0) >= 0.5 and A.Paths.Walls(wallsFrom(snd), eye, 1, snd.srcObj) or nil
		if walls and #walls > 0 then
			local dsp, gain = muffleFor(walls)
			A.stats.farMuffled = (A.stats.farMuffled or 0) + 1
			return "muffled", dsp, gain
		end
		return "far"
	end
	-- clients rendering every sound natively (userinfo pba_native_all_want) get the relay even with a clear
	-- line: their module plays the sound instead of the engine
	local all = A.cfg.native_relay >= 0.5 and A.cfg.allow_native >= 0.5 and ply:GetInfoNum("pba_native_all_want", 0) >= 1
	-- one name from many sources: past its quota it takes no token of the budget the other sounds share
	local nq = A.cfg.relay_name_rate or 8
	local ns
	if nq > 0 then
		ns = nameState(ply, data.SoundName)
		if not takeToken(ns, "bucket", nq, "relayNameCapped") then
			local dsp, gain = reuseVerdict(ns, pos, eye)
			if dsp then
				A.stats.relayNameReused = (A.stats.relayNameReused or 0) + 1
				return "muffled", dsp, gain
			end
			local w = A.Paths.Walls(wallsFrom(snd), eye, 1, snd.srcObj)
			if #w == 0 then return "clear" end
			noteVerdict(ns, pos, eye, w)
			dsp, gain = muffleFor(w)
			return "muffled", dsp, gain
		end
	end
	local walls = not all and A.Paths.Walls(wallsFrom(snd), eye, 1, snd.srcObj) or nil
	if (all or #walls > 0) and relayToken(ply) then
		if ns and walls then noteVerdict(ns, pos, eye, walls) end
		return "relay"
	end
	-- over budget (or a clear line): the wall test decides, a native-all player over budget included (his
	-- relay was not conditioned on a wall)
	walls = walls or A.Paths.Walls(wallsFrom(snd), eye, 1, snd.srcObj)
	if #walls > 0 then
		if ns then noteVerdict(ns, pos, eye, walls) end
		local dsp, gain = muffleFor(walls)
		return "muffled", dsp, gain
	end
	return "clear"
end

-- ------------------------------------------------------------------ dispatch

--- Re-emits the original sound, through the engine, to `plys` only (A.Emit: our hook lets it pass).
-- Its own start time (SoundTime) goes with it: EmitSound takes none, our hook puts it back on the
-- re-emission (A.reemitTime), so the engine spaces two shots of one update as it would the original.
local function reemit(data, pos, lvl, plys, name, vol, dsp)
	local f = RecipientFilter()
	f:AddPlayers(plys)
	local e = data.Entity
	local st = (A.cfg.soundtime or 1) >= 0.5 and data.SoundTime or 0
	A.reemitTime = st ~= 0 and st or nil
	if IsValid(e) and not e:IsWorld() then
		A.Emit(A.orig.EntEmitSound, e, name, lvl, data.Pitch, vol, data.Channel, data.Flags, dsp, f)
	else
		A.Emit(A.orig.EmitSound, name, pos, 0, data.Channel, vol, lvl, data.Flags, data.Pitch, dsp, f)
	end
	A.reemitTime = nil
end

--- The muffled players, one engine emission per (preset, level): players behind the same kind of wall share
-- it. The sound's own preset (a scripted DSP) is kept when we have none to apply.
local function reemitMuffled(snd, muffled, name)
	local data = snd.data
	local groups, order = {}, {}
	for _, m in ipairs(muffled) do
		local k = m.dsp .. ":" .. math.Round(m.gain * 1000)
		local g = groups[k]
		if not g then
			g = { dsp = m.dsp, gain = m.gain, plys = {} }
			groups[k] = g
			order[#order + 1] = g
		end
		g.plys[#g.plys + 1] = m.ply
	end
	for _, g in ipairs(order) do
		reemit(data, snd.pos, snd.lvl, g.plys, name, (data.Volume or 1) * g.gain, g.dsp > 0 and g.dsp or data.DSP)
	end
end

--- The audience of snd split by verdict: clear, relay, muffled ({ ply, dsp, gain }), far.
local function audienceOf(snd)
	local clear, relay, muffled, far = {}, {}, {}, {}
	for _, ply in ipairs(player.GetHumans()) do
		local v, dsp, gain = S.Audience(snd, ply)
		if v == "clear" then clear[#clear + 1] = ply
		elseif v == "relay" then relay[#relay + 1] = ply
		elseif v == "muffled" then muffled[#muffled + 1] = { ply = ply, dsp = dsp, gain = gain }
		elseif v == "far" then far[#far + 1] = ply end
	end
	return clear, relay, muffled, far
end

--- A sound whose lifecycle stays the engine's (physics friction loops, LP.EngineDriven): each of its events
-- (start, volume / pitch changes) re-emitted by the engine itself, muffled per player as a budget miss is
-- (DSP preset + volume from the walls), its name, channel and flags kept, so later changes and the C++
-- StopSound (sent to every player) still reach the copies. Clear players get it unchanged; nobody behind a
-- wall: untouched. Returns false when the original was replaced.
local function dispatchEngineDriven(snd)
	local data = snd.data
	local lvl = data.SoundLevel or 75
	if lvl <= 0 or lvl >= 256 then return end
	if not prepare(snd) then return end
	local clear, _, muffled = audienceOf(snd)
	if #muffled == 0 then return end
	if #clear > 0 then reemit(data, snd.pos, snd.lvl, clear, data.SoundName, data.Volume, data.DSP) end
	reemitMuffled(snd, muffled, data.SoundName)
	A.stats.physMuffled = (A.stats.physMuffled or 0) + 1
	return false
end

--- (pba_early_line_takeover, sv_relay A.NoteEarly) A spoken line the engine plays for players whose early window
-- is open: kept for those who are not ready (whatever their verdict: far, muffled, clear), and for the ready ones
-- in clear sight whose module does not render every sound yet (pba_native_all_want still 0: its rendering
-- starting); their client hands it to the module once settled.
local function noteEarly(snd, clear, muffled, far)
	local secs = A.EarlyLine(snd.data) -- (the line test first: most sounds are not lines)
	if not secs then return end
	local function note(ply, ev, verdict)
		if not A.EarlyOpen(ply) then return end
		local blocked = not clientReady(ply)
		if not blocked and not (verdict == "clear" and ply:GetInfoNum("pba_native_all_want", 0) < 1) then return end
		A.NoteEarly(snd.data, secs, ply, ev, blocked)
	end
	local vol = snd.data.Volume or 1
	for _, p in ipairs(clear) do note(p, vol, "clear") end
	for _, p in ipairs(far) do note(p, vol, "far") end
	for _, m in ipairs(muffled) do note(m.ply, vol * m.gain, "muffled") end
end

--- A brief sound: re-emitted unchanged for the clear listeners, muffled for those over budget, relayed to the
-- others; untouched when nobody is blocked. Returns false when the original was replaced.
local function dispatchBrief(snd)
	if not prepare(snd) then return end
	local data, pos, lvl = snd.data, snd.pos, snd.lvl
	local clear, blocked, muffled, far = audienceOf(snd)
	if (A.cfg.early_line_takeover or 1) >= 0.5 and A.NoteEarly and not snd.sentence then noteEarly(snd, clear, muffled, far) end
	-- clients rendering echoes natively also want the loud sounds they hear directly
	if A.cfg.echo_relay >= 0.5 and A.cfg.allow_native >= 0.5 and lvl >= A.cfg.echo_min_level and #clear > 0 then
		local want = {}
		for _, ply in ipairs(clear) do
			if ply:GetInfoNum("pba_echo_want", 0) >= 1 and echoToken(ply) then want[#want + 1] = ply end
		end
		if #want > 0 then A.RelaySend(data, pos, want, true) end
	end
	-- players beyond lod_dist hear the original as clear players do (vanilla when nobody is blocked)
	for _, p in ipairs(far) do clear[#clear + 1] = p end
	-- a sentence cannot be re-emitted to some players only (EmitSentence takes no filter): players
	-- over budget get the relay anyway (sentences are rare, a few per minute)
	if snd.sentence then
		-- (pba_sentence_ready) ... but not to a player whose pba client is not ready: nothing would play it for him.
		-- Then the engine plays it for everyone, as it would without pba.
		if (A.cfg.sentence_ready or 1) >= 0.5 then
			for _, p in ipairs(clear) do if not clientReady(p) then A.stats.untouched = A.stats.untouched + 1 return end end
			for _, m in ipairs(muffled) do if not clientReady(m.ply) then A.stats.untouched = A.stats.untouched + 1 return end end
		end
		for _, m in ipairs(muffled) do blocked[#blocked + 1] = m.ply end
		muffled = {}
	end
	if #blocked == 0 and #muffled == 0 then
		A.stats.untouched = A.stats.untouched + 1
		return
	end
	-- a sentence: the clear listeners get the relay too, and their client plays it unchanged
	if snd.sentence and #clear > 0 then
		for _, p in ipairs(clear) do blocked[#blocked + 1] = p end
		clear = {}
	end
	if #clear > 0 then reemit(data, pos, lvl, clear, data.SoundName, data.Volume, data.DSP) end
	if #muffled > 0 then
		-- a "#" (dry mix) sound gets no DSP from the engine: the same file without it, or the preset
		-- would be ignored and the sound only quieter
		reemitMuffled(snd, muffled, A.WithoutDryMix(data.SoundName))
		A.stats.relayMuffled = (A.stats.relayMuffled or 0) + #muffled
	end
	-- the relayed players apart: their caption arms the client's safety net for a lost relay (pba_caption_net)
	local told = {}
	for _, p in ipairs(clear) do told[#told + 1] = p end
	for _, m in ipairs(muffled) do told[#told + 1] = m.ply end
	A.SendCaption(data, told)
	A.SendCaption(data, blocked, true)
	if #blocked == 0 then return false end
	local e = data.Entity
	if IsValid(e) and not e:IsWorld() then
		local r = A.recentTo[e:EntIndex()] or {}
		A.recentTo[e:EntIndex()] = r
		local now = CurTime()
		for _, p in ipairs(blocked) do r[p] = now end
	end
	A.RelaySend(data, pos, blocked)
	A.relayedTo = blocked
	A.stats.relayed = A.stats.relayed + 1
	return false
end

--- The hook's body: classify, then the loop stage's step and kinds, then the brief stage's. Returns false
-- when the original is suppressed (taken over, relayed, re-emitted), nil when the engine plays it.
function S.Dispatch(data)
	A.stats.seen = A.stats.seen + 1
	local snd = { data = data }
	local kind = loopStage(data, snd)
	runPre(snd)
	if takeLoop(kind, snd) then return false end
	snd.kind = briefStage(snd)
	kind = snd.kind
	if kind == "engineDriven" then return dispatchEngineDriven(snd) end
	if kind == "stop" then
		A.RelayStop(data.Entity, data.SoundName)
		return
	end
	if kind == "brief" then return dispatchBrief(snd) end
end

A.AddHook("EntityEmitSound", (A.WithChannelRule or function(f) return f end)(function(data)
	if A.reemitting then
		-- pba's re-emission: the original's start time put back (reemit)
		if A.reemitTime then data.SoundTime = A.reemitTime return true end
		return
	end
	A.relayedTo = nil
	if A.explicitFilter then return end
	local ret = S.Dispatch(data)
	A.HoldCopies(data, A.relayedTo)
	A.NoteBrief(data, ret == false)
	return ret
end))
