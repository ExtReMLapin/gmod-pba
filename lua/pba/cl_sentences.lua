-- pba: sentences (scripts/sentences.txt) rendered by the native module.
-- Copyright (C) 2026 pba contributors. Licensed under the GNU GPL v3 or later (see LICENSE).
--
-- A sentence ("!NAME": Combine and metrocop radio, HL2 NPC chatter) is not a file: the engine reads its
-- line in scripts/sentences.txt and plays its words one after the other. pba left them to the engine
-- (EmitSentence: muffled by a DSP preset, no HRTF, no native reverb). With pba_native_sentences the line is
-- read here, the words are decoded by the module and rendered once into one sound (pba_native.LoadSentence),
-- which a voice then plays like any file. The format, as the engine reads it:
--   NAME [dir/]word word(params) (params) word, word. {len 1.2 closecaption TOKEN}
-- * the line's name ends at the first space; lines starting with "/" are comments; the first line of a
--   name wins;
-- * {...} blocks are commands (length, caption), not words;
-- * the directory of the words is everything up to the LAST "/" of the line ("vox/" without one); a word
--   is the file <dir><word>.wav;
-- * words end at a space, "," or "." ; a "," or "." that is not the last character adds a pause, the
--   word "_comma" or "_period" of the same directory (silence files);
-- * (v p s e t) parameters right after a word apply to that word; a block standing alone sets the
--   defaults of the following words (reset at the start of the line): v volume %, p pitch %, s / e start /
--   end % of the word, t time compression (no effect in the engine's mixer: ignored);
-- * at most 32 tokens (words, pauses and parameter blocks) are read;
-- * "V_..." words are virtual: replaced by the engine with per-entity names, numbers, distances, grid
--   positions, sectors... kept in its own state. A sentence with one is left to the engine.
local A = pba
local S = A.Sentences or {}
A.Sentences = S

local MAX_TOKENS = 32
S.len = S.len or {}       -- NAME (upper) -> seconds of the rendered sentence
S.failed = S.failed or {} -- NAME -> RealTime() of a failed rendering (retried after 30 s)

--- Parameters in a "(...)" block (the part between the brackets) into p (a copy of the defaults).
local function readParams(block, p)
	local i, n = 1, #block
	while i <= n do
		local c = string.sub(block, i, i)
		if c == "v" or c == "p" or c == "s" or c == "e" or c == "t" then
			local digits = string.match(block, "^%d+", i + 1)
			if not digits then break end -- (a command letter not followed by a number ends the block)
			local v = tonumber(string.sub(digits, 1, 7))
			if c == "v" then p.vol = v elseif c == "p" then p.pitch = v elseif c == "s" then p.start = v
			elseif c == "e" then p.finish = v else p.tc = v end
			i = i + 1 + #digits
		else
			i = i + 1
		end
	end
	return p
end

local function copy(p) return { vol = p.vol, pitch = p.pitch, start = p.start, finish = p.finish, tc = p.tc } end

--- Parses the data of a sentence line (what follows its name). Returns { dir, words = { { file, vol,
-- pitch, start, finish, tc } }, virtual = true when a word is "V_...", len, caption }.
function S.ParseData(data)
	local def = { words = {} }
	-- commands: {len X closecaption TOKEN}
	data = string.gsub(data, "{([^}]*)}?", function(cmd)
		local len = string.match(string.lower(cmd), "len%s+([%d%.]+)")
		if len then def.len = tonumber(len) end
		local cap = string.match(cmd, "[Cc][Ll][Oo][Ss][Ee][Cc][Aa][Pp][Tt][Ii][Oo][Nn]%s+([^%s}]+)")
		if cap then def.caption = cap end
		return ""
	end)
	data = string.gsub(data, "%s+$", "")
	-- directory: up to the last "/"
	local slash = string.match(data, "^.*()/")
	local dir, text
	if slash then dir, text = string.sub(data, 1, slash), string.sub(data, slash + 1)
	else dir, text = "vox/", data end
	def.dir = dir
	-- tokens: a word ends at " ", ",", "." ; "(" opens parameters closed by ")"; a "," or "." not last
	-- adds a pause token
	local tokens = {}
	local i, n = 1, #text
	while i <= n and #tokens < MAX_TOKENS do
		local j = i
		local c = string.sub(text, j, j)
		while j <= n and not string.find(c, "[ ,%.%({]") do j = j + 1 c = string.sub(text, j, j) end
		if c == "(" or c == "{" then
			local close = string.find(text, c == "(" and ")" or "}", j, true)
			j = (close or n) + 1
			c = string.sub(text, j, j)
		end
		tokens[#tokens + 1] = string.sub(text, i, j - 1)
		if j > n then break end
		if (c == "." or c == ",") and j < n and #tokens < MAX_TOKENS then
			tokens[#tokens + 1] = c == "." and "_period" or "_comma"
		end
		j = j + 1
		while j <= n and string.find(string.sub(text, j, j), "[ ,%.]") do j = j + 1 end
		i = j
	end
	def.tokens = tokens
	def.words, def.virtual = S.Words(dir, tokens)
	return def
end

--- Words of a sentence from its tokens (the engine reads the parameters after replacing the virtual words,
-- cl_sentences_virtual): { { file, vol, pitch, start, finish, tc } }, and true when a word is "V_...".
function S.Words(dir, tokens)
	local words, virtual = {}, false
	-- parameters: a block after a word is that word's; a block alone becomes the default
	local dflt = { vol = 100, pitch = -1, start = 0, finish = 100, tc = 0 }
	for _, tok in ipairs(tokens) do
		local p = copy(dflt)
		local word = tok
		if string.sub(tok, -1) == ")" then
			local open = string.find(tok, "(", 1, true)
			if open then
				word = string.sub(tok, 1, open - 1)
				readParams(string.sub(tok, open + 1, -2), p)
			end
		end
		if word == "" then
			if string.sub(tok, -1) == ")" then dflt = p end -- a parameter block alone
		else
			if string.sub(word, 1, 2) == "V_" then virtual = true end
			words[#words + 1] = { file = string.lower(dir .. word .. ".wav"), vol = p.vol, pitch = p.pitch,
				start = p.start, finish = p.finish, tc = p.tc }
		end
	end
	return words, virtual
end

--- Parses a whole sentences file into NAME (upper) -> line data (the first line of a name wins).
function S.ParseFile(text)
	local lines = {}
	for line in string.gmatch(text, "[^\r\n]+") do
		line = string.gsub(line, "^[\t ]+", "")
		if line ~= "" and string.sub(line, 1, 1) ~= "/" then
			local name, data = string.match(line, "^([^ ]+) ?(.*)$")
			if name then
				name = string.upper(name)
				if not lines[name] then lines[name] = data end
			end
		end
	end
	return lines
end

--- The sentence files, in the engine's order (GMod's engine reads Half-Life: Source's lines after HL2's).
S.FILES = { "scripts/sentences.txt", "scripts/sentences-hl1.txt" }

--- Merges the texts of several sentence files, in order: the first definition of a name wins.
function S.ParseFiles(texts)
	local lines = {}
	for _, text in ipairs(texts) do
		for name, data in pairs(S.ParseFile(text)) do
			if not lines[name] then lines[name] = data end
		end
	end
	return lines
end

--- The definition of sentence NAME (without "!"), parsed on first use; nil if unknown.
function S.Get(name)
	if not S.lines then
		local texts = {}
		for i, f in ipairs(S.FILES) do texts[i] = file.Read(f, "GAME") or "" end
		S.lines = S.ParseFiles(texts)
		S.defs = {}
	end
	name = string.upper(name)
	local d = S.defs[name]
	if d == nil then
		local data = S.lines[name]
		d = data and S.ParseData(data) or false
		S.defs[name] = d
	end
	return d or nil
end

--- True when sentences may be rendered by the module (option on, a module that has LoadSentence).
function S.On()
	local N = A.Native
	return (A.cfg.native_sentences or 1) >= 0.5 and N and N.render and pba_native and pba_native.LoadSentence and true or false
end

--- Makes sure the module has rendered sentence `name` ("!NAME"). Returns true, key when playable natively;
-- false, nil, "pending" while a word decodes; false when it is the engine's (virtual words, a word the
-- module cannot decode, unknown sentence).
function S.Ensure(name)
	if not S.On() then return false end
	local sub = string.upper(string.sub(name, 2))
	local key = "!" .. string.lower(sub)
	local words, fkey = nil, sub
	-- virtual words ("V_..."): the words picked for the sound being played (cl_sentences_virtual, at
	-- emission), rendered under their own key; without them (option off, no emission seen): the engine's
	local cur = S.current and S.current[sub]
	if cur then key, words, fkey = cur.key, cur.words, cur.key end
	if pba_native.HasSound(key) then
		if cur then S.len[sub] = S.len[cur.key] end
		return true, key
	end
	local f = S.failed[fkey]
	if f and RealTime() - f < 30 then return false end
	local def = S.Get(sub)
	if not def or #def.words == 0 or (def.virtual and not cur) then S.failed[sub] = math.huge return false end
	words = words or def.words
	if #words == 0 then S.failed[fkey] = math.huge return false end
	local flat, want = {}, 0
	for _, w in ipairs(words) do
		-- a word without a file is skipped, as the engine does; one the module cannot decode: engine
		if file.Exists("sound/" .. w.file, "GAME") then
			local ok, _, why = A.Native.EnsureSound(w.file)
			if not ok then
				if why == "pending" then return false, nil, "pending" end
				S.failed[fkey] = RealTime()
				return false
			end
			want = want + 1
		end
		local k = #flat
		flat[k + 1], flat[k + 2], flat[k + 3], flat[k + 4], flat[k + 5] = w.file, w.vol, w.pitch, w.start, w.finish
	end
	if want == 0 then S.failed[fkey] = RealTime() return false end
	local ok, secs, used = pcall(pba_native.LoadSentence, key, flat)
	-- (a word evicted meanwhile: retried later rather than played without it)
	if not ok or not secs or (used or 0) < want then
		S.failed[fkey] = RealTime()
		return false
	end
	S.len[sub] = secs
	if cur then
		S.len[cur.key] = secs
		A.stats.sentencesVirtual = (A.stats.sentencesVirtual or 0) + 1
	end
	A.stats.sentencesNative = (A.stats.sentencesNative or 0) + 1
	return true, key
end

--- Seconds sentence `name` ("!NAME") plays at pitch 100 as the module renders it (nil: not rendered by the
-- module; then the engine's own {len} applies, A.SoundDuration).
function S.Length(name)
	local sub = string.upper(string.sub(name, 2))
	if S.len[sub] then return S.len[sub] end
	if S.Ensure(name) then return S.len[sub] end
	return nil
end
