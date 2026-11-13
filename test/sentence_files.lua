-- Sentence files (client, lua_exec; no module needed): the engine reads scripts/sentences.txt THEN
-- scripts/sentences-hl1.txt (Half-Life: Source's lines), the first definition of a name winning
-- (observed in GMod's engine.dll). pba.Sentences.FILES lists them in that order and S.ParseFiles merges
-- texts in order, first wins.
-- Pass: the two files in the engine's order, a name only in the second text found, a name in both taken
-- from the first, and S.Get resolving through the merged table.
local S = pba.Sentences
if not S then return { pass = false, err = "cl_sentences not loaded" } end
local res = { checks = {} }
local function chk(k, ok) res.checks[k] = ok and true or false end
chk("order", istable(S.FILES) and S.FILES[1] == "scripts/sentences.txt" and S.FILES[2] == "scripts/sentences-hl1.txt")
if isfunction(S.ParseFiles) then
	local m = S.ParseFiles({ "A_ONE vox/a b\nBOTH vox/first", "B_TWO vox/c d\nBOTH vox/second" })
	chk("secondFile", m.B_TWO == "vox/c d")
	chk("firstWins", m.BOTH == "vox/first")
	chk("firstFile", m.A_ONE == "vox/a b")
	local savedLines, savedDefs = S.lines, S.defs
	S.lines, S.defs = m, {}
	local d = S.Get("b_two")
	S.lines, S.defs = savedLines, savedDefs
	chk("get", d ~= nil)
else
	chk("parseFiles", false)
end
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
