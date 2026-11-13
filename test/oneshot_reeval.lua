-- One scheduler for every followed sound (refactor step 10): a followed one-shot whose source, listener
-- and world do not move is re-evaluated by the cadence rule of loops (pba_reeval_adaptive: on a move, a
-- world change or after pba_reeval_max_s), not every update_interval. Client lua_job, pba_tworooms; the
-- player stands still in room A, the line plays behind the wall in room B (3.4 s, followed).
-- args.adaptive: the pba_reeval_adaptive value for this run (0 = every interval, the control).
local A = pba
if game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms" } end
local want = (job.args or {}).adaptive or 1
local ad0 = GetConVar("pba_reeval_adaptive"):GetFloat()
RunConsoleCommand("pba_reeval_adaptive", tostring(want))
job:wait(function() return A.cfg.reeval_adaptive == want end, 3)
local name = "vo/npc/male01/question06.wav"
local P = A.Paths
local ev0 = P.Evaluate
local n, rec = 0, nil
P.Evaluate = function(o, ...)
	if rec and o == rec then n = n + 1 end
	return ev0(o, ...)
end
local d = { SoundName = name, OriginalSoundName = name, Pos = Vector(1000, 480, 64), Entity = game.GetWorld(), Channel = CHAN_AUTO,
	Volume = 1, SoundLevel = 75, Pitch = 100, Flags = 0, DSP = 0, SoundTime = 0 }
local ok, err = pcall(A.hooks.EntityEmitSound, d)
for _, r in ipairs(A.OneShots.recs or {}) do if r.name == name then rec = r end end
local res = { followed = rec ~= nil, err = not ok and tostring(err) or nil, adaptive = A.cfg.reeval_adaptive }
if rec then
	job:sleep(2.2)
	res.evals = n
end
P.Evaluate = ev0
RunConsoleCommand("pba_reeval_adaptive", tostring(ad0))
-- adaptive: the first re-evaluation, then one after reeval_max_s (1 s); every interval (0.25 s): about 8
if want >= 0.5 then
	res.pass = res.followed and (res.evals or 0) >= 1 and (res.evals or 99) <= 3
else
	res.pass = res.followed and (res.evals or 0) >= 6
end
return res
