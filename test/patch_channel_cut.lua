-- A C++ sound patch started on a replacing channel cuts what the entity plays there (audit B-16, pba_patch_channel_cut).
-- A CSoundPatch's Play reaches EntityEmitSound as a SND_CHANGE_VOL + SND_CHANGE_PITCH update on a sound that is not
-- playing, which the engine turns into a new sound ON ITS CHANNEL (CHAN_VOICE for the NPCs' own patches), replacing what
-- played there. sh_core's channel rule excludes the CHANGE_* flags, so sv_loops kept the old mirror (a speech line
-- followed through the walls) running over the new patch. Lua's CreateSound plays on CHAN_AUTO: the same event is
-- made with Entity:EmitSound and the change flags on CHAN_VOICE.
-- Server lua_job, pba_tworooms with a human. Pass: with the old line followed on CHAN_VOICE, a new loop with the flags
--   0 (control)                      cuts the line;
--   CHANGE_VOL + CHANGE_PITCH        cuts the line (the patch start);
--   the same + DO_NOT_OVERWRITE      keeps it;
--   a change of the playing line itself (same name)  keeps it (a real change is not a start);
-- and the new loop is followed in each case.
local A = pba
local LP = A.Loops
if not (IsValid(player.GetHumans()[1]) and LP) then return { pass = false, err = "needs a human and pba loops" } end
local LONG = "music/hl2_song12_long.mp3"
local PATCH = "ambient/machines/spin_loop.wav"
local CHANGE = SND_CHANGE_VOL + SND_CHANGE_PITCH
local NO_OVERWRITE = SND_DO_NOT_OVERWRITE_EXISTING_ON_CHANNEL or 1024
local e = ents.Create("prop_physics")
e:SetModel("models/props_junk/popcan01a.mdl")
e:SetPos(Vector(256, 300, 40))
e:Spawn()
local phys = e:GetPhysicsObject()
if IsValid(phys) then phys:EnableMotion(false) end
job:sleep(0.2)
local idx = e:EntIndex()
local function find(name)
	for k, l in pairs(LP.active) do if l.idx == idx and l.name == name then return k end end
end
local function try(newName, flags)
	LP.Stop(idx, nil)
	e:StopSound(LONG) e:StopSound(PATCH)
	e:EmitSound(LONG, 75, 100, 1, CHAN_VOICE)
	local old = find(LONG)
	if not old then return { taken = false } end
	e:EmitSound(newName, 75, 100, 1, CHAN_VOICE, flags)
	local r = { taken = true, oldAlive = find(LONG) ~= nil, newFollowed = find(newName) ~= nil }
	LP.Stop(idx, nil)
	e:StopSound(LONG) e:StopSound(PATCH)
	return r
end
local res = {}
local ok, err = pcall(function()
	res.plain = try(PATCH, 0)
	res.patchStart = try(PATCH, CHANGE)
	res.noOverwrite = try(PATCH, CHANGE + NO_OVERWRITE)
	res.sameName = try(LONG, CHANGE)
end)
LP.Stop(idx, nil)
if IsValid(e) then e:Remove() end
if not ok then return { pass = false, err = tostring(err) } end
res.pass = res.plain.taken and not res.plain.oldAlive and res.plain.newFollowed
	and res.patchStart.taken and not res.patchStart.oldAlive and res.patchStart.newFollowed
	and res.noOverwrite.taken and res.noOverwrite.oldAlive
	and res.sameName.taken and res.sameName.oldAlive
return res
