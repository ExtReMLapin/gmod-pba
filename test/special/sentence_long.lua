-- A sentence longer than pba_max_duration behind a wall (Combine radio chatter: METROPOLICE_IDLE_CR12,
-- "on3 leadersreportratios off2", about 12 s of words). Why: sentences are relayed only through the
-- one-shot path, whose eligibility drops sounds longer than max_duration (SentenceDuration), and the
-- long-sound path never sees them (their hook name is "invalid.wav"): a long radio line is left to
-- the engine and crosses every wall.
-- Map: pba_tworooms (listener in room A, source in room B behind the wall). Realm: server (lua_job).
-- When SentenceDuration is not above max_duration, pba_max_duration is lowered below it for the test
-- (restored after), so that the long case is what gets measured.
-- Expected: pba takes the sentence (its hook returns false: relayed or followed), pba_sentences 1.
-- Returns { pass, taken, relayed, followed, duration, maxDuration }.
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
local NAME = "METROPOLICE_IDLE_CR12"
ply:SetPos(Vector(256, 256, 0))
local door = ents.FindByName("door1")[1]
if IsValid(door) then door:Fire("Close") end
local src = ents.Create("prop_dynamic")
src:SetModel("models/props_junk/popcan01a.mdl")
src:SetPos(Vector(784, 256, 40))
src:Spawn()
local oldMax, oldSent = GetConVar("pba_max_duration"):GetString(), GetConVar("pba_sentences"):GetString()
local dur = SentenceDuration(NAME) or 0
local hooks = hook.GetTable().EntityEmitSound
local orig = hooks and hooks.pba
local calls = {}
local ok, res = pcall(function()
	if not orig then return { err = "pba hook not installed" } end
	RunConsoleCommand("pba_sentences", "1")
	if dur <= pba.cfg.max_duration then RunConsoleCommand("pba_max_duration", tostring(math.max(0.5, dur - 1))) end
	job:sleep(1)
	hook.Add("EntityEmitSound", "pba", function(t)
		local orgName = t.OriginalSoundName
		local r = orig(t)
		if orgName == NAME or t.SoundName == "!" .. NAME then calls[#calls + 1] = { name = t.SoundName, ret = tostring(r) } end
		return r
	end)
	local r0, n0 = pba.stats.relayed, table.Count(pba.Loops.active)
	EmitSentence(NAME, src:GetPos(), src:EntIndex(), CHAN_VOICE, 1, 80, 0, 100)
	job:sleep(0.5)
	hook.Add("EntityEmitSound", "pba", orig)
	local taken = false
	for _, c in ipairs(calls) do if c.ret == "false" then taken = true end end
	return { taken = taken, relayed = pba.stats.relayed - r0, followed = table.Count(pba.Loops.active) - n0, calls = calls,
		duration = dur, maxDuration = pba.cfg.max_duration }
end)
if orig then hook.Add("EntityEmitSound", "pba", orig) end
RunConsoleCommand("pba_max_duration", oldMax)
RunConsoleCommand("pba_sentences", oldSent)
if IsValid(src) then src:Remove() end
if not ok then return { pass = false, err = tostring(res) } end
if res.err then res.pass = false return res end
if #res.calls == 0 then
	res.pass = nil
	res.note = "the sentence never reached EntityEmitSound: inconclusive"
	return res
end
res.pass = res.taken
res.expected = "taken = true (hook returned false: relayed or followed as a long sound)"
return res
