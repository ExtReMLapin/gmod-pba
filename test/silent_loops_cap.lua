-- Silent loops and the loops_max cap (audit B-7). C++ code starts many sound patches at volume 0 and raises
-- them later (airboat: 6 patches, gravity gun, mounted guns); the engine runs them at 0 at no cost. pba
-- followed each one as a mirror counted in loops_max, so once the cap was reached by silent ones a new
-- AUDIBLE loop was left to the engine (vanilla through walls).
-- Server lua_job, any map with a human. The cap is set to 4 for the test (restored after); 4 patches are
-- started at volume 0, then one at volume 1.
-- Pass: the audible loop is followed (LP.active), not capped; a silent patch raised later is followed too;
-- with pba_loops_cap_audible 0 the audible one is capped again (the old behaviour).
local A = pba
local LP = A.Loops
local ply = player.GetHumans()[1]
if not (LP and IsValid(ply)) then return { pass = false, err = "needs pba loops and a human" } end
local SND = "ambient/machines/spin_loop.wav"
local savedMax = A.cfg.loops_max
local props, patches = {}, {}
local function prop(i)
	local e = ents.Create("prop_physics")
	e:SetModel("models/props_junk/popcan01a.mdl")
	e:SetPos(ply:GetPos() + Vector(100 + 30 * i, 0, 40))
	e:Spawn()
	local phys = e:GetPhysicsObject()
	if IsValid(phys) then phys:EnableMotion(false) end
	props[#props + 1] = e
	return e
end
local function activeOf(e)
	for _, l in pairs(LP.active) do if l.idx == e:EntIndex() then return true end end
	return false
end
local function cappedOf(e)
	for _, l in pairs(LP.capped) do if l.idx == e:EntIndex() then return true end end
	return false
end
-- the other loops already followed count too: the cap is set relative to them
local before = table.Count(LP.active)
A.cfg.loops_max = before + 4
local res = { checks = {} }
local ok, err = pcall(function()
	for i = 1, 4 do
		local p = CreateSound(prop(i), SND)
		p:PlayEx(0, 100)
		patches[#patches + 1] = p
	end
	job:sleep(0.3)
	local loud = prop(5)
	local p = CreateSound(loud, SND)
	p:PlayEx(1, 100)
	patches[#patches + 1] = p
	job:sleep(0.3)
	res.checks.audibleFollowed = activeOf(loud)
	res.checks.audibleNotCapped = not cappedOf(loud)
	-- a silent one raised later: followed from then on
	patches[1]:ChangeVolume(1, 0)
	job:sleep(0.3)
	res.checks.raisedFollowed = activeOf(props[1])
	res.active = table.Count(LP.active) - before
end)
for _, p in ipairs(patches) do p:Stop() end
for _, e in ipairs(props) do if IsValid(e) then e:Remove() end end
-- control: with loops_cap_audible 0 the silent patches fill the cap again and the audible one is capped
if ok then
	local savedOpt = A.cfg.loops_cap_audible
	A.cfg.loops_cap_audible = 0
	local props2, patches2 = {}, {}
	for i = 1, 5 do
		local e = ents.Create("prop_physics")
		e:SetModel("models/props_junk/popcan01a.mdl")
		e:SetPos(ply:GetPos() + Vector(100 + 30 * i, 60, 40))
		e:Spawn()
		props2[i] = e
	end
	A.cfg.loops_max = table.Count(LP.active) + 4
	for i = 1, 4 do local p = CreateSound(props2[i], SND) p:PlayEx(0, 100) patches2[i] = p end
	job:sleep(0.3)
	local p5 = CreateSound(props2[5], SND) p5:PlayEx(1, 100) patches2[5] = p5
	job:sleep(0.3)
	res.checks.optionOffCaps = not activeOf(props2[5])
	for _, p in ipairs(patches2) do p:Stop() end
	for _, e in ipairs(props2) do if IsValid(e) then e:Remove() end end
	A.cfg.loops_cap_audible = savedOpt
end
A.cfg.loops_max = savedMax
if not ok then return { pass = false, err = tostring(err) } end
res.fails = {}
for k, v in SortedPairs(res.checks) do if not v then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
