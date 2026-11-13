-- The loops_max cap counted two ways (audit bug 3). LP.Handle caps with LP.CapCount(), which with
-- loops_cap_audible counts the audible loops only; the timer taking capped loops over counted every loop
-- (table.Count(LP.active)). With silent patches running (C++ engines at volume 0), a capped audible loop
-- was never taken over although audible slots were free: vanilla through every wall to its end.
-- Server lua_job, any map with a human. 4 silent patches, then 2 audible ones fill a cap of 2 audible, a
-- third audible one is capped; one audible stops.
-- Pass: the capped one is taken over by the timer (within 1.5 s). (With pba_loops_cap_audible 0 both ways
-- count every loop: nothing to compare.)
local A = pba
local LP = A.Loops
local ply = player.GetHumans()[1]
if not (LP and IsValid(ply)) then return { pass = false, err = "needs pba loops and a human" } end
local SND = "ambient/machines/spin_loop.wav"
local savedMax, savedOpt = A.cfg.loops_max, A.cfg.loops_cap_audible
local props, patches = {}, {}
local function prop(i)
	local e = ents.Create("prop_physics")
	e:SetModel("models/props_junk/popcan01a.mdl")
	e:SetPos(ply:GetPos() + Vector(100 + 20 * i, 0, 40))
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
local function run(capAudible)
	A.cfg.loops_cap_audible = capAudible
	for i = 1, 4 do local p = CreateSound(prop(i), SND) p:PlayEx(0, 100) patches[#patches + 1] = p end
	job:sleep(0.2)
	-- the cap: what is followed now (counted the cap's way) plus 2
	A.cfg.loops_max = LP.CapCount() + 2
	local loud = {}
	for i = 1, 3 do
		local e = prop(10 + i)
		local p = CreateSound(e, SND) p:PlayEx(1, 100)
		patches[#patches + 1] = p
		loud[i] = { e = e, p = p }
	end
	job:sleep(0.2)
	local r = { capped = cappedOf(loud[3].e) }
	loud[1].p:Stop()
	job:sleep(1.5)
	r.takenOver = activeOf(loud[3].e)
	for _, p in ipairs(patches) do p:Stop() end
	for _, e in ipairs(props) do if IsValid(e) then e:Remove() end end
	patches, props = {}, {}
	job:sleep(0.6)
	return r
end
local res = {}
local ok, err = pcall(function()
	res.audible = run(1)
end)
A.cfg.loops_max, A.cfg.loops_cap_audible = savedMax, savedOpt
for _, p in ipairs(patches) do p:Stop() end
for _, e in ipairs(props) do if IsValid(e) then e:Remove() end end
if not ok then return { pass = false, err = tostring(err) } end
res.pass = res.audible.capped and res.audible.takenOver
return res
