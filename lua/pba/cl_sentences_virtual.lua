-- pba: the virtual words ("V_...") of sentences, replaced in Lua so the module can render those sentences too.
-- Copyright (C) 2026 pba contributors. Licensed under the GNU GPL v3 or later (see LICENSE).
--
-- A Combine or metrocop radio line names its speaker ("V_MYNAMES" -> "leader"), counts ("V_SEQG0_NBRP"),
-- gives a range or a bearing ("V_DISTS", "V_DIRS")... The engine replaces those words when it plays the
-- sentence, from a state it keeps (who is called what, which global word is current). That state is not
-- reachable from Lua, and reading the engine's memory would break with every game update and differ on
-- Linux, so the rules are applied here again, with pba's own state. They are the engine's, as GMod's own
-- engine.dll applies them (checked there):
-- * the type of a virtual word is its last character ("S" Combine soldier, "P" metrocop);
-- * a group is every sentence named <group><number>; its "word" is the first word of the line. A random
--   pick takes the members in a shuffled order and reshuffles once all are used; a pick by index stops on
--   the group's last member;
-- * V_MYNAME / V_MYNUM: one name and one number per speaker (entity) and type, picked on first use;
-- * V_RND...: a random member of the group named by the word;
-- * V_DIST: the source-listener distance in metres (units x 0.0254, at most 900), digit by digit
--   (hundreds, tens, ones; the leading zeros dropped) from V_NUMBERS<type>;
-- * V_DIR: the bearing from the source to the listener (yaw, 0-359 degrees) in number words
--   (V_NUMBERS<type>: 0-19 by index, 20-90 at 18 + tens, 100-300 at 27 + hundreds);
-- * V_GRIDX / V_GRIDY: the listener's x / y in 10 m cells modulo 20 ((x + 16384) x 0.00254), digits;
-- * V_SECTOR: a sector number shared by everyone, started at random (0-19) and moved on by one every
--   snd_vox_sectimetout seconds (300; after 20 it goes back to 1);
-- * V_G0_ .. V_G3_: one random word per type and slot, shared by every speaker of the type, picked again
--   when snd_vox_globaltimeout (300 s) has passed since it was picked;
-- * V_SEQG0_ .. V_SEQG3_: the next word of the group per type and slot, back to the first after half of
--   snd_vox_seqtimetout (150 s) without use;
-- * "_MAP__" in a word becomes the index of the map (two digits): the first V_MAPNAME member that is part
--   of the map's name, 0 when none is;
-- * V_IDIED: silent; marks the speaker dead. V_WHODIED: the name and number of the last speaker of the
--   type marked dead (nothing when none);
-- * a group member that does not exist ends the sentence at that word; an unknown "V_" word stays as it
--   is (no file: skipped); 32 tokens at most;
-- * engine quirks kept: the word after a V_IDIED marker (or after an unmatched V_WHODIED) is never itself
--   replaced; a sequential pick never wraps (it stays on the last member until it expires); 64 speakers
--   remembered at most, the oldest slot reused first.
-- Limits (accepted, "good enough"):
-- * pba's picks are not the engine's: names and numbers, V_RND words, globals, the starting sector differ
--   from what the engine would have said (nobody hears both: the sentence is played by one of them);
-- * pba's memory is separate from the engine's: a speaker can change name when some of its lines go back
--   to the engine (a word missing or not decodable, the option turned off in a game);
-- * multiplayer: each client picks its own words, as each client's engine does in vanilla;
-- * nothing is saved with the game (neither does the engine);
-- * V_IDIED / V_WHODIED only work when the death lines are played by pba too.
-- Differences found in GMod's engine.dll against the older public sources: none in these rules (the
-- "_MAP__" index is written in place, so map-relative groups work, which a version with a truncating copy
-- would not).
local A = pba
if A.JitFile then A.JitFile("cl_sentences_virtual") end -- LuaJIT per file: pba_lua_interp (sh_config.lua)
local V = A.SentenceVirtual or {}
A.SentenceVirtual = V

local SLOTS = 64
local MAX_TOKENS = 32
local sub, find, upper = string.sub, string.find, string.upper

--- Seconds of an engine sound convar (its default when Lua cannot read it).
local function timeout(name, dflt)
	local c = GetConVar(name)
	local v = c and c:GetInt()
	return (v and v > 0) and v or dflt
end

--- State back to empty. lines: name (upper) -> line data to use instead of the game's sentences (tests).
function V.Reset(lines)
	V.lines = lines
	V.groups = nil       -- group name -> member count
	V.bags = {}          -- group name -> shuffled member order (false: used)
	V.slots = {}         -- [0..63] speakers: { type, src, name, num, glob, tglob, iseq, tseq, died, tdied }
	V.last = 0
	V.sector, V.sectorT = -1, 0
end
if not V.slots then V.Reset() end

local function lines()
	if V.lines then return V.lines end
	local S = A.Sentences
	S.Get("")
	return S.lines or {}
end

