-- audioprop phase 0 probe: logs every EntityEmitSound in this realm, plus detours of
-- the Lua sound entry points that bypass the hook. Optional suppression test.
AP_PROBE = AP_PROBE or {}
local P = AP_PROBE
P.log = {}
P.suppress = P.suppress or nil -- pattern: return false for matching sounds
P.realm = SERVER and "server" or "client"

local function add(kind, name, extra)
	extra = extra or {}
	extra.kind = kind
	extra.name = name
	extra.t = RealTime()
	P.log[#P.log + 1] = extra
end
P.add = add

hook.Add("EntityEmitSound", "audioprop_probe", function(t)
	local e = t.Entity
	add("hook", t.SoundName, {
		orig = t.OriginalSoundName,
		ent = IsValid(e) and e:GetClass() or (e == game.GetWorld() and "worldspawn" or tostring(e)),
		chan = t.Channel, lvl = t.SoundLevel, vol = t.Volume, dsp = t.DSP, st = t.SoundTime,
		pos = t.Pos and tostring(t.Pos) or nil, flags = t.Flags,
	})
	if P.suppress and string.find(t.SoundName, P.suppress, 1, true) then
		return false
	end
end)

-- Detours (kept idempotent on reload)
P.orig = P.orig or {
	CreateSound = CreateSound,
	soundPlay = sound.Play,
	EmitSound = EmitSound,
	surfacePlaySound = surface and surface.PlaySound,
}
CreateSound = function(ent, name, filter)
	add("CreateSound", name, { ent = IsValid(ent) and ent:GetClass() or tostring(ent) })
	return P.orig.CreateSound(ent, name, filter)
end
sound.Play = function(name, pos, ...)
	add("sound.Play", name, { pos = tostring(pos) })
	return P.orig.soundPlay(name, pos, ...)
end
EmitSound = function(name, ...)
	add("EmitSound(global)", name)
	return P.orig.EmitSound(name, ...)
end
if CLIENT and P.orig.surfacePlaySound then
	surface.PlaySound = function(name)
		add("surface.PlaySound", name)
		return P.orig.surfacePlaySound(name)
	end
end

function P.restore()
	hook.Remove("EntityEmitSound", "audioprop_probe")
	CreateSound = P.orig.CreateSound
	sound.Play = P.orig.soundPlay
	EmitSound = P.orig.EmitSound
	if CLIENT then surface.PlaySound = P.orig.surfacePlaySound end
end

return P.realm .. " probe ready"
