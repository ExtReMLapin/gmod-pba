-- A NEW sound emitted with SND_CHANGE_PITCH / SND_CHANGE_VOL (parity plan P2-18: a scene line with a pitch other
-- than 1; EmitSound(..., SND_CHANGE_PITCH) on a sound nobody plays): the engine starts it. A.Eligible refused every
-- change flag, so when sv_loops did not follow it (pba_patch_oneshots 0, the loops cap reached) it played through
-- the wall unmuffled. pba_change_new relays it as any new sound when nothing of that name plays on its entity;
-- the real change of a playing sound stays the engine's / dropped (brief_change, commit b5139cb).
-- Server lua_job, pba_tworooms with a human (moved to room A); a prop in room B behind the shared wall.
-- Pass: with patch_oneshots 0 and with the loops cap at 0, a new flag-2 / flag-1 sound is relayed (relayed +1,
-- no mirror), a later pitch change of it starts nothing (no mirror, no second relay); with the
-- default settings it is still followed as a patch start; with pba_change_new 0 the engine plays it again (no relay, no mirror).
local A, LP = pba, pba.Loops
local ply = player.GetHumans()[1]
if not (LP and IsValid(ply)) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms, pba loops and a human" } end
ply:SetPos(Vector(24, 24, 0))
local BEHIND = Vector(1000, 480, 40)
local function run(file, flags)
	local e = ents.Create("prop_physics")
	e:SetModel("models/props_junk/popcan01a.mdl")
	e:SetPos(BEHIND)
	e:Spawn()
	local phys = e:GetPhysicsObject()
	if IsValid(phys) then phys:EnableMotion(false) end
	job:sleep(0.3)
	local function mirrored()
		for _, l in pairs(LP.active) do if l.idx == e:EntIndex() then return true end end
		return false
	end
	local r0, un0 = A.stats.relayed or 0, A.stats.untouched or 0
	e:EmitSound(file, 75, 120, 1, CHAN_STATIC, flags)
	job:sleep(0.3)
	local r = { relayed = (A.stats.relayed or 0) - r0, untouched = (A.stats.untouched or 0) - un0, mirror = mirrored() }
	local r1, un1 = A.stats.relayed or 0, A.stats.untouched or 0
	e:EmitSound(file, 75, 150, 1, CHAN_STATIC, SND_CHANGE_PITCH) -- a real change, while it plays
	job:sleep(0.3)
	r.changeRelayed, r.changeUntouched, r.changeMirror = (A.stats.relayed or 0) - r1, (A.stats.untouched or 0) - un1, mirrored()
	LP.Stop(e:EntIndex(), nil)
	e:StopSound(file)
	e:Remove()
	job:sleep(0.4)
	return r
end
local res = { checks = {} }
local sv = { patch_oneshots = A.cfg.patch_oneshots, loops_max = A.cfg.loops_max, change_new = A.cfg.change_new }
local ok, err = pcall(function()
	res.default = run("vo/npc/male01/answer01.wav", SND_CHANGE_PITCH)
	A.cfg.patch_oneshots = 0
	res.noPatch = run("vo/npc/male01/answer02.wav", SND_CHANGE_PITCH)
	res.noPatchVol = run("vo/npc/male01/answer03.wav", SND_CHANGE_VOL)
	A.cfg.patch_oneshots = sv.patch_oneshots
	A.cfg.loops_max = 0
	res.capped = run("vo/npc/male01/answer04.wav", SND_CHANGE_PITCH)
	A.cfg.loops_max = sv.loops_max
	A.cfg.patch_oneshots = 0
	A.cfg.change_new = 0
	res.off = run("vo/npc/male01/answer05.wav", SND_CHANGE_PITCH)
	local c = res.checks
	c.defaultFollowed = res.default.mirror
	for _, k in ipairs({ "noPatch", "noPatchVol", "capped" }) do
		local r = res[k]
		c[k .. "Relayed"] = r.relayed >= 1 and not r.mirror
		c[k .. "ChangeKept"] = not r.changeMirror and r.changeRelayed == 0
	end
	c.optionOff = res.off.relayed == 0 and not res.off.mirror
end)
for k, v in pairs(sv) do A.cfg[k] = v end
if not ok then return { pass = false, err = tostring(err) } end
res.fails = {}
for k, v in SortedPairs(res.checks) do if not v then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
