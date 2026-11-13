-- mouth_stop, client half 1 (after scene_cancel_setup.lua): the relayed line of the scene has its mouth copy
-- on the speaker (cl_render mouthCopy). The engine calls that stop the copy are watched from now on: the
-- original StopSound of an entity and EmitSound with SND_STOP, on the speaker's index.
local idx = GetGlobalInt("pba_test_sc_idx")
local rec = { n = 0 }
pba._msRec = rec
local ENT = FindMetaTable("Entity")
local origStop = pba.origCl and pba.origCl.StopSound or ENT.StopSound
local origEmit = EmitSound
pba._msRestore = function()
	if pba.origCl then pba.origCl.StopSound = origStop end
	EmitSound = origEmit
end
if pba.origCl then
	pba.origCl.StopSound = function(e, name, ...)
		if IsValid(e) and e:EntIndex() == idx then rec.n = rec.n + 1 end
		return origStop(e, name, ...)
	end
end
EmitSound = function(name, pos, i, ch, vol, lvl, flags, ...)
	if i == idx and bit.band(flags or 0, SND_STOP) ~= 0 then rec.n = rec.n + 1 end
	return origEmit(name, pos, i, ch, vol, lvl, flags, ...)
end
local mouths = pba.stats.mouthCopies or 0
return { pass = mouths > 0, mouthCopies = mouths, ent = IsValid(Entity(idx)) }
