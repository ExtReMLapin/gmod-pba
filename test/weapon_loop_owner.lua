-- Loops of a weapon a player holds (server, lua_exec or lua_job): the gravity gun's hold loop is a
-- CSoundPatch on the WEAPON (weapon_physcannon), raised / faded and finally destroyed by its C++ with a
-- StopSound Lua never sees. Like the player's own loops, it is left to the engine: a mirror on the weapon
-- played it to its holder as a foreign source (reverb, Doppler) and could outlive the C++ destroy.
-- Events are the ones recorded in game (pick up: volume / pitch ramp, SND_CHANGE_VOL + SND_CHANGE_PITCH).
-- Pass: no take-over for a held weapon; a weapon lying on the ground (no owner) is still taken over.
local LP = pba.Loops
local ply = player.GetHumans()[1]
local NAME = ")weapons/physcannon/hold_loop.wav"
local function ramp(e)
	local taken = false
	for i, v in ipairs({ 0, 0.24, 0.55, 0.8 }) do
		local r = LP.Handle({ Entity = e, SoundName = NAME, OriginalSoundName = NAME, Channel = CHAN_STATIC,
			Flags = i == 1 and SND_CHANGE_VOL or SND_CHANGE_VOL + SND_CHANGE_PITCH, Volume = v, Pitch = 50 + v * 62,
			SoundLevel = 75, DSP = 0 })
		taken = taken or r
	end
	local key = e:EntIndex() .. ":" .. CHAN_STATIC .. ":" .. NAME
	local active = LP.active[key] ~= nil
	LP.Stop(e:EntIndex(), nil)
	return taken or active
end
local held = ply:Give("weapon_physcannon")
if not IsValid(held) then held = ply:GetWeapon("weapon_physcannon") end
local res = { checks = {} }
res.checks.heldLeftToEngine = IsValid(held) and held:GetOwner() == ply and not ramp(held)
local ground = ents.Create("weapon_physcannon")
ground:SetPos(ply:GetPos() + Vector(0, 0, 4000))
ground:Spawn()
res.checks.groundTakenOver = not IsValid(ground:GetOwner()) and ramp(ground)
ground:Remove()
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
