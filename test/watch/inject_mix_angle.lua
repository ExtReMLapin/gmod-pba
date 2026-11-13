-- Validation only: re-creates the cl_mix bug fixed in 8a3858a (the own-sound path passed pba.ListenerPos()
-- whole, its eye angle landing in NoteSound's secs -> "RealTime() + Angle" on every own sound), to show the
-- watchdog's lua_error detector flags it.
local M = pba.Mix
if not M or M.pbaWatchInjected then return false end
M.pbaWatchInjected = true
local orig = M.NoteSound
M.NoteSound = function(data, L, secs)
	if secs == nil and data and data.Entity == LocalPlayer() then
		local _, ang = pba.ListenerPos()
		return RealTime() + ang -- the old failure, raised from the same call
	end
	return orig(data, L, secs)
end
-- the player makes his own sounds now and then (in play: footsteps, gunfire, the flashlight)
timer.Create("pba_watch_ownsound", 5, 0, function() if IsValid(LocalPlayer()) then LocalPlayer():EmitSound("items/flashlight1.wav", 60, 100, 1, CHAN_ITEM) end end)
return true
