-- The silent line safety net leaves alone a line pba made inaudible on purpose (client lua_job, pba_tworooms, Light
-- or native rendering; review C5). A relayed line on CHAN_VOICE of an entity without a face, whose only path is far
-- under the emission thresholds (the walls' loss), emits no voice: pba's model says it is not heard. The net
-- (pba_silent_handback, armed as cl_render's relay receiver arms it) then saw nothing rendered and handed it to the
-- engine, which played it clear through the walls.
-- The path search is stubbed with that voice. Pass: taken (A.Process true), no voice, and the net does not hand it
-- back within 0.5 s. pre: `local CONTROL = true` runs with pba_handback_quiet 0: passes when it IS handed back.
local A = pba
local NAME = "vo/npc/male01/hi01.wav"
local L = A.ListenerPos()
local S = Vector(784, 256, 40)
local src
for _, e in ipairs(ents.GetAll()) do
	if IsValid(e) and e:EntIndex() > 0 and not e:IsPlayer() and not e:IsWorld() and (e.GetFlexNum == nil or e:GetFlexNum() == 0) then src = e break end
end
if not src then return { pass = false, err = "no entity" } end
local idx = src:EntIndex()
A.SetOverride("handback_quiet", CONTROL and 0 or 1)
A.SetOverride("burst_budget_ms", 0)
A.SetOverride("burst_mask_db", 0)
local origEval, origSlicer = A.Paths.Evaluate, A.Slicer
A.Paths.Evaluate = function() return { clear = false, voices = { { pos = Vector(500, 256, 40), gain = 1e-7, len = 600, lp = 4, rawLossDb = 140 } } } end
local res = { checks = {} }
local handed = false
local ok, err = pcall(function()
	local v0 = A.stats.voices
	local data = { SoundName = NAME, Pos = S, SoundLevel = 75, Pitch = 100, Volume = 1, Channel = CHAN_VOICE, Flags = 0, DSP = 0, EntIndex = idx }
	local taken = A.Process(data, true)
	A.Paths.Evaluate = origEval
	res.taken, res.voices = taken, A.stats.voices - v0
	if taken then A.WatchLine(NAME, 0, "test relayed line", function() handed = true end, idx, CHAN_VOICE) end
	job:sleep(0.5)
	res.handedBack = handed
	res.checks.taken = taken == true
	res.checks.noVoice = res.voices == 0
	res.checks.notHandedBack = handed == false
end)
A.Paths.Evaluate = origEval
A.SetOverride("handback_quiet", nil)
A.SetOverride("burst_budget_ms", nil)
A.SetOverride("burst_mask_db", nil)
if not ok then return { pass = false, err = tostring(err) } end
res.fails = {}
for k, okc in SortedPairs(res.checks) do if not okc then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
if CONTROL then
	res.controlRed = not res.pass
	res.pass = res.checks.taken and res.checks.noVoice and handed == true or false
end
return res
