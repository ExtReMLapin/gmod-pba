-- Sentences with virtual words rendered by the module (client lua_job, native rendering on, the module with
-- LoadSentence, HL2 mounted): every sentence of the game's files with a "V_" word (a token starting with
-- it: "HEV_logon" is not one) is emitted once as a speaker 200 units away would (pba.SentenceVirtual.Begin,
-- as A.Process does), then rendered (pba.Sentences.Ensure, waiting while words decode).
-- Pass: at least 95 % of them rendered by the module (before: none, they all went to the engine; measured
-- 153 of 154: METROPOLICE_HIT_BY_PHYSOBJECT3 has no directory in the game's file, its words point at vox/
-- where they do not exist, for the engine too), a speaker's two lines name it the same, and the rendered
-- length is the sum of its words.
local S, V, N = pba.Sentences, pba.SentenceVirtual, pba.Native
if not (S and N and N.render and pba_native and pba_native.LoadSentence) then
	return { pass = false, err = "native sentences unavailable" }
end
local res = { checks = {} }
local function chk(k, ok) res.checks[k] = ok and true or false end
S.Get("")
local names = {}
for name, data in SortedPairs(S.lines) do
	local def = string.sub(name, 1, 2) ~= "V_" and S.Get(name)
	if def and def.virtual then names[#names + 1] = name end
end
res.total = #names
local L = LocalPlayer():EyePos()
local Spos = L + Vector(200, 0, 0)
local function render(name, src)
	local data = { SoundName = "!" .. name, EntIndex = src }
	if V then V.Begin(data, Spos, L) end
	local ok
	for _ = 1, 400 do
		local why
		ok, _, why = S.Ensure("!" .. name)
		if ok or why ~= "pending" then break end
		job:frames(1)
	end
	return ok
end
local okN, failed = 0, {}
for i, name in ipairs(names) do
	if render(name, 1000 + i) then okN = okN + 1 elseif #failed < 8 then failed[#failed + 1] = name end
	job:progress(i, #names, name)
	job:step()
end
res.rendered, res.failedSample = okN, failed
chk("share", okN >= 0.95 * #names)
-- one speaker, two lines naming it: the same name word
if V then
	local cur = S.current or {}
	render("COMBINE_ANNOUNCE0", 77)
	local a = cur.COMBINE_ANNOUNCE0 and cur.COMBINE_ANNOUNCE0.words
	render("COMBINE_ANNOUNCE0", 77)
	local b = cur.COMBINE_ANNOUNCE0 and cur.COMBINE_ANNOUNCE0.words
	local function names_(w) local t = {} for k, x in ipairs(w or {}) do t[k] = x.file end return table.concat(t, " ") end
	res.announce = names_(a)
	chk("sameSpeaker", a and b and names_(a) == names_(b))
	-- rendered length = sum of the words' durations (no gaps)
	local sum = 0
	for _, w in ipairs(a or {}) do
		if file.Exists("sound/" .. w.file, "GAME") then sum = sum + SoundDuration(w.file) end
	end
	res.len, res.sum = S.len.COMBINE_ANNOUNCE0, sum
	chk("length", res.len and sum > 0 and math.abs(res.len - sum) < 0.02 * sum + 0.01)
else
	chk("sameSpeaker", false)
end
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
