-- Sentences rendered by the native module (client lua_job, native rendering on, HL2 mounted): the words of
-- a sentence (scripts/sentences.txt) assembled into one sound by pba_native.LoadSentence, then played by a
-- voice like any file (cl_sentences.lua).
-- The engine's own {len} of a line is a rough value per group (COMBINE_ANSWER0: 1.57 s for 0.57 s of words),
-- so the reference is the sum of the words' lengths (SoundDuration), cut and pitched as the line says.
-- Pass: 20 sentences rendered (no virtual word, every file present), each within 2 % + 20 ms of that sum
-- (cuts move to a zero crossing); A.SoundDuration gives the rendered length; a voice plays one; with
-- pba_native_sentences 0 none is rendered. Red with a module without LoadSentence.
local N, S = pba.Native, pba.Sentences
if not (N and N.render) then return { pass = false, err = "native renderer not running" } end
if not S then return { pass = false, err = "cl_sentences not loaded" } end
if not pba_native.LoadSentence then return { pass = false, err = "module without LoadSentence (install the new DLL)" } end
local saved = GetConVar("pba_native_sentences"):GetString()
RunConsoleCommand("pba_native_sentences", "1")
job:wait(function() return (pba.cfg.native_sentences or 0) >= 0.5 end, 5)
local function expected(d)
	local sum = 0
	for _, w in ipairs(d.words) do
		local du = SoundDuration(w.file)
		if not du or du <= 0 then return nil end
		local s0 = (w.start > 0 and w.start < 100) and w.start or 0
		local e0 = (w.finish > w.start and w.finish < 100) and w.finish or 100
		sum = sum + du * (e0 - s0) / 100 / (w.pitch > 0 and w.pitch / 100 or 1)
	end
	return sum
end
local res = { checks = {}, bad = {} }
local names = {}
for name in SortedPairs(S.ParseFile(file.Read("scripts/sentences.txt", "GAME") or "")) do
	if string.sub(name, 1, 2) ~= "V_" and string.sub(name, 1, 4) ~= "HEV_" then names[#names + 1] = name end
end
local done, good, first = 0, 0, nil
for _, name in ipairs(names) do
	if done >= 20 then break end
	local d = S.Get(name)
	local want = d and not d.virtual and expected(d)
	if want then
		S.failed[string.upper(name)] = nil
		local ok, key, why
		job:wait(function() ok, key, why = S.Ensure("!" .. name) return ok or why ~= "pending" end, 10)
		done = done + 1
		local got = ok and S.len[string.upper(name)]
		if got and math.abs(got - want) <= 0.02 * want + 0.02 then good = good + 1 first = first or name
		elseif #res.bad < 6 then res.bad[#res.bad + 1] = string.format("%s got %s want %.3f", name, tostring(got), want) end
	end
	job:step()
end
res.rendered, res.withinTolerance = done, good
res.checks.lengths = done == 20 and good == 20
res.checks.soundDuration = first ~= nil and math.abs((pba.SoundDuration("!" .. first) or 0) - S.len[string.upper(first)]) < 1e-6
local L = pba.ListenerPos()
local id = first and L and N.PlayVoice("!" .. first, L + Vector(100, 0, 0), 0.01, 0, 100, { noRoom = true })
res.checks.plays = id and id > 0 or false
if id then pba_native.StopVoice(id) end
RunConsoleCommand("pba_native_sentences", "0")
job:wait(function() return (pba.cfg.native_sentences or 1) < 0.5 end, 5)
res.checks.optionOff = first ~= nil and not S.Ensure("!" .. first)
RunConsoleCommand("pba_native_sentences", saved)
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
