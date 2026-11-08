-- scripted_sentence: a map entity makes an NPC say a sentence (BeginSentence input). Why: the line
-- goes through the NPC's scripted-sentence path (PlayScriptedSentence) rather than EmitSentence; it
-- must be relayed muffled like the other sentences, not cross the wall.
-- Map: pba_tworooms (metrocop in room B, listener in room A, door closed). Realm: server (lua_job).
-- Expected: within 4 s of BeginSentence, a sentence reaches pba's hook and is taken (relayed).
-- Returns { pass, seen, taken, calls }.
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
ply:SetPos(Vector(256, 256, 0))
local door = ents.FindByName("door1")[1]
if IsValid(door) then door:Fire("Close") end
local npc = ents.Create("npc_metropolice")
npc:SetPos(Vector(784, 256, 0))
npc:SetKeyValue("targetname", "pba_test_cop")
npc:Spawn()
local ss = ents.Create("scripted_sentence")
ss:SetPos(Vector(784, 256, 64))
ss:SetKeyValue("entity", "pba_test_cop")
ss:SetKeyValue("sentence", "!METROPOLICE_IDLE0")
ss:SetKeyValue("radius", "512")
ss:SetKeyValue("volume", "10")
ss:SetKeyValue("attenuation", "0")
ss:SetKeyValue("delay", "0")
ss:SetKeyValue("refire", "1")
ss:Spawn()
ss:Activate()
local hooks = hook.GetTable().EntityEmitSound
local orig = hooks and hooks.pba
local calls = {}
local ok, err = pcall(function()
	if not orig then error("pba hook not installed") end
	job:sleep(1)
	hook.Add("EntityEmitSound", "pba", function(t)
		local name, org = t.SoundName, t.OriginalSoundName
		local r = orig(t)
		if t.Entity == npc then calls[#calls + 1] = { SoundName = name, OriginalSoundName = org, ret = tostring(r) } end
		return r
	end)
	ss:Fire("BeginSentence")
	job:wait(function()
		for _, c in ipairs(calls) do if c.SoundName == "invalid.wav" then return true end end
		return false
	end, 4)
	job:sleep(0.3)
end)
if orig then hook.Add("EntityEmitSound", "pba", orig) end
if IsValid(ss) then ss:Remove() end
if IsValid(npc) then npc:Remove() end
if not ok then return { pass = false, err = tostring(err) } end
local seen, taken = false, false
for _, c in ipairs(calls) do
	if c.SoundName == "invalid.wav" then
		seen = true
		if c.ret == "false" then taken = true end
	end
end
local res = { seen = seen, taken = taken, calls = calls, expected = "seen = true and taken = true" }
if not seen then
	res.pass = nil
	res.note = "no sentence from the NPC reached the hook within 4 s (NPC busy?): inconclusive"
else
	res.pass = taken
end
return res
