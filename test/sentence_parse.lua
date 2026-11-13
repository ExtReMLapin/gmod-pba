-- Sentence line parser (client, lua_exec; no module needed): pba.Sentences.ParseData / ParseFile read the
-- lines of scripts/sentences.txt as the engine does (see cl_sentences.lua).
-- Pass: directory up to the last "/" ("vox/" without one), default parameter blocks carry to the following
-- words and a word's own block overrides them for that word only, a final "," or "." adds no pause while an
-- inner one adds "_comma" / "_period", {len / closecaption} commands read and removed, "V_" words flagged
-- virtual, comments and repeated names skipped, the token cap (32), and the lines of the game's
-- sentences.txt (HL2 mounted) parsed with words whose files exist for >= 95 % of the non-virtual sentences
-- (the rest: 7 lines of the file itself name missing files, e.g. COMBINE_KICK1).
local S = pba.Sentences
if not S then return { pass = false, err = "cl_sentences not loaded" } end
local res = { checks = {} }
local function chk(k, ok) res.checks[k] = ok and true or false end
local function files(d) local t = {} for i, w in ipairs(d.words) do t[i] = w.file end return table.concat(t, " ") end

local d = S.ParseData("npc/combine_soldier/vo/(v80 p110) on1 alert1(p95 e50) off1 {Len 0.77  closecaption NPC_Combine.Coord}")
chk("dir", d.dir == "npc/combine_soldier/vo/")
chk("files", files(d) == "npc/combine_soldier/vo/on1.wav npc/combine_soldier/vo/alert1.wav npc/combine_soldier/vo/off1.wav")
chk("default block", d.words[1].vol == 80 and d.words[1].pitch == 110 and d.words[3].vol == 80 and d.words[3].pitch == 110)
chk("word override", d.words[2].pitch == 95 and d.words[2].finish == 50 and d.words[2].vol == 80)
chk("override one word only", d.words[3].finish == 100)
chk("len", d.len == 0.77)
chk("caption", d.caption == "NPC_Combine.Coord")

d = S.ParseData("hello there, how are you. fine.")
chk("default dir", d.dir == "vox/")
chk("pauses", files(d) == "vox/hello.wav vox/there.wav vox/_comma.wav vox/how.wav vox/are.wav vox/you.wav vox/_period.wav vox/fine.wav")
chk("defaults", d.words[1].vol == 100 and d.words[1].pitch == -1 and d.words[1].start == 0 and d.words[1].finish == 100)

d = S.ParseData("npc/x/(v100) on2(p110) grid V_GRIDXS dash off1")
chk("virtual", d.virtual == true)
chk("no virtual", not S.ParseData("npc/x/ a b c").virtual)

d = S.ParseData("npc/x/ a (t30 v50) b c(s10 e90)")
chk("block mid-line", d.words[1].vol == 100 and d.words[2].vol == 50 and d.words[2].tc == 30 and d.words[3].start == 10 and d.words[3].finish == 90 and d.words[3].vol == 50)

local many = {}
for i = 1, 40 do many[i] = "w" .. i end
chk("token cap", #S.ParseData("x/" .. table.concat(many, " ")).words == 32)
-- (a space right after the directory is an empty first token, as in the engine: one slot less)
chk("token cap after a space", #S.ParseData("x/ " .. table.concat(many, " ")).words == 31)

local lines = S.ParseFile("// comment\nA one two\n  B x/ three\nA again\n\n")
chk("file", lines.A == "one two" and lines.B == "x/ three" and lines["//"] == nil)

-- the game's own file
local all = S.ParseFile(file.Read("scripts/sentences.txt", "GAME") or "")
local n, virt, ok, missing = 0, 0, 0, {}
for name, data in pairs(all) do
	-- (V_ lines are the word groups of virtual words, not sentences; HEV_ lines are Half-Life 1's suit voice,
	-- hl1/fvox, not mounted with HL2 alone)
	if string.sub(name, 1, 2) == "V_" or string.sub(name, 1, 4) == "HEV_" then continue end
	n = n + 1
	local def = S.ParseData(data)
	if def.virtual then virt = virt + 1
	else
		local good = #def.words > 0
		for _, w in ipairs(def.words) do
			if not file.Exists("sound/" .. w.file, "GAME") then good = false if #missing < 8 then missing[#missing + 1] = name .. ":" .. w.file end end
		end
		if good then ok = ok + 1 end
	end
end
res.sentences, res.virtual, res.allFilesFound, res.missingSample = n, virt, ok, missing
chk("game file", n > 300 and ok >= 0.95 * (n - virt))
res.fails = {}
for k, v in SortedPairs(res.checks) do if not v then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
