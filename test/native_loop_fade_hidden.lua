-- A hidden loop faded to silence by its entity (client lua_job, pba_tworooms, native rendering on, player
-- in room A at its spawn): the entity lowers its CSoundPatch to volume 0 without stopping it (a gravity gun
-- let go, an ambient_generic's Volume 0, a car addon). Its native voice used to stay at its last level for
-- good: the change forced a re-evaluation, but the far-and-quiet shortcut (A.TooQuiet, -40 dB) sees the
-- new volume 0 as "quiet" and keeps the voice's values. Pass: the voice's gain drops below -60 dB of the
-- level it had, within 1.5 s.
local N = pba.Native
if not (N and N.render) then return { pass = false, err = "native renderer not running" } end
if game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "pba_tworooms only" } end
local LP = pba.Loops
local NAME = "ambient/machines/spin_loop.wav"
local e = ClientsideModel("models/hunter/blocks/cube025x025x025.mdl", RENDERGROUP_OTHER)
e:SetNoDraw(true)
e:SetPos(Vector(784, 256, 40)) -- room B, behind the wall
local gains = {}
local origUpdate = pba_native.Update
pba_native.Update = function(id, pos, g, ...)
	gains[id] = g
	return origUpdate(id, pos, g, ...)
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
	res.before = gains[id]
	p:ChangeVolume(0, 0)
	job:sleep(1.5)
	res.after = gains[id]
	res.checks.silenced = (res.before or 0) > 0 and (res.after or 1) < res.before * 1e-3
	p:Stop()
end)
pba_native.Update = origUpdate
if IsValid(e) then e:Remove() end
if not ok then return { pass = false, err = err } end
res.fails = {}
for k, okc in SortedPairs(res.checks) do if not okc then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
