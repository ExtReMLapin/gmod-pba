-- A speaker's voice (SND_SPEAKER: a loudspeaker, Breencast copies) keeps its speaker EQ (N.SPEAKER_EQ:
-- lows and highs cut) while pba follows it, not only at its start (side bug 44). Client lua_job, native
-- rendering on, pba_tworooms closed (any map with a wall near the player works).
-- Two followed cases: an obstructed one-shot (cl_render one-shot records, targetValues) and a clear one on a
-- moving entity in "everything native" (N.follow, N.UpdateFollowers). For each, the same line is played
-- with and without SND_SPEAKER; every message sent to the voice (Play, then Update) is recorded as its
-- low/mid band ratio. The clear case then moves its entity behind the wall (the voice turns obstructed, its
-- EQ ramps to the new target). Pass, per case: with the flag, the steady ratio of the updates before the
-- move, and the settled ratio after it (the last updates agree), stay at most half those without the flag
-- (SPEAKER_EQ cuts the lows to 0.25), and enough updates were seen.
-- Before the fix: Play had the EQ, the first re-evaluation dropped it (same ratio as without the flag).
-- (Once, the plain run's largest ratio was compared with the flagged run's: the clear voice turned
-- obstructed only at the end of a fixed 1.8 s window, so a loaded machine, where the plain run's few updates
-- came before the turn, failed 1 run in 8 at no fault of the code. The states are now waited for, not timed.)
local A = pba
local N = A.Native
if not (N and N.ready and N.render and pba_native) then
	return { pass = false, err = "native renderer not running (pba_native_render 1, module loaded)" }
end
local L0 = A.ListenerPos()
if not L0 then return { pass = false, err = "no listener" } end
local NAME = "vo/breencast/br_collaboration01.wav" -- 8.3 s (a speaker's line): a followed one-shot, long enough to wait for states in
N.EnsureSound(NAME)
job:sleep(0.5)

local blocked, clear
math.randomseed(5)
for _ = 1, 800 do
	if blocked and clear then break end
	local S = L0 + Vector(math.random(-900, 900), math.random(-900, 900), math.random(-40, 40))
	if bit.band(util.PointContents(S), MASK_SOLID) == 0 and S:Distance(L0) > 200 then
		local r = A.Paths.Compute(S, L0, 75)
		if r.clear then clear = clear or S
		elseif r.voices and #r.voices > 0 then blocked = blocked or S end
	end
	job:step()
end
if not (blocked and clear) then return { pass = false, err = "no blocked + clear source pair found" } end

-- spies (restored below): the bands of every message to the line's voices
local ids, msgs = {}, {}
local play, update = pba_native.Play, pba_native.Update
local function isName(n) return n and string.find(string.lower(tostring(n)), NAME, 1, true) ~= nil end
pba_native.Play = function(n, pos, g, l, m, h, ...)
	local id = play(n, pos, g, l, m, h, ...)
	if id and id > 0 and isName(n) then ids[id] = true end
	return id
end
pba_native.Update = function(id, pos, g, l, m, h, ...)
	if ids[id] and l and m and m > 0 then msgs[#msgs + 1] = l / m end
	return update(id, pos, g, l, m, h, ...)
end
local origLP = A.ListenerPos
local L = L0
A.ListenerPos = function() return L, (blocked - L):Angle() end

local MAXT = 7 -- seconds a state is waited for (the line lasts 8 s)
local function settled(t, n)
	if #t < n then return false end
	local lo, hi = math.huge, 0
	for i = #t - n + 1, #t do lo, hi = math.min(lo, t[i]), math.max(hi, t[i]) end
	return hi - lo <= 0.02 * hi
end
-- moveTo: after a steady state (4 updates) the entity is put there, and the new state is waited for (the last 3
-- updates agree, 4 updates since the move)
local function run(S, speaker, ent, moveTo)
	ids, msgs = {}, {}
	local d = { SoundName = NAME, OriginalSoundName = NAME, Pos = S, SoundLevel = 75, Pitch = 100, Volume = 1,
		Channel = CHAN_VOICE, Flags = speaker and (SND_SPEAKER or 64) or 0, DSP = 0,
		Entity = ent or game.GetWorld(), EntIndex = ent and ent:EntIndex() or 0 }
	local taken = A.Process(d, true)
	local n1 -- updates seen when the entity was moved
	local i, t0 = 0, RealTime()
	while RealTime() - t0 < MAXT * (moveTo and 2 or 1) do
		job:sleep(0.15) -- (the listener steps a little: every re-evaluation gets a new target)
		i = i + 1
		L = L0 + Vector(0, (i % 2) * 6, 0)
		if not n1 then
			if #msgs >= 4 then
				if not moveTo then break end
				n1 = #msgs
				ent:SetPos(moveTo)
				t0 = RealTime()
			end
		elseif #msgs >= n1 + 4 and settled(msgs, 3) then
			break
		end
	end
	L = L0
	for id in pairs(ids) do pba_native.StopVoice(id) end
	local first, last, seq = {}, msgs[#msgs] or 0, {}
	for k = 1, n1 or #msgs do first[#first + 1] = msgs[k] end
	for k = 1, math.min(#msgs, 40) do seq[k] = math.Round(msgs[k], 2) end
	local lo, hi = math.huge, 0
	for _, r in ipairs(first) do lo, hi = math.min(lo, r), math.max(hi, r) end
	return { taken = taken, voices = table.Count(ids), updates = #msgs, firstLo = math.Round(lo, 3), firstHi = math.Round(hi, 3),
		last = math.Round(last, 3), moved = n1 ~= nil, settled = settled(msgs, 3), seq = seq, dist = math.Round(S:Distance(L0)) }
end

local res = { checks = {} }
local all = A.cfg.native_all
local ok, err = pcall(function()
	A.cfg.native_all = 0
	res.blockedPlain = run(blocked, false)
	res.blockedSpeaker = run(blocked, true)
	A.cfg.native_all = 1
	local e = ClientsideModel("models/props_junk/PopCan01a.mdl")
	e:SetPos(clear)
	res.clearPlain = run(clear, false, e, blocked)
	e:SetPos(clear)
	res.clearSpeaker = run(clear, true, e, blocked)
	e:Remove()
end)
pba_native.Play, pba_native.Update = play, update
A.ListenerPos = origLP
A.cfg.native_all = all
if not ok then return { pass = false, err = tostring(err) } end

local c = res.checks
local function keeps(p, s, moved)
	if p.updates < 4 or s.updates < 4 then return false end
	if moved and not (p.moved and s.moved and p.settled and s.settled) then return false end
	-- the steady state before the move (Play, then the first re-evaluations: the original bug) and the settled one
	return s.firstHi <= 0.5 * p.firstLo and s.last <= 0.5 * p.last
end
c.blockedKeepsEQ = keeps(res.blockedPlain, res.blockedSpeaker, false)
c.clearKeepsEQ = keeps(res.clearPlain, res.clearSpeaker, true)
res.option = A.cfg.native_speaker_follow
res.fails = {}
for k, v in SortedPairs(c) do if not v then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
