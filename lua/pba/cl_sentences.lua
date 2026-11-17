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
S.failWhy = S.failWhy or {} -- NAME -> why it failed (S.Note)

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

--- True when NAME (upper) is a group: some line is called NAME followed by a number ("HG_ALERT" for
-- HG_ALERT0, HG_ALERT1...).
function S.Group(name)
	S.Get("")
	if not S.groups then
		S.groups = {}
		for n in pairs(S.lines) do
			local base = string.match(n, "^(.-)%d+$")
			if base and base ~= "" then S.groups[base] = true end
		end
	end
	return S.groups[string.upper(name)] or false
end

--- True when sentences may be rendered by the module (option on, a module that has LoadSentence).
function S.On()
	local N = A.Native
	return (A.cfg.native_sentences or 1) >= 0.5 and N and N.render and pba_native and pba_native.LoadSentence and true or false
end

-- What was left to the engine, and why (S.Note, one count per voice asked of the module): the ledger behind
-- pba_sentences_report. Reasons: off (option off), unknown (no such line), group (the name is a group
-- of lines, not a line), empty (no word), virtual (a "V_" word and none picked for this sound), cut (a
-- virtual word that ended the line), pending (a word still decoding: the engine's that once), word (a word the
-- module cannot decode), nofile (none of the words exists: the engine plays nothing either), load (the module
-- refused the assembled sentence); an earlier failure keeps its reason for 30 s. Before the module is asked:
-- norender (no native rendering), owndsp (a preset of its own), notall (clear sight without pba_native_all),
-- far (past lod_dist), quiet (too quiet to matter), inaudible (a voice under the emission threshold).
S.stats = S.stats or { emitted = 0, native = 0, engine = 0, why = {}, names = {} }

--- Notes the verdict of a voice asked for sentence `name` ("!NAME"): ok = rendered by the module, else why.
function S.Note(name, ok, why)
	local st = S.stats
	local sub = string.upper(string.sub(name, 2))
	local n = st.names[sub]
	if not n then n = { native = 0, engine = 0, why = {} } st.names[sub] = n end
	if ok then
		st.native, n.native = st.native + 1, n.native + 1
	else
		why = why or S.lastWhy or "other"
		st.engine, n.engine = st.engine + 1, n.engine + 1
		st.why[why], n.why[why] = (st.why[why] or 0) + 1, (n.why[why] or 0) + 1
	end
end

--- Why the module does not take a sentence of DSP preset dsp before asking it (see S.Note); clear: a sentence in
-- clear sight (needs pba_native_all too).
function S.WhyNot(dsp, clear)
	local N = A.Native
	if not (N and N.render) then return "norender" end
	if not S.On() then return "off" end
	if A.OwnDSP(dsp) then return "owndsp" end
	if clear and (A.cfg.native_all or 1) < 0.5 then return "notall" end
	return "other"
end

--- Forgets the ledger (a test, a new measurement).
function S.ResetStats() S.stats = { emitted = 0, native = 0, engine = 0, why = {}, names = {} } end

