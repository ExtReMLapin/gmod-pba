-- Lip sync of a voice pba re-emits: a citizen speaks behind the glass cell of pba_materials (seen,
-- heard through the glass). The client animates the mouth from the voices playing ON the entity; a
-- copy played on an anchor or by the native module leaves the mouth still, so pba plays the line on the
-- speaker at an inaudible volume (cl_render mouthCopy, pba_lipsync). Server half: speaks twice, pba off then
-- on; the client half (lipsync_client.lua) has counted the mouth copies of each phase. (The jaw opening once
-- measured here proved nothing: GetFlexWeight reads the server's flexes, the AI's expressions; the lip sync
-- is applied at render time on the client and Lua cannot read it.)
-- lua_job, server realm, pba_materials. Returns { pass, taken = { vanilla, pba } }: the server's own share
-- of the A/B: pass = the citizen was spawned and pba really took the line over behind the glass
-- (relayed or re-emitted muffled: stats.relayed + stats.relayMuffled grow) with pba on, and nothing was
-- taken with pba off. Without that the client half compares two vanilla playbacks and proves nothing.
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_materials" then return { pass = false, err = "needs pba_materials with a human" } end
local X = 4 * 272 + 128 -- glass cell
ply:SetPos(Vector(X, 128, 0))
ply:SetEyeAngles(Angle(0, 90, 0))
local npc = ents.Create("npc_citizen")
npc:SetPos(Vector(X, 400, 0))
npc:SetAngles(Angle(0, 270, 0))
npc:Spawn()
job:sleep(1)
ply:SetEyeAngles((npc:EyePos() - ply:EyePos()):Angle())
ply:SendLua([[pba._lip = { phase = "", max = {}, base = pba.stats.mouthCopies or 0 }
hook.Add("Think", "pba_test_lip", function()
	local L = pba._lip
	if L.phase == "" then return end
	-- copies counted up to the end of each phase (the relayed line and the phase's SendLua travel on two
	-- channels: either may arrive first)
	L.mcEnd = L.mcEnd or {}
	L.mcEnd[L.phase] = pba.stats.mouthCopies or 0
end)]])
local old = GetConVar("pba_enable"):GetString()
local LINE = "vo/npc/male01/question06.wav"
local taken = {}
local function nTaken() return (pba.stats.relayed or 0) + (pba.stats.relayMuffled or 0) end
local function speak(phase, enable)
	RunConsoleCommand("pba_enable", enable)
	job:sleep(0.5)
	ply:SendLua("pba._lip.phase = '" .. phase .. "'")
	local t0 = nTaken()
	npc:EmitSound(LINE, 75, 100, 1, CHAN_VOICE)
	job:sleep(2.5)
	taken[phase] = nTaken() - t0
	ply:SendLua("pba._lip.phase = ''")
	job:sleep(0.5)
end
local spawned = IsValid(npc)
speak("vanilla", "0")
speak("pba", "1")
RunConsoleCommand("pba_enable", old)
npc:Remove()
job:sleep(0.3)
ply:SendLua([[hook.Remove("Think", "pba_test_lip")]])
return { pass = spawned and taken.vanilla == 0 and taken.pba >= 1, taken = taken, spawned = spawned }
