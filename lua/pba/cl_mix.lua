-- pba: the engine's sound mixer (mix groups, soundscape mixers, ducking) for natively rendered sounds.
-- Copyright (C) 2026 pba contributors. Licensed under the GNU GPL v3 or later (see LICENSE).
--
-- The engine scales every sound it plays by a "mix value" (audit C-2 / C-3 / C-4, read in engine.dll):
-- * scripts/soundmixers.txt lists GROUPRULES (group, substring of the file name, substring of the source
--   entity's class name, channel, level min / max, priority, is ducked, causes ducking, duck to %,
--   threshold %) then named mixers giving a value to some groups. Default_Mix: All 0.72, Weapons 0.79,
--   Explosions 0.90, bullet hits 0.67, the HEV 0.56, the player's own loud weapons 1.0...
-- * a sound belongs to the groups whose rule matches, in the file's order (8 at most); the file name rules
--   count only among the first 8 that match the name. Matching ignores case.
-- * its value: the first of its groups the current mixer (snd_soundmixer, set by soundscapes:
--   d3_citadel's Citadel_Dialog_Only puts everything but dialog at 0.01) gives a value, times the lowest
--   duck of its "ducked" groups up to that one; no such group: the duck alone.
-- * ducking, every 0.1 s: the volumes of the playing sounds are summed per group that causes ducking
--   (weapons, explosions, dialog, music); one over its threshold makes every ducked group of lower
--   priority (ambience, vehicles, music) ramp linearly to its "duck to" share in snd_duckerattacktime,
--   then back in snd_duckerreleasetime; nothing moves while no ducked sound plays.
-- The module's voices skipped all of it: 2.9 dB louder than the engine for most sounds, a level jump
-- when a sound passed from the engine to the module, no Citadel silence, no ducking. Here the same
-- rules give each module voice its value (pba_native_mix), ducking included (pba_native_duck).
-- Limits: the ducker only hears the sounds pba sees on the client (A.Process, the relays, the client
-- hook): server sounds the engine plays in clear sight do not count, loops (mirrors) are ducked but do not
-- duck (their volume is not summed), and the module's voices do not feed the engine's own ducker
-- (engine-played ambience is ducked by engine-played sounds only). Server
-- loops reach the client without their channel: the channel rules (NPC_Looping, Vehicles_Looping) do not
-- match them.
local A = pba
local M = A.Mix or {}
A.Mix = M

M.FILE = "scripts/soundmixers.txt"
M.MAX_GROUPS = 8
M.TICK = 0.1 -- the engine's ducker period (seconds), also its ramp step
local CHAN = { CHAN_STATIC = 6, CHAN_WEAPON = 1, CHAN_VOICE = 2, CHAN_VOICE2 = 7, CHAN_BODY = 4, CHAN_ITEM = 3 }

--- Tokens of a script file: quoted strings, { and }, bare words; // comments skipped.
local function tokens(text)
	local out, i, n = {}, 1, #text
	while i <= n do
		local c = string.sub(text, i, i)
		if c == "/" and string.sub(text, i + 1, i + 1) == "/" then
			local e = string.find(text, "\n", i, true)
			i = (e or n) + 1
		elseif c == "\"" then
			local e = string.find(text, "\"", i + 1, true) or (n + 1)
			out[#out + 1] = string.sub(text, i + 1, e - 1)
			i = e + 1
		elseif c == "{" or c == "}" then
			out[#out + 1] = c
			i = i + 1
		elseif string.find(c, "%s") then
			i = i + 1
		else
			local e = string.find(text, "[%s{}\"]", i) or (n + 1)
			out[#out + 1] = string.sub(text, i, e - 1)
			i = e
		end
	end
	return out
end

local function num(s, dflt)
	if not s or s == "" then return dflt end
	return tonumber(s) or dflt
end

--- Parses a soundmixers.txt text into { rules = { {group, dir, class, chan, lmin, lmax, prio, ducked,
-- causes, duckTo, threshold} }, info = group -> its first rule, mixers = name -> { group -> value } }.
function M.Parse(text)
	local t = tokens(text or "")
	local p = 1
	local mix = { rules = {}, info = {}, mixers = {} }
	while t[p] and t[p] ~= "{" do p = p + 1 end -- "GROUPRULES"
	p = p + 1
	while t[p] and t[p] ~= "}" do
		local f = {}
		for k = 1, 11 do f[k] = t[p + k - 1] or "" end
		p = p + 11
		local r = {
			group = f[1], dir = string.lower(string.gsub(f[2], "\\", "/")), class = f[3] ~= "" and string.lower(f[3]) or nil,
			chan = f[4] ~= "" and (CHAN[string.upper(f[4])] or 0) or -1, lmin = num(f[5], -1), lmax = num(f[6], -1),
			prio = num(f[7], 50), ducked = num(f[8], 0) ~= 0, causes = num(f[9], 0) ~= 0,
			duckTo = num(f[10], 100) * 0.01, threshold = num(f[11], 100) * 0.01,
		}
		mix.rules[#mix.rules + 1] = r
		if not mix.info[r.group] then mix.info[r.group] = r end
	end
	p = p + 1
	while t[p] do
		local name = t[p]
		if name == "{" or name == "}" then p = p + 1
		else
			p = p + 1
			while t[p] == "{" do p = p + 1 end
			local values = {}
			while t[p] and t[p] ~= "}" do
				values[t[p]] = tonumber(t[p + 1] or "")
				p = p + 2
			end
			mix.mixers[name] = values
			p = p + 1
		end
	end
	return mix
end

--- Reads scripts/soundmixers.txt (the game's, as the engine does) into M.data. Returns it.
function M.Load()
	M.data = M.Parse(file.Read(M.FILE, "GAME") or "")
	M.cache = {}
	M.ver = (M.ver or 0) + 1
	return M.data
end

--- The groups of a sound, as the engine assigns them: { names = { group... } }. name: the file as played,
-- class: its source entity's class name (nil: none), chan: its channel, lvl: its level.
function M.Groups(name, class, chan, lvl)
	local data = M.data or M.Load()
	name = string.lower(string.gsub(name or "", "\\", "/"))
	class = class and string.lower(class) or nil
	chan, lvl = chan or 0, math.floor(lvl or 75)
	local key = name .. "|" .. (class or "") .. "|" .. chan .. "|" .. lvl
	local g = M.cache[key]
	if g then return g end
	-- the file name rules count only among the first 8 that match the name
	local dirOk, nDir = {}, 0
	for i, r in ipairs(data.rules) do
		if r.dir ~= "" and nDir < M.MAX_GROUPS and string.find(name, r.dir, 1, true) then
			dirOk[i] = true
			nDir = nDir + 1
		end
	end
	local names = {}
	for i, r in ipairs(data.rules) do
		local ok = r.dir == "" or dirOk[i]
		if ok and r.class then ok = class ~= nil and string.find(class, r.class, 1, true) ~= nil end
		if ok and r.chan >= 0 then ok = chan == r.chan end
		if ok and r.lmin >= 0 then ok = lvl >= r.lmin end
		if ok and r.lmax >= 0 then ok = lvl <= r.lmax end
		if ok then
			names[#names + 1] = r.group
			if #names >= M.MAX_GROUPS then break end
		end
	end
	g = { names = names }
	M.cache[key] = g
	return g
end

--- Groups of a sound from its source entity (or entity index).
function M.GroupsOf(name, ent, chan, lvl)
	if isnumber(ent) then ent = ent > 0 and Entity(ent) or nil end
	local class = ent and IsValid(ent) and not ent:IsWorld() and ent:GetClass() or nil
	return M.Groups(name, class, chan, lvl)
end

M.duck = M.duck or {}
--- Current duck of group (1 = none).
function M.DuckOf(group) return M.duck[group] or 1 end

--- Value of a sound's groups in mixer mixerName. noDuck: the mix value alone.
function M.ValueIn(g, mixerName, noDuck)
	local data = M.data or M.Load()
	local values = data.mixers[mixerName or ""] or {}
	local duck = 1
	for _, name in ipairs(g.names) do
		if not noDuck then
			local r = data.info[name]
			if r and r.ducked then duck = math.min(duck, M.duck[name] or 1) end
		end
		local v = values[name]
		if v and v >= 0 then return v * duck end
	end
	return duck
end

local cvMixer, cvNoDuck = GetConVar("snd_soundmixer"), GetConVar("snd_disable_mixer_duck")
M.mixer = M.mixer or (cvMixer and cvMixer:GetString() or "Default_Mix")

--- The gain factor of a module voice of groups g now (pba_native_mix / pba_native_duck): 1 when both off.
function M.Value(g)
	if not g then return 1 end
	local mixOn = (A.cfg.native_mix or 1) >= 0.5
	local duckOn = (A.cfg.native_duck or 1) >= 0.5 and not (cvNoDuck and cvNoDuck:GetBool())
	if not mixOn and not duckOn then return 1 end
	local mode = (mixOn and 1 or 0) + (duckOn and 2 or 0)
	if g.ver == M.ver and g.mode == mode then return g.val end
	local v
	if mixOn then v = M.ValueIn(g, M.mixer, not duckOn)
	else
		v = 1
		local data = M.data
		for _, name in ipairs(g.names) do
			local r = data.info[name]
			if r and r.ducked then v = math.min(v, M.duck[name] or 1) end
		end
	end
	g.val, g.ver, g.mode = v, M.ver, mode
	return v
end

-- ------------------------------------------------------------------ ducker
-- Sounds heard (M.Note): { g = groups, vol = engine-law volume, tEnd }. The engine sums its channels'
-- volumes; ours are noted when pba sees a sound, at the volume the engine would give it there.
M.heard = M.heard or {}
M.ramp = M.ramp or {} -- group -> target
function M.Reset()
	M.heard, M.duck, M.ramp, M.lastTick = {}, {}, {}, nil
	M.ver = (M.ver or 0) + 1
end

--- Notes a sound playing until tEnd at volume vol (0..1: volume x the engine's distance gain x its mix
-- value) for the ducker.
function M.Note(g, vol, tEnd)
	if not g or (vol or 0) <= 0 then return end
	local h = M.heard
	h[#h + 1] = { g = g, vol = vol, tEnd = tEnd }
end

local cvAttack, cvRelease = GetConVar("snd_duckerattacktime"), GetConVar("snd_duckerreleasetime")
--- One period of the ducker at time now (also run by the Think hook below).
function M.Tick(now)
	local data = M.data or M.Load()
	M.lastTick = now
	local total, anyDucked = {}, false
	local h, n = M.heard, 0
	for i = 1, #h do
		local s = h[i]
		if s.tEnd > now then
			n = n + 1
			h[n] = s
			for _, name in ipairs(s.g.names) do
				local r = data.info[name]
				if r then
					if r.causes then total[name] = (total[name] or 0) + s.vol end
					if r.ducked then anyDucked = true end
				end
			end
		end
	end
	for i = #h, n + 1, -1 do h[i] = nil end
	-- a module voice of a ducked group playing (a loop mirror: not a noted sound) lets the ducks move too
	if not anyDucked then
		for _, v in pairs(M.voice) do
			for _, name in ipairs(v.g.names) do
				local r = data.info[name]
				if r and r.ducked then anyDucked = true break end
			end
			if anyDucked then break end
		end
	end
	if not anyDucked then return end
	local changed = false
	local attack = math.max(cvAttack and cvAttack:GetFloat() or 0.5, 0.01)
	local release = math.max(cvRelease and cvRelease:GetFloat() or 2.5, 0.01)
	for name, r in pairs(data.info) do
		if r.ducked then
			local target = 1
			for other, o in pairs(data.info) do
				if o.causes and r.prio < o.prio and (total[other] or 0) > o.threshold then target = r.duckTo break end
			end
			local cur = M.duck[name] or 1
			if cur ~= target then
				local step = (1 - r.duckTo) * (M.TICK / (cur > target and attack or release))
				if cur > target then cur = math.max(cur - step, target) else cur = math.min(cur + step, target) end
				M.duck[name] = cur
				changed = true
			end
		end
	end
	if changed then M.ver = M.ver + 1 end
end

--- Notes a sound pba sees (data: the EntityEmitSound table, Pos set) for the ducker.
function M.NoteSound(data, L, secs)
	if (A.cfg.native_duck or 1) < 0.5 or not (data and data.SoundName and data.Pos and L) then return end
	local lvl = data.SoundLevel or 75
	local g = M.GroupsOf(data.SoundName, data.Entity or data.EntIndex, data.Channel, lvl)
	local vol = (data.Volume or 1) * math.min(A.AC.EngineGain(math.max(data.Pos:Distance(L), 1), lvl), 1) * M.ValueIn(g, M.mixer, true)
	if not isnumber(secs) then secs = nil end -- (a caller passing pba.ListenerPos() straight: its 2nd value is the angle)
	M.Note(g, vol, RealTime() + (secs or A.SoundDuration(data.SoundName) or 1))
end

hook.Add("Think", "pba_mix", function()
	local now = RealTime()
	if M.lastTick and now - M.lastTick < M.TICK then return end
	-- the current mixer (a soundscape sets snd_soundmixer)
	local cur = cvMixer and cvMixer:GetString() or "Default_Mix"
	if cur ~= M.mixer then M.mixer = cur M.ver = (M.ver or 0) + 1 end
	if (A.cfg.native_duck or 1) >= 0.5 then M.Tick(now)
	else
		M.lastTick = now
		if next(M.duck) then M.duck = {} M.ver = (M.ver or 0) + 1 end
	end
end)

-- ------------------------------------------------------------------ module voices
-- Each module voice keeps its groups (M.voice[id]); its gain and reverb sends are scaled by M.Value at
-- Play and at every update, in pba_native.Play / Update / SourceReflect themselves (wrapped below, the
-- outermost layer): a mixer change or a duck reaches the voices already playing, and whatever sits above
-- (callers, tests watching the calls) sees the same unscaled values at Play and at Update.
M.voice = M.voice or {}
M.lastPlay = M.lastPlay or {}

--- pba_native.Play for a sound of groups g (same arguments after g): the wrapped Play below scales it.
function M.Play(g, ...)
	M.pending = g
	local id = pba_native.Play(...)
	M.pending = nil
	return id
end

function M.Wrap()
	if not pba_native or pba_native.pbaMixWrapped then return end
	pba_native.pbaMixWrapped = true
	local play, update, reflect, stop = pba_native.Play, pba_native.Update, pba_native.SourceReflect, pba_native.StopVoice
	pba_native.Play = function(n, pos, gain, l, m, h, pitch, loop, delay, sh, diffuse, roomSend, offset)
		local g = M.pending
		M.pending = nil
		if g and gain then
			local k = M.Value(g)
			gain = gain * k
			if roomSend then roomSend = roomSend * k end
		end
		local id = play(n, pos, gain, l, m, h, pitch, loop, delay, sh, diffuse, roomSend, offset)
		if g and id and id > 0 then M.voice[id] = { g = g, t = RealTime() } end
		local lp = M.lastPlay -- (what the module was given: tests)
		lp.id, lp.gain = id, gain
		return id
	end
	pba_native.Update = function(id, pos, gain, l, m, h, pitch, diffuse, send, sh)
		local v = M.voice[id]
		if v then
			local k = M.Value(v.g)
			v.t = RealTime()
			if gain then gain = gain * k end
			if send then send = send * k end
		end
		local ok = update(id, pos, gain, l, m, h, pitch, diffuse, send, sh)
		if not ok and v then M.voice[id] = nil end
		return ok
	end
	if reflect then
		pba_native.SourceReflect = function(id, S, send, ...)
			local v = M.voice[id]
			if v and send then send = send * M.Value(v.g) end
			return reflect(id, S, send, ...)
		end
	end
	if stop then
		pba_native.StopVoice = function(id, ...)
			M.voice[id] = nil
			return stop(id, ...)
		end
	end
end
if pba_native then M.Wrap() end
-- voices never updated (short one-shots) are forgotten after a while
timer.Create("pba_mix_gc", 10, 0, function()
	local now = RealTime()
	for id, v in pairs(M.voice) do if now - v.t > 30 then M.voice[id] = nil end end
end)
