-- Volume / pitch change of a brief sound pba already relayed or re-emitted (audit B-8). An ambient_generic
-- that is not looped (spawnflag 32) with a preset, LFO or Pitch / Volume inputs, a func_rotating or
-- func_tracktrain with a non-looped move sound send SND_CHANGE_* updates for a brief sound already playing.
-- pba had taken its start; the update then either went to the engine, which STARTED a vanilla copy midway
-- at the players who got pba's copy (no channel matched), or (since pba_patch_oneshots) was taken as a
-- patch start: a second, muffled copy from the top. Either way the sound played twice.
-- Server lua_job, any map with a human. A brief line is emitted on a prop, then a pitch change 0.3 s later.
-- Pass: the start is not taken as a loop mirror; the change starts no mirror (it is suppressed);
-- with pba_brief_updates 0 the change starts a mirror again (the old behaviour).
local A, LP = pba, pba.Loops
local ply = player.GetHumans()[1]
if not (LP and IsValid(ply)) then return { pass = false, err = "needs pba loops and a human" } end
local function run(file)
	local e = ents.Create("prop_physics")
	e:SetModel("models/props_junk/popcan01a.mdl")
	e:SetPos(ply:GetPos() + Vector(300, 0, 40))
	e:Spawn()
	local phys = e:GetPhysicsObject()
	if IsValid(phys) then phys:EnableMotion(false) end
	job:sleep(0.3)
	local function mirrored()
		for _, l in pairs(LP.active) do if l.idx == e:EntIndex() then return true end end
		return false
	end
	local seen0 = A.stats.seen
	e:EmitSound(file, 75, 100, 1, CHAN_STATIC)
	job:sleep(0.3)
	local startMirror = mirrored()
	e:EmitSound(file, 75, 140, 1, CHAN_STATIC, SND_CHANGE_PITCH)
	job:sleep(0.2)
	local r = { seen = A.stats.seen - seen0, startMirror = startMirror, changeMirror = mirrored() }
	LP.Stop(e:EntIndex(), nil)
	e:StopSound(file)
	e:Remove()
	job:sleep(0.3)
	return r
end
local res = { checks = {} }
local saved = A.cfg.brief_updates
local ok, err = pcall(function()
	local on = run("vo/npc/male01/hi02.wav")
	A.cfg.brief_updates = 0
	local off = run("vo/npc/male01/hi01.wav")
	res.on, res.off = on, off
	res.checks.startNotMirror = not on.startMirror
	res.checks.changeNoMirror = not on.changeMirror
	res.checks.optionOff = off.changeMirror
end)
A.cfg.brief_updates = saved
if not ok then return { pass = false, err = tostring(err) } end
res.fails = {}
for k, v in SortedPairs(res.checks) do if not v then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
