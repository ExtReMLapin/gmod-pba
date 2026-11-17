-- Sentences whose words were never decoded (client lua_job, native rendering on, HL2 mounted). The first play of
-- a sentence went to the engine while its words decoded on the module's worker ("pending": 251 of 300 metrocop
-- lines of a chatter on d1_trainstation_03, all of the engine's). A sentence's words are small: Sentences.Ensure
-- decodes the ones it lacks on the main thread, within pba_native_sentence_ms (12) a frame, so the first play is the
-- module's too, without a hitch when many sentences come in one frame.
-- The decoded sounds are flushed first (render restart) so every word is cold.
-- Pass: 1) 8 sentences, one per frame: every first Ensure renders (none "pending"), worst 25 ms;
-- 2) 8 sentences in one frame: the frame costs less than 40 ms (budget 12 ms + the sentence that crosses it, 119 ms for 8 unbounded)
-- (measured 26-30 ms on a loaded machine), the others are "pending", and every one is rendered within 3 s;
-- 3) pba_native_sentence_ms 0: a cold sentence is "pending" (the background way, kept optional).
local S, N = pba.Sentences, pba.Native
if not (S and N and N.render and pba_native and pba_native.LoadSentence) then
	return { pass = false, err = "native sentences unavailable" }
end
if not (pba.cfg.native_sentence_ms) then return { pass = false, err = "pba_native_sentence_ms missing" } end
local saved = { GetConVar("pba_native_sentences"):GetString(), GetConVar("pba_native_sentence_ms"):GetString() }
RunConsoleCommand("pba_native_sentences", "1")
RunConsoleCommand("pba_native_sentence_ms", "12")
job:wait(function() return (pba.cfg.native_sentences or 0) >= 0.5 and pba.cfg.native_sentence_ms == 12 end, 5)
S.Get("")
local names = {}
for name in SortedPairs(S.lines) do
	if #names >= 24 then break end
	local def = string.sub(name, 1, 2) ~= "V_" and string.sub(name, 1, 4) ~= "HEV_" and S.Get(name)
	if def and not def.virtual and #def.words > 0 then
		local all = true
		for _, w in ipairs(def.words) do if not file.Exists("sound/" .. w.file, "GAME") then all = false break end end
		if all then names[#names + 1] = name end
	end
	job:step()
end
local function flush()
	N.StopRender()
	N.StartRender()
	job:wait(function() return N.render end, 10)
	for _, n in ipairs(names) do S.failed[n] = nil end
end
local res = { checks = {}, names = #names }
res.checks.enough = #names >= 24

-- 1) one per frame
flush()
local ok1, worst, bad = 0, 0, {}
for i = 1, 8 do
	local name = names[i]
	local t = SysTime()
	local r, _, why = S.Ensure("!" .. name)
	worst = math.max(worst, (SysTime() - t) * 1000)
	if r then ok1 = ok1 + 1 else bad[#bad + 1] = name .. ":" .. tostring(why or S.lastWhy) end
	job:frames(1)
end
res.spread = { rendered = ok1, worstMs = worst, bad = bad }
res.checks.spreadRenders = ok1 == 8
res.checks.spreadWorst = worst < 25

-- 2) a burst in one frame
flush()
local t0 = SysTime()
local pend, done = 0, {}
for i = 9, 16 do
	local r, _, why = S.Ensure("!" .. names[i])
	if r then done[names[i]] = true elseif why == "pending" then pend = pend + 1 end
end
local ms = (SysTime() - t0) * 1000
res.burst = { ms = ms, pending = pend, renderedAtOnce = 8 - pend }
res.checks.burstBounded = ms < 40
res.checks.burstPending = pend > 0 -- (the budget was spent: some went to the background)
local tEnd = SysTime() + 3
while SysTime() < tEnd do
	local left = 0
	for i = 9, 16 do
		if not done[names[i]] then
			if S.Ensure("!" .. names[i]) then done[names[i]] = true else left = left + 1 end
		end
	end
	if left == 0 then break end
	job:frames(1)
end
local n = 0
for _ in pairs(done) do n = n + 1 end
res.burst.rendered = n
res.checks.burstAllRender = n == 8

-- 3) budget 0: the background way
RunConsoleCommand("pba_native_sentence_ms", "0")
job:wait(function() return pba.cfg.native_sentence_ms == 0 end, 5)
flush()
local r0, _, why0 = S.Ensure("!" .. names[17])
res.zero = { rendered = r0, why = why0 }
res.checks.zeroIsPending = not r0 and why0 == "pending"

RunConsoleCommand("pba_native_sentences", saved[1])
RunConsoleCommand("pba_native_sentence_ms", saved[2])
res.fails = {}
for k, v in SortedPairs(res.checks) do if not v then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
