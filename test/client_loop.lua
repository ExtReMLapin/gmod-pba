-- Loops born on the client (CreateSound of an addon: vehicle engines...): taken over by a client mirror
-- (muffled in place), following the patch's pitch changes, and stopped with CSoundPatch:Stop, with the
-- patch being collected, and with its entity removed (none of which fires EntityEmitSound).
-- lua_job, client realm, any map. Returns { pass, steps }.
local LP = pba.Loops
local NAME = "ambient/machines/spin_loop.wav" -- loop points
local L = LocalPlayer():EyePos()
local function model()
	local e = ClientsideModel("models/props_junk/popcan01a.mdl", RENDERGROUP_OTHER)
	e:SetPos(L + LocalPlayer():GetForward() * 200)
	return e
end
local function mirrorOf(e)
	for _, m in pairs(LP.mirrors) do if m.client and m.ent == e and m.name == NAME then return m end end
end
local steps = {}
-- what pba's client handler receives for this loop (pba's hook returns false: later hooks see nothing)
local events = {}
local origHandle = LP.HandleClient
LP.HandleClient = function(t)
	local r = origHandle(t)
	if t.SoundName == NAME then events[#events + 1] = string.format("f=%d p=%d v=%.2f -> %s", t.Flags or 0, t.Pitch or -1, t.Volume or -1, tostring(r)) end
	return r
end
local e = model()
local p = CreateSound(e, NAME)
p:Play()
job:sleep(0.4)
local m = mirrorOf(e)
steps.started = m ~= nil and not m.once
p:ChangePitch(150, 0)
job:sleep(0.4)
m = mirrorOf(e)
steps.pitch = m and m.pitch or -1
p:Stop()
job:sleep(0.6)
steps.stopped = mirrorOf(e) == nil
local p2 = CreateSound(e, NAME)
p2:Play()
job:sleep(0.4)
steps.restarted = mirrorOf(e) ~= nil
-- a patch dropped by its owner: GMod may keep it while it plays (then the engine plays on, and so must
-- the mirror). The invariant: the mirror lives exactly as long as the patch object
local weak = setmetatable({ p2 }, { __mode = "v" })
p2 = nil
for _ = 1, 15 do
	collectgarbage() collectgarbage()
	job:sleep(0.2)
	if weak[1] == nil then break end
end
job:sleep(0.4)
steps.patchCollected = weak[1] == nil
steps.collected = (weak[1] == nil) == (mirrorOf(e) == nil)
if weak[1] then weak[1]:Stop() end
local p3 = CreateSound(e, NAME)
p3:Play()
job:sleep(0.4)
local had = mirrorOf(e) ~= nil
e:Remove()
job:sleep(0.8)
local left = 0
for _, x in pairs(LP.mirrors) do if x.client and x.name == NAME then left = left + 1 end end
steps.removed = had and left == 0
p3:Stop()
LP.HandleClient = origHandle
local pass = steps.started and steps.pitch == 150 and steps.stopped and steps.restarted and steps.collected and steps.removed
return { pass = pass, steps = steps, events = events }
