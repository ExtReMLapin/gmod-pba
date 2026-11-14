-- A client CreateSound patch on a file without loop points that has played to its end, then restarted by a
-- ChangeVolume / ChangePitch (the engine plays a finished channel's alteration as a new start, from the top):
-- its mirror was gone, so the hook found no mirror and no patch and left the restart to the engine, raw,
-- through every wall. Now the patches' ChangeVolume / ChangePitch tell the hook which patch it is
-- (pba_patch_restart) and the restart is taken as a new one-shot mirror.
-- lua_job, client realm, pba_tworooms. Returns { pass, checks }.
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
local function played(change)
	local p = CreateSound(e, NAME)
	p:Play()
	job:sleep(0.2)
	local first = mirrorOf(e)
	job:sleep((res.dur or 1) + 1.5)
	local ended = first ~= nil and mirrorOf(e) == nil
	change(p)
	job:sleep(0.4)
	local again = mirrorOf(e)
	local ok = ended and again ~= nil and again.once == true
	-- the restarted one ends with its file too
	job:sleep((res.dur or 1) + 1.5)
	local over = mirrorOf(e) == nil
	p:Stop()
	return ended, ok, over
end
local ended, ok, over = played(function(p) p:ChangeVolume(0.6, 0) end)
chk("firstEnded", ended)
chk("volumeRestartTaken", ok)
chk("volumeRestartEnds", over)
ended, ok, over = played(function(p) p:ChangePitch(120, 0) end)
chk("pitchRestartTaken", ok)
chk("pitchRestartEnds", over)
-- option off: left to the engine
local was = pba.cfg.patch_restart
pba.cfg.patch_restart = 0
ended, ok = played(function(p) p:ChangeVolume(0.6, 0) end)
chk("optionOff", ended and not ok)
pba.cfg.patch_restart = was
-- a patch still playing keeps its mirror: a change is that mirror's, no second one
local p = CreateSound(e, NAME)
p:Play()
job:sleep(0.2)
local m = mirrorOf(e)
p:ChangeVolume(0.5, 0)
job:sleep(0.1)
chk("changeKeepsMirror", m ~= nil and mirrorOf(e) == m)
p:Stop()
e:Remove()
res.fails = {}
for k, v in SortedPairs(res.checks) do if not v then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
