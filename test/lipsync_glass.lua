-- Lip sync of a voice pba re-emits: a citizen speaks behind the glass cell of pba_materials (seen,
-- heard through the glass). The client animates the mouth from the voices playing ON the entity; a
-- copy played on an anchor or by the native module leaves the mouth still. Server half: speaks twice,
-- pba off then on; the client half (lipsync_client.lua) has recorded the jaw opening of each phase.
-- lua_job, server realm, pba_materials. Returns { phases }.
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_materials" then return { err = "needs pba_materials with a human" } end
local X = 4 * 272 + 128 -- glass cell
ply:SetPos(Vector(X, 128, 0))
ply:SetEyeAngles(Angle(0, 90, 0))
local npc = ents.Create("npc_citizen")
npc:SetPos(Vector(X, 400, 0))
npc:SetAngles(Angle(0, 270, 0))
npc:Spawn()
job:sleep(1)
ply:SetEyeAngles((npc:EyePos() - ply:EyePos()):Angle())
ply:SendLua([[pba._lip = { phase = "", max = {} }
hook.Add("Think", "pba_test_lip", function()
	local L = pba._lip
	if L.phase == "" then return end
	for _, e in ipairs(ents.FindByClass("npc_citizen")) do
		local id = e:GetFlexIDByName("jaw_drop")
		if id then L.max[L.phase] = math.max(L.max[L.phase] or 0, e:GetFlexWeight(id)) end
	end
end)]])
local old = GetConVar("pba_enable"):GetString()
local LINE = "vo/npc/male01/question06.wav"
local function speak(phase, enable)
	RunConsoleCommand("pba_enable", enable)
	job:sleep(0.5)
	ply:SendLua("pba._lip.phase = '" .. phase .. "'")
	npc:EmitSound(LINE, 75, 100, 1, CHAN_VOICE)
	job:sleep(2.5)
	ply:SendLua("pba._lip.phase = ''")
	job:sleep(0.5)
end
speak("vanilla", "0")
speak("pba", "1")
RunConsoleCommand("pba_enable", old)
npc:Remove()
job:sleep(0.3)
ply:SendLua([[hook.Remove("Think", "pba_test_lip")]])
return { ok = true }
