-- A speaker's voice (SND_SPEAKER: a loudspeaker, Breencast copies) keeps its speaker EQ (N.SPEAKER_EQ:
-- lows and highs cut) while pba follows it, not only at its start (side bug 44). Client lua_job, native
-- rendering on, pba_tworooms closed (any map with a wall near the player works).
-- Two followed cases: an obstructed one-shot (cl_render one-shot records, targetValues) and a clear one on a
-- moving entity in "everything native" (N.follow, N.UpdateFollowers). For each, the same line is played
-- with and without SND_SPEAKER; every message sent to the voice (Play, then Update) is recorded as its
-- low/mid band ratio. Pass: with the flag, the largest low/mid ratio of the updates stays at most half the
-- one without the flag (SPEAKER_EQ cuts the lows to 0.25), and updates were seen.
-- Before the fix: Play had the EQ, the first re-evaluation dropped it (same ratio as without the flag).
local A = pba
local N = A.Native
if not (N and N.ready and N.render and pba_native) then
	return { pass = false, err = "native renderer not running (pba_native_render 1, module loaded)" }
end
local L0 = A.ListenerPos()
if not L0 then return { pass = false, err = "no listener" } end
local NAME = "vo/npc/male01/question06.wav" -- 3.4 s: a followed one-shot
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

local function run(S, speaker, ent)
	ids, msgs = {}, {}
	local d = { SoundName = NAME, OriginalSoundName = NAME, Pos = S, SoundLevel = 75, Pitch = 100, Volume = 1,
		Channel = CHAN_VOICE, Flags = speaker and (SND_SPEAKER or 64) or 0, DSP = 0,
		Entity = ent or game.GetWorld(), EntIndex = ent and ent:EntIndex() or 0 }
	local taken = A.Process(d, true)
	-- the listener steps a little: every re-evaluation gets a new target
	for i = 1, 12 do
		job:sleep(0.15)
		L = L0 + Vector(0, (i % 2) * 6, 0)
		if IsValid(ent) then ent:SetPos(S + Vector(i * 4, 0, 0)) end
	end
	L = L0
	for id in pairs(ids) do pba_native.StopVoice(id) end
	local mx = 0
	for _, r in ipairs(msgs) do mx = math.max(mx, r) end
	return { taken = taken, voices = table.Count(ids), updates = #msgs, maxLowMid = math.Round(mx, 3) }
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
	res.clearPlain = run(clear, false, e)
	e:SetPos(clear)
	res.clearSpeaker = run(clear, true, e)
	e:Remove()
end)
pba_native.Play, pba_native.Update = play, update
A.ListenerPos = origLP
A.cfg.native_all = all
if not ok then return { pass = false, err = tostring(err) } end

local c = res.checks
local function keeps(p, s)
	return p.updates > 0 and s.updates > 0 and s.maxLowMid <= 0.5 * p.maxLowMid
end
c.blockedKeepsEQ = keeps(res.blockedPlain, res.blockedSpeaker)
c.clearKeepsEQ = keeps(res.clearPlain, res.clearSpeaker)
res.option = A.cfg.native_speaker_follow
res.fails = {}
for k, v in SortedPairs(c) do if not v then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
