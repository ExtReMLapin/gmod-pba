-- A pitch change of a hidden native loop (client lua_job, pba_tworooms, native rendering on, player in room A):
-- the entity's SND_CHANGE_PITCH (a vehicle's revs, an ambient_generic's Pitch input, an LFO) is applied by the
-- engine at the tick. Before, a hidden mirror's voice took it at its next evaluation turn (up to update_interval)
-- and then glided to it over one more interval (audit B-6). Pass: within 0.1 s of ChangePitch(200, 0) the
-- voice's pitch reaches 90 % of the way, and the change forced no path evaluation.
local N = pba.Native
if not (N and N.render) then return { pass = false, err = "native renderer not running" } end
if game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "pba_tworooms only" } end
local LP = pba.Loops
local NAME = "ambient/machines/spin_loop.wav"
local e = ClientsideModel("models/hunter/blocks/cube025x025x025.mdl", RENDERGROUP_OTHER)
e:SetNoDraw(true)
e:SetPos(Vector(784, 256, 40)) -- room B, behind the wall
local pitches = {}
local origUpdate = pba_native.Update
pba_native.Update = function(id, pos, g, el, em, eh, pitch, ...)
	pitches[id] = pitch
	return origUpdate(id, pos, g, el, em, eh, pitch, ...)
end
local evals, origEval = 0, pba.Paths.Evaluate
pba.Paths.Evaluate = function(...) evals = evals + 1 return origEval(...) end
local res = { checks = {} }
local ok, err = pcall(function()
	local p = CreateSound(e, NAME)
	p:SetSoundLevel(80)
	p:PlayEx(1, 100)
	job:sleep(1.5)
	local m
	for _, x in pairs(LP.mirrors) do if x.client and x.ent == e then m = x end end
	res.checks.mirrorNative = m ~= nil and m.nativeId ~= nil and not m.clearPath
	if not res.checks.mirrorNative then return end
	local id = m.nativeId
	res.before = pitches[id]
	-- (just after a round of the mirror's evaluation: the worst case for a change waiting for the next one)
	local e0 = evals
	p:ChangePitch(200, 0)
	local t1 = RealTime()
	job:sleep(0.1)
	res.after = pitches[m.nativeId or id]
	res.dt = RealTime() - t1
	res.evalsAfter = evals - e0
	res.checks.pitchFollowed = res.before ~= nil and res.after ~= nil
		and (res.after - res.before) >= 0.9 * (200 - res.before)
	p:Stop()
end)
pba_native.Update = origUpdate
pba.Paths.Evaluate = origEval
if IsValid(e) then e:Remove() end
if not ok then return { pass = false, err = err } end
res.fails = {}
for k, okc in SortedPairs(res.checks) do if not okc then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
