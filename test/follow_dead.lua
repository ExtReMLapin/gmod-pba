-- The per-frame follower notices a mirror's module voice that is gone (client lua_job, pba_tworooms, native rendering
-- on, player in room A; review risk "FollowNative ignores Update's return"). LP.FollowNative glides a mirror's voice
-- every frame and dropped pba_native.Update's answer: a voice the module ended (its voice cap, a module stop) kept its
-- id until the mirror's next evaluation, which a still scene may not bring (reeval_adaptive): a long line's mirror
-- stayed "playing" a dead voice, and its early copy muted (early release) or its handback waited.
-- Pass: after the voice is stopped in the module, one follower pass with a gliding ramp clears m.nativeId.
local A = pba
local N = A.Native
if not (N and N.render) then return { pass = false, err = "native renderer not running" } end
local LP = A.Loops
local NAME = "ambient/machines/spin_loop.wav"
local e = ClientsideModel("models/hunter/blocks/cube025x025x025.mdl", RENDERGROUP_OTHER)
e:SetNoDraw(true)
e:SetPos(Vector(784, 256, 40))
local res = { checks = {} }
local ok, err = pcall(function()
	local p = CreateSound(e, NAME)
	p:SetSoundLevel(80)
	p:PlayEx(1, 100)
	job:sleep(1.5)
	local m
	for _, x in pairs(LP.mirrors) do if x.client and x.ent == e then m = x end end
	res.checks.mirrorNative = m ~= nil and m.nativeId ~= nil and m.ramp ~= nil
	if not res.checks.mirrorNative then return end
	local id = m.nativeId
	pba_native.StopVoice(id)
	res.updateAnswer = pba_native.Update(id, e:GetPos(), 0.01, 1, 1, 1, 100)
	m.ramp.pending = true
	LP.FollowNative(A.ListenerPos())
	res.idAfter = m.nativeId
	res.checks.cleared = m.nativeId == nil
	p:Stop()
end)
if IsValid(e) then e:Remove() end
if not ok then return { pass = false, err = tostring(err) } end
res.fails = {}
for k, okc in SortedPairs(res.checks) do if not okc then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
