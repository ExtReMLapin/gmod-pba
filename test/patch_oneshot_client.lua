-- A client CreateSound patch on a file WITHOUT loop points (an addon's client effect): its Play reaches
-- the client hook as a SND_CHANGE_VOL start; it was neither a loop nor an eligible one-shot, so it crossed
-- every wall unprocessed. Taken as a one-shot mirror (pba_patch_oneshots): for its file's length, stopped
-- with the patch. lua_job, client realm, pba_tworooms. Returns { pass, checks }.
local LP = pba.Loops
local NAME = "ambient/machines/machine1_hit2.wav" -- no loop points
local res = { checks = {}, dur = pba.SoundDuration(NAME) }
local function chk(k, ok) res.checks[k] = ok and true or false end
local function mirrorOf(e)
	for _, m in pairs(LP.mirrors) do if m.client and m.ent == e and m.name == NAME then return m end end
end
local L = LocalPlayer():EyePos()
local e = ClientsideModel("models/props_junk/popcan01a.mdl", RENDERGROUP_OTHER)
e:SetPos(L + LocalPlayer():GetForward() * 200)
chk("noLoopPoints", not pba.IsLooping(NAME) and (res.dur or 0) > 0.3)
local p = CreateSound(e, NAME)
p:Play()
job:sleep(0.2)
local m = mirrorOf(e)
chk("taken", m ~= nil)
chk("once", m ~= nil and m.once == true)
p:Stop()
job:sleep(0.4)
chk("stopped", mirrorOf(e) == nil)
-- played to its end: the mirror ends with the file
local p2 = CreateSound(e, NAME)
p2:Play()
job:sleep(0.2)
local had = mirrorOf(e) ~= nil
job:sleep((res.dur or 1) + 1.5)
chk("ended", had and mirrorOf(e) == nil)
p2:Stop()
-- option off: left to the engine
local was = pba.cfg.patch_oneshots
pba.cfg.patch_oneshots = 0
local p3 = CreateSound(e, NAME)
p3:Play()
job:sleep(0.2)
chk("optionOff", mirrorOf(e) == nil)
p3:Stop()
pba.cfg.patch_oneshots = was
e:Remove()
res.fails = {}
for k, v in SortedPairs(res.checks) do if not v then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
