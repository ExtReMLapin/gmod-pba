-- A deferred channel cut reaches the copies of a sound held while its routes are computed (client lua_job, pba_tworooms,
-- native rendering on; review C2). A far line on a replacing channel (CHAN_VOICE) whose evaluation runs in slices is
-- held (A.Process: a placeholder in the copy registry, cl_slicer job). A new sound on that channel starting 0.5 s later
-- (A.CutChannel with its delay, pba_cut_at_start) sets the placeholder's cut time. The routes are ready before that time
-- (the job's onDone): the copies emitted then must stop at the cut. Before, the placeholder's timer found it cancelled
-- (its part over) and the copies played to their end.
-- The path search is stubbed: A.Paths.Evaluate returns a held job, completed by hand with one transmission voice.
-- Pass: the copy's module voice is stopped 0.5 s (+-0.15) after the cut.
local A = pba
local N = A.Native
if not (N and N.render) then return { pass = false, err = "native renderer not running" } end
local NAME = "vo/breencast/br_welcome01.wav"
local L = A.ListenerPos()
local S = Vector(784, 256, 40) -- room B
local src
for _, e in ipairs(ents.GetAll()) do
	if IsValid(e) and e:EntIndex() > 0 and not e:IsPlayer() and not e:IsWorld() and e ~= LocalPlayer():GetViewModel() then src = e break end
end
if not src then return { pass = false, err = "no entity to borrow an index from" } end
local idx = src:EntIndex()
A.SetOverride("burst_budget_ms", 0)
A.SetOverride("burst_mask_db", 0)
local fake = { deadline = RealTime() + 1 }
local origEval, origStop = A.Paths.Evaluate, pba_native.StopVoice
local stopped = {}
pba_native.StopVoice = function(id) stopped[id] = stopped[id] or RealTime() return origStop(id) end
A.Paths.Evaluate = function() return nil, fake end
local res = { checks = {}, idx = idx }
local ok, err = pcall(function()
	job:wait(function() return (N.EnsureSound(NAME)) end, 10)
	local data = { SoundName = NAME, Pos = S, SoundLevel = 75, Pitch = 100, Volume = 1, Channel = CHAN_VOICE, Flags = 0, DSP = 0, EntIndex = idx }
	local taken = A.Process(data, true)
	A.Paths.Evaluate = origEval
	res.held = taken == true and fake.onDone ~= nil
	res.checks.held = res.held
	if not res.held then return end
	local tCut = RealTime()
	A.CutChannel(idx, CHAN_VOICE, 0.5)
	-- the routes are ready at once (before the cut's time)
	fake.onDone({ clear = false, voices = { { pos = Vector(500, 256, 40), gain = 0.05, len = 600, lp = 1, rawLossDb = 26 } } })
	local id
	for _, h in ipairs(A.emitted[idx] or {}) do if h.id and h.orig == NAME then id = h.id end end
	res.copy = id ~= nil
	res.checks.copy = res.copy
	if not id then return end
	job:sleep(0.8)
	res.stopAfter = stopped[id] and (stopped[id] - tCut) or false
	res.checks.stoppedAtCut = res.stopAfter ~= false and math.abs(res.stopAfter - 0.5) <= 0.15
	pba_native.StopVoice(id)
end)
A.Paths.Evaluate, pba_native.StopVoice = origEval, origStop
A.StopSource(idx, NAME)
A.SetOverride("burst_budget_ms", nil)
A.SetOverride("burst_mask_db", nil)
if not ok then return { pass = false, err = tostring(err) } end
res.fails = {}
for k, okc in SortedPairs(res.checks) do if not okc then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