--- Group sizes: every sentence name ending in a number belongs to the group named by what precedes it.
local function groups()
	if V.groups then return V.groups end
	local g = {}
	for name in pairs(lines()) do
		local base = string.match(name, "^(.-)%d+$")
		if base and base ~= "" then g[base] = (g[base] or 0) + 1 end
	end
	V.groups = g
	return g
end

--- The word a group member stands for: the first word of its line ({...} commands removed); nil when the
-- member does not exist.
local function memberWord(group, i)
	local data = lines()[group .. i]
	if not data then return nil end
	data = string.gsub(data, "{[^}]*}?", "")
	return string.match(data, "^%s*([^%s]+)")
end

--- Random member of a group, least recently used first.
local function rnd(group)
	group = upper(group)
	local n = groups()[group]
	if not n or n == 0 then return nil end
	local bag = V.bags[group]
	for _ = 1, 2 do
		if bag then
			for k = 1, n do
				if bag[k] then
					local i = bag[k]
					bag[k] = false
					return memberWord(group, i)
				end
			end
		end
		bag = {}
		for k = 1, n do bag[k] = k - 1 end
		for _ = 1, n * 4 do
			local a, b = math.random(1, n), math.random(1, n)
			bag[a], bag[b] = bag[b], bag[a]
		end
		V.bags[group] = bag
	end
	return nil
end

--- Member `i` of a group (stops on the last one) and the index after it.
local function byIndex(group, i)
	group = upper(group)
	local n = groups()[group]
	if not n or n == 0 then return nil, 0 end
	if i >= n then i = n - 1 end
	return memberWord(group, i), i + 1
end

local function number(t, i) return (byIndex("V_NUMBERS" .. t, i)) end

--- Slot of speaker src of type t (marked alive again); a new one (the oldest reused) when alloc is set.
local function slotOf(t, src, alloc)
	for i = 0, SLOTS - 1 do
		local s = V.slots[i]
		if s and s.type == t and s.src == src then
			s.died = false
			return s
		end
	end
	if not alloc then return nil end
	V.last = V.last + 1
	if V.last >= SLOTS then V.last = 0 end
	local s = { type = t, src = src, glob = {}, tglob = {}, iseq = {}, tseq = {}, died = false, tdied = 0 }
	V.slots[V.last] = s
	return s
end

--- Digits of n (0-999): ones; tens when there are tens or hundreds; hundreds. Spoken hundreds first.
local function digits(t, n)
	local h, te, o = math.floor(n / 100), math.floor(n % 100 / 10), n % 10
	if h > 0 then return { number(t, h), number(t, te), number(t, o) } end
	if te > 0 then return { number(t, te), number(t, o) } end
	return { number(t, o) }
end