--- Makes sure the module has rendered sentence `name` ("!NAME"). Returns true, key when playable natively;
-- false, nil, "pending" while a word decodes; false when it is the engine's (virtual words, a word the
-- module cannot decode, unknown sentence). S.lastWhy says why (see S.Note).
function S.Ensure(name)
	local function no(why, fkey, at)
		S.lastWhy = why
		if fkey then S.failed[fkey], S.failWhy[fkey] = at, why end
		return false
	end
	if not S.On() then return no("off") end
	local sub = string.upper(string.sub(name, 2))
	local key = "!" .. string.lower(sub)
	local words, fkey = nil, sub
	-- virtual words ("V_..."): the words picked for the sound being played (cl_sentences_virtual, at
	-- emission), rendered under their own key; without them (option off, no emission seen): the engine's
	local cur = S.current and S.current[sub]
	if cur then key, words, fkey = cur.key, cur.words, cur.key end
	if pba_native.HasSound(key) then
		if cur then S.len[sub] = S.len[cur.key] end
		S.lastWhy = nil
		return true, key
	end
	local f = S.failed[fkey]
	if f and RealTime() - f < 30 then S.lastWhy = S.failWhy[fkey] or "failed" return false end
	local def = S.Get(sub)
	if not def then return no(S.Group(sub) and "group" or "unknown", sub, math.huge) end
	if #def.words == 0 then return no("empty", sub, math.huge) end
	if def.virtual and not cur then return no("virtual", sub, math.huge) end
	words = words or def.words
	if #words == 0 then return no("cut", fkey, math.huge) end
	local flat, want = {}, 0
	-- the words not decoded yet are decoded here, on the main thread, within pba_native_sentence_ms a frame (a word is
	-- small: a sentence waiting for its words went to the engine the first time, 18 of 26 on a Combine chatter);
	-- what is past the budget decodes on the worker, and the sentence is the engine's that once
	local fr = FrameNumber()
	if S.frame ~= fr then S.frame, S.spentMs = fr, 0 end
	local budget = A.cfg.native_sentence_ms or 12
	for _, w in ipairs(words) do
		-- a word without a file is skipped, as the engine does; one the module cannot decode: engine
		if file.Exists("sound/" .. w.file, "GAME") then
			local now = S.spentMs < budget
			local t = SysTime()
			local ok, _, why = A.Native.EnsureSound(w.file, now)
			S.spentMs = S.spentMs + (SysTime() - t) * 1000
			if not ok then
				if why == "pending" then S.lastWhy = "pending" return false, nil, "pending" end
				return no("word", fkey, RealTime())
			end
			want = want + 1
		end
		local k = #flat
		flat[k + 1], flat[k + 2], flat[k + 3], flat[k + 4], flat[k + 5] = w.file, w.vol, w.pitch, w.start, w.finish
	end
	if want == 0 then return no("nofile", fkey, RealTime()) end
	local t1 = SysTime()
	local ok, secs, used = pcall(pba_native.LoadSentence, key, flat)
	S.spentMs = S.spentMs + (SysTime() - t1) * 1000
	-- (a word evicted meanwhile: retried later rather than played without it)
	if not ok or not secs or (used or 0) < want then return no("load", fkey, RealTime()) end
	S.len[sub] = secs
	if cur then
		S.len[cur.key] = secs
		A.stats.sentencesVirtual = (A.stats.sentencesVirtual or 0) + 1
	end
	A.stats.sentencesNative = (A.stats.sentencesNative or 0) + 1
	S.lastWhy = nil
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

--- The ledger as text: sentences emitted, rendered by the module, left to the engine with the reasons, and the
-- names left to the engine most often.
function S.Report()
	local st = S.stats
	local out = { string.format("sentences: %d emitted, %d voices rendered by the module, %d left to the engine", st.emitted, st.native, st.engine) }
	local whys = {}
	for why, n in pairs(st.why) do whys[#whys + 1] = { why, n } end
	table.sort(whys, function(a, b) return a[2] > b[2] end)
	for _, w in ipairs(whys) do out[#out + 1] = string.format("  engine, %s: %d", w[1], w[2]) end
	local names = {}
	for name, n in pairs(st.names) do if n.engine > 0 then names[#names + 1] = { name, n } end end
	table.sort(names, function(a, b) return a[2].engine > b[2].engine end)
	for i = 1, math.min(#names, 15) do
		local why = {}
		for k, c in pairs(names[i][2].why) do why[#why + 1] = k .. " x" .. c end
		out[#out + 1] = string.format("  %s: %d engine (%s), %d native", names[i][1], names[i][2].engine, table.concat(why, ", "), names[i][2].native)
	end
	return table.concat(out, "\n")
end

concommand.Add("pba_sentences_report", function() MsgN(S.Report()) end)
