-- Volume / pitch change of a brief sound already playing (audit B-8). An ambient_generic that is not looped
-- (spawnflag 32) with a preset, LFO or Pitch / Volume inputs, a func_rotating or func_tracktrain with a
-- non-looped move sound send SND_CHANGE_* updates for a brief sound already playing.
-- * pba took its start over (relayed / re-emitted): the update either went to the engine, which STARTED a
--   vanilla copy midway at the players who got pba's copy (no channel matched), or (since
--   pba_patch_oneshots) was taken as a patch start: a second, muffled copy from the top.
-- * the engine plays it (untouched: in plain sight beyond lod_dist, or in multiplayer when no player is
--   blocked): the update is the engine's (it changes its own copy); pba_patch_oneshots took it as a patch
--   start all the same: a second copy from the top.
-- Server lua_job, pba_tworooms with a human (moved to room A). A brief line is emitted on a prop, then a
-- pitch change 0.3 s later (lines over 1 s: the change comes while they play); the prop in room B behind the
-- shared wall (taken over), then in room A in plain sight 660 u away with lod_dist 500 (left to the engine,
-- untouched; lod_dist restored).
-- Pass: no start is taken as a loop mirror; no change starts a mirror in either case; with
-- pba_brief_updates 0 the change of the taken-over one starts a mirror again (the old behaviour).
local A, LP = pba, pba.Loops
local ply = player.GetHumans()[1]
if not (LP and IsValid(ply)) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms, pba loops and a human" } end
ply:SetPos(Vector(24, 24, 0))
local BEHIND, CLEAR = Vector(1000, 480, 40), Vector(490, 490, 40)
local function run(file, pos)
	local e = ents.Create("prop_physics")
	e:SetModel("models/props_junk/popcan01a.mdl")
	e:SetPos(pos)
	e:Spawn()
	local phys = e:GetPhysicsObject()
	if IsValid(phys) then phys:EnableMotion(false) end
	job:sleep(0.3)
	local function mirrored()
		for _, l in pairs(LP.active) do if l.idx == e:EntIndex() then return true end end
		return false
	end
	local seen0, un0 = A.stats.seen, A.stats.untouched
	e:EmitSound(file, 75, 100, 1, CHAN_STATIC)
	job:sleep(0.3)
	local startMirror = mirrored()
	local untouched = A.stats.untouched - un0
	e:EmitSound(file, 75, 140, 1, CHAN_STATIC, SND_CHANGE_PITCH)
	job:sleep(0.2)
	local r = { seen = A.stats.seen - seen0, untouched = untouched, startMirror = startMirror, changeMirror = mirrored() }
	LP.Stop(e:EntIndex(), nil)
	e:StopSound(file)
	e:Remove()
	job:sleep(0.3)
	return r
end
local res = { checks = {} }
local saved = A.cfg.brief_updates
local ok, err = pcall(function()
	local on = run("vo/npc/male01/answer01.wav", BEHIND)
	local lod0 = GetConVar("pba_lod_dist"):GetFloat()
	RunConsoleCommand("pba_lod_dist", "500")
	job:sleep(0.2)
	local engine = run("vo/npc/male01/answer02.wav", CLEAR)
	RunConsoleCommand("pba_lod_dist", tostring(lod0))
	job:sleep(0.2)
	A.cfg.brief_updates = 0
	local off = run("vo/npc/male01/answer04.wav", BEHIND)
	res.on, res.engine, res.off = on, engine, off
	res.checks.takenBehind = on.untouched == 0
	res.checks.engineUntouched = engine.untouched >= 1
	res.checks.startNotMirror = not on.startMirror and not engine.startMirror
	res.checks.changeNoMirror = not on.changeMirror
	res.checks.engineChangeNoMirror = not engine.changeMirror
	res.checks.optionOff = off.changeMirror
end)
A.cfg.brief_updates = saved
if not ok then return { pass = false, err = tostring(err) } end
res.fails = {}
for k, v in SortedPairs(res.checks) do if not v then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
