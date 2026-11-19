-- Burst-degraded sounds are never dropped: client lua_job, pba_tworooms. A new sound past the burst budget
-- (pba_burst_budget_ms) or masked (pba_burst_mask_db) with no nearby result to reuse gets the cheap model (the
-- walls' transmission alone, no routes round them). An 80 dB impact in room B heard from room A through the open
-- doorway: full model -30.8 dB, cheap model -60 dB, under what a voice is emitted at (native gain 0.001, engine
-- volume 0.01): the sound was taken from the engine and nothing played it at all.
--   reference: the budget off, the impact fully evaluated: its dominant voice's level at birth;
--   degraded: budget 0.001 ms already spent this frame, masking off, no reusable result, not the loudest of the
--     burst, the slicer's deferral refused (too near): the cheap model. Pass = it is played (a voice emitted) and
--     its level 0.3 s later within KEEP_DB of the reference (its full evaluation came in and it glided to it).
local A = pba
if game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms" } end
local P, B, OS = A.Paths, A.burst, A.OneShots
local KEEP_DB, AFTER_S = 3, 0.3
if LocalPlayer():GetPos():Distance(Vector(256, 256, 0)) > 1 then
	RunConsoleCommand("setpos", "256", "256", "0")
	job:sleep(0.5)
end
local L = A.ListenerPos()
local name = "physics/metal/metal_barrel_impact_hard1.wav" -- (1.2 s: followed while it plays)
local S = Vector(900, 400, 40)
local function snd()
	return { SoundName = name, OriginalSoundName = name, Pos = Vector(S), Entity = NULL, EntIndex = 0,
		Channel = CHAN_AUTO, Volume = 1, SoundLevel = 80, Pitch = 100, Flags = 0, DSP = 0, SoundTime = 0 }
end
local function db(g) return 20 * math.log10(math.max(g or 0, 1e-9)) end
-- the newest followed record of the impact and its dominant voice's level now
local function recLevel(after)
	local best
	for _, rec in ipairs(OS.recs or {}) do
		if rec.name == name and rec.key > after and (not best or rec.key > best.key) then best = rec end
	end
	if not best then return nil end
	local g = 0
	for _, fv in ipairs(best.voices) do
		if not fv.dead and not fv.fading and fv.ramp and fv.ramp.to then
			g = math.max(g, (P.RampAt(fv.ramp, RealTime(), L)))
		end
	end
	return db(g), best
end
-- every emission of a voice during A.Process: native PlayVoice and engine copies
local emitted = 0
local N = A.Native
local origPV, origEA, origE = N and N.PlayVoice, A.EmitAt, A.Emit
local function count(f) return function(...) emitted = emitted + 1 return f(...) end end
local function once(budgetMs)
	A.SetOverride("burst_budget_ms", budgetMs)
	job:frames(2)
	B.loudT, B.loudDb = RealTime(), 200 -- (a loud sound just before: this one is not the loudest of the burst)
	B.near = {}
	B.byEmitter = setmetatable({}, { __mode = "k" })
	B.frame, B.spent = FrameNumber(), 1 -- (the frame's budget already spent)
	local k0 = OS.seq or 0
	emitted = 0
	local taken = A.Process(snd(), false)
	local lv0 = recLevel(k0)
	job:sleep(AFTER_S)
	local lv1 = recLevel(k0)
	return { taken = taken, emitted = emitted, birthDb = lv0 and math.Round(lv0, 1), afterDb = lv1 and math.Round(lv1, 1) }
end
local saved = { burst_budget_ms = A.override.burst_budget_ms, burst_mask_db = A.override.burst_mask_db }
local defer = A.Slicer and A.Slicer.Defer
local ok, res = pcall(function()
	if N and origPV then N.PlayVoice = count(origPV) end
	A.EmitAt, A.Emit = count(origEA), count(origE)
	if A.Slicer then A.Slicer.Defer = function() return nil end end
	A.SetOverride("burst_mask_db", 0)
	-- (native: the file decoded first, both runs rendered by the module; a first play is the engine's meanwhile)
	if N and N.render and N.EnsureSound then
		N.EnsureSound(name)
		job:wait(function() return pba_native.HasSound(name) end, 5)
	end
	local cheap = P.Cheap(S, L, 80, nil, nil)
	local ref = once(0)
	job:sleep(1.5)
	local deg = once(0.001)
	return { ref = ref, deg = deg, cheapDb = cheap and cheap.voices and cheap.voices[1] and math.Round(db(cheap.voices[1].gain), 1) }
end)
if N and origPV then N.PlayVoice = origPV end
A.EmitAt, A.Emit = origEA, origE
if A.Slicer then A.Slicer.Defer = defer end
-- (by key: pairs() skipped the keys that had no override, and the test left its own two in memory)
for _, k in ipairs({ "burst_budget_ms", "burst_mask_db" }) do A.SetOverride(k, saved[k]) end
if not ok then return { pass = false, err = tostring(res) } end
local r, d = res.ref, res.deg
res.native = N and N.render or false
res.played = d.taken == true and d.emitted > 0
res.reached = d.afterDb ~= nil and r.birthDb ~= nil and math.abs(d.afterDb - r.birthDb) <= KEEP_DB
res.pass = r.emitted > 0 and res.played and res.reached
return res