--- n (0-999) in number words, the engine's way (V_NUMBERS: 0-19, 20-90 at 18 + tens, 100-300 at 27 +
-- hundreds); 0 says nothing.
local function numberWords(t, n)
	local h, te, o = math.floor(n / 100), math.floor(n % 100 / 10), n % 10
	local out = {}
	if h > 0 then
		if te == 0 and o == 0 then
			-- (above 300 the engine counts three words but keeps two: its own "zero zero")
			if h <= 3 then return { number(t, 27 + h) } end
			return { number(t, 0), number(t, 0) }
		end
		if te == 0 then
			if h <= 3 then return { number(t, 27 + h), number(t, o) } end
			return { number(t, h), number(t, 0), number(t, o) }
		end
		out[1] = number(t, h)
	end
	if te < 2 then
		out[#out + 1] = number(t, o + te * 10)
	else
		out[#out + 1] = number(t, te + 18)
		if o ~= 0 then out[#out + 1] = number(t, o) end
	end
	return out
end

--- Index of the map among the V_MAPNAME members (the first one its name contains), 0 when none.
local function mapIndex(map)
	local n = groups()["V_MAPNAME"] or 0
	for i = 0, n - 1 do
		local w = memberWord("V_MAPNAME", i)
		if w and find(map, w, 1, true) then return math.min(i, 99) end
	end
	return 0
end

local function globalWord(t, src, word, ig, now)
	local limit = timeout("snd_vox_globaltimeout", 300)
	for i = 0, SLOTS - 1 do
		local s = V.slots[i]
		if s and s.type == t and now - (s.tglob[ig] or 0) <= limit then
			if s.glob[ig] then return s.glob[ig] end
			break
		end
	end
	local w = rnd(word)
	local s = slotOf(t, src, true)
	s.tglob[ig], s.glob[ig] = now, w
	return w
end

local function seqWord(t, src, word, ig, now)
	local half = math.floor(timeout("snd_vox_seqtimetout", 300) / 2)
	local s
	for i = 0, SLOTS - 1 do
		local x = V.slots[i]
		if x and x.type == t then
			s = x
			if now - (x.tseq[ig] or 0) > half then x.iseq[ig] = 0 end
			break
		end
	end
	s = s or slotOf(t, src, true)
	local w, nextI = byIndex(word, s.iseq[ig] or 0)
	s.iseq[ig], s.tseq[ig] = nextI, now
	return w
end

local function sectorWord(t, word, now)
	if V.sector == -1 then V.sector = math.random(0, 19) end
	if now - V.sectorT > timeout("snd_vox_sectimetout", 300) then
		V.sector = V.sector + 1
		if V.sector > 20 then V.sector = 1 end
		V.sectorT = now
	end
	return number(t, V.sector)
end

--- The tokens of a sentence with their virtual words replaced. c = { src = speaker's entity index, S =
-- source position, L = listener position, now = CurTime(), map = map name }. Returns a new list.
function V.Resolve(tokens, c)
	local out = {}
	for i = 1, math.min(#tokens, MAX_TOKENS) do out[i] = tokens[i] end
	local i = 1
	while out[i] do
		local tok = out[i]
		if sub(tok, 1, 2) == "V_" then
			local t = sub(tok, -1)
			local w = upper(tok)
			local at = find(w, "_MAP__", 1, true)
			if at then
				local m = mapIndex(c.map or game.GetMap())
				w = sub(w, 1, at + 3) .. string.format("%02d", m) .. sub(w, at + 6)
			end
			local new, cut, skip = nil, false, false
			if find(w, "V_MYNAME", 1, true) or find(w, "V_MYNUM", 1, true) then
				local s = slotOf(t, c.src, true)
				local k = find(w, "V_MYNAME", 1, true) and "name" or "num"
				if not s[k] then s[k] = rnd(w) end
				new, cut = { s[k] }, s[k] == nil
			elseif find(w, "V_RND", 1, true) then
				local r = rnd(w)
				new, cut = { r }, r == nil
			elseif find(w, "V_DIST", 1, true) then
				local m = math.Clamp(math.floor(c.S:Distance(c.L) * 0.0254), 0, 900)
				new = digits(t, m)
			elseif find(w, "V_DIR", 1, true) then
				local yaw = math.floor((c.L - c.S):Angle().y) % 360
				new = numberWords(t, yaw)
				if #new == 0 then new = nil end
			elseif find(w, "V_IDIED", 1, true) then
				local s = slotOf(t, c.src, false)
				if not s then
					s = slotOf(t, c.src, true)
					s.name, s.num = rnd("V_MYNAME" .. t), rnd("V_MYNUM" .. t)
				end
				s.died, s.tdied = true, c.now
				table.remove(out, i)
				skip = true
			elseif find(w, "V_WHODIED", 1, true) then
				local best, bt = nil, -1
				for k = 0, SLOTS - 1 do
					local s = V.slots[k]
					if s and s.type == t and s.died and s.tdied >= bt then best, bt = s, s.tdied end
				end
				if best then
					new, cut = { best.name, best.num }, best.name == nil
				else
					table.remove(out, i)
					skip = true
				end
			elseif find(w, "V_SECTOR", 1, true) then
				local r = sectorWord(t, w, c.now)
				if r then new = { r } end
			elseif find(w, "V_GRIDX", 1, true) or find(w, "V_GRIDY", 1, true) then
				local x = find(w, "V_GRIDX", 1, true) and c.L.x or c.L.y
				new = digits(t, math.floor((x + 16384) * 0.00254) % 20)
			else
				for ig = 0, 3 do
					if find(w, "V_G" .. ig .. "_", 1, true) then
						local r = globalWord(t, c.src, w, ig, c.now)
						if r then new = { r } end
						break
					elseif find(w, "V_SEQG" .. ig .. "_", 1, true) then
						local r = seqWord(t, c.src, w, ig, c.now)
						if r then new = { r } end
						break
					end
				end
			end
			if cut then
				for k = #out, i, -1 do out[k] = nil end
				break
			end
			if new then
				out[i] = new[1]
				for k = 2, #new do
					if new[k] then table.insert(out, i + k - 1, new[k]) end
				end
				for k = #out, MAX_TOKENS + 1, -1 do out[k] = nil end
			end
			-- (the engine moves on by one after a removal: the word that took the marker's place is not
			-- looked at)
			if skip then i = i + 1 end
		end
		i = i + 1
	end
	return out
end

--- At the emission of sound `data` ("!NAME", source S, listener L): when its sentence has virtual words,
-- they are picked now for this sound (cl_sentences reads them, A.Sentences.current).
function V.Begin(data, S, L)
	local Se = A.Sentences
	if not (Se and Se.On()) then return end
	local name = upper(sub(data.SoundName or "", 2))
	local def = Se.Get(name)
	if not (def and def.virtual and def.tokens) then return end
	local e = data.Entity
	local src = IsValid(e) and e:EntIndex() or (data.EntIndex or 0)
	local tokens = V.Resolve(def.tokens, { src = src, S = S, L = L, now = CurTime(), map = game.GetMap() })
	local words = Se.Words(def.dir, tokens)
	local parts = {}
	for k, w in ipairs(words) do
		parts[k] = w.file .. ":" .. w.vol .. ":" .. w.pitch .. ":" .. w.start .. ":" .. w.finish
	end
	Se.current = Se.current or {}
	Se.current[name] = { key = "!" .. string.lower(name) .. "#" .. util.CRC(table.concat(parts, "|")), words = words }
	A.stats.sentenceResolves = (A.stats.sentenceResolves or 0) + 1
end
