-- One module Update per change of a mirror (client lua_job, pba_tworooms, native rendering on, player in room A):
-- a server update that changes a hidden loop's volume AND pitch (updateMirror), then the frame's follower
-- (LP.FollowNative), send the voice its new values once. Before, volumeNow sent them with the old pitch, pitchNow
-- again with the new one, and FollowNative a third time in the same frame (review C0). Pass: one Update for the
-- voice over the change and the follower, carrying the new gain and pitch.
local N = pba.Native
if not (N and N.render) then return { pass = false, err = "native renderer not running" } end
local LP = pba.Loops
local NAME = "ambient/machines/spin_loop.wav"
local recv = net.Receivers and net.Receivers["pba_loop"]
local updateMirror
for i = 1, 60 do
	local n, v = debug.getupvalue(recv, i)
	if not n then break end
	if n == "updateMirror" then updateMirror = v end
end
if not updateMirror then return { pass = false, err = "updateMirror not found" } end
local e = ClientsideModel("models/hunter/blocks/cube025x025x025.mdl", RENDERGROUP_OTHER)
e:SetNoDraw(true)
e:SetPos(Vector(784, 256, 40)) -- room B, behind the wall
local calls = {}
local origUpdate = pba_native.Update
pba_native.Update = function(id, pos, g, el, em, eh, pitch, ...)
	calls[#calls + 1] = { id = id, g = g, pitch = pitch }
	return origUpdate(id, pos, g, el, em, eh, pitch, ...)
end
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
	-- (just after its evaluation: a ramp is running, the follower would send it this frame)
	m.reeval = m.reeval or {}
	job:frames(2)
	for k in pairs(calls) do calls[k] = nil end
	local g0 = m.appliedVol
	updateMirror(m, false, 0.5, 150)
	LP.FollowNative(pba.ListenerPos())
	local mine = {}
	for _, c in ipairs(calls) do if c.id == id then mine[#mine + 1] = c end end
	res.updates = #mine
	res.g0 = g0
	res.last = mine[#mine]
	res.first = mine[1]
	res.checks.oneUpdate = #mine == 1
	res.checks.newPitch = mine[#mine] ~= nil and mine[#mine].pitch ~= nil and mine[#mine].pitch > 140
	res.checks.everyNewPitch = true
	for _, c in ipairs(mine) do if not (c.pitch and c.pitch > 140) then res.checks.everyNewPitch = false end end
	p:Stop()
end)
pba_native.Update = origUpdate
if IsValid(e) then e:Remove() end
if not ok then return { pass = false, err = err } end
res.fails = {}
for k, okc in SortedPairs(res.checks) do if not okc then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
