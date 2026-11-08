-- Moving-brush loop stopped by the engine's C++ (func_door noise1 with loop points): the server
-- mirror (pba.Loops.active) must disappear once the door has arrived.
-- lua_job, server realm, on pba_demo (garage shutter). Returns { pass, seen, activeWhileMoving, activeAfter }.
local NAME = "plats/rackmove1.wav" -- has loop points
local d = ents.FindByName("pba_garage_shutter")[1]
if not IsValid(d) then return { pass = false, err = "no pba_garage_shutter (load pba_demo)" } end
-- the demo starts in mode A (vanilla: pba off): mode B for the test, restored at the end
local DM = pba.DemoMap
local oldMode = DM and DM.mode
if DM and DM.mode == 1 then DM.SetMode(2) job:wait(function() return pba.hooksInstalled end, 3) end
local oldNoise = d:GetInternalVariable("m_NoiseMoving")
local oldSpeed = d:GetInternalVariable("m_flSpeed")
util.PrecacheSound(NAME)
d:SetKeyValue("noise1", NAME)
d:SetKeyValue("speed", "80") -- 2 s travel
local seen = {}
hook.Add("EntityEmitSound", "pba_test_brushloop", function(t)
	if t.Entity == d then seen[#seen + 1] = string.format("%s flags=%d chan=%d", t.SoundName, t.Flags or 0, t.Channel or -1) end
end)
local function count()
	local n = 0
	for _, l in pairs(pba.Loops.active) do if l.ent == d and l.name == NAME then n = n + 1 end end
	return n
end
-- start closed
if d:GetInternalVariable("m_toggle_state") ~= 1 then d:Fire("Close") job:sleep(4) end
local before = count()
d:Fire("Open")
job:sleep(0.5)
local moving = count()
job:wait(function() return d:GetInternalVariable("m_toggle_state") == 0 end, 10)
job:sleep(1.5) -- the 0.5 s loops timer had time to act
local after = count()
d:Fire("Close")
job:wait(function() return d:GetInternalVariable("m_toggle_state") == 1 end, 10)
job:sleep(1.5)
local afterClose = count()
hook.Remove("EntityEmitSound", "pba_test_brushloop")
d:SetKeyValue("noise1", oldNoise)
d:SetKeyValue("speed", tostring(oldSpeed))
if DM and oldMode and DM.mode ~= oldMode then DM.SetMode(oldMode) end
return { pass = moving == 1 and after == 0 and afterClose == 0, before = before, activeWhileMoving = moving,
	activeAfterOpen = after, activeAfterClose = afterClose, seen = seen }
