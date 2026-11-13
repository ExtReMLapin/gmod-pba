-- A CSoundPatch on a file WITHOUT loop points (server lua_job, any map, a human player). CSoundPatch:Play
-- reaches EntityEmitSound as SND_CHANGE_VOL (then SND_CHANGE_VOL + SND_CHANGE_PITCH), which the engine
-- turns into a start when that sound is not playing (S_StartDynamicSound falls through): the file plays
-- once and ends, the patch still "playing" for Lua. Neither a loop (no loop points) nor an eligible
-- one-shot (a change flag): pba left it unprocessed, heard through every wall (recorded on
-- ambient/machines/machine1_hit2.wav, 2.7 s).
-- Pass: taken over as a one-shot mirror (once) with subscribers, gone after the file's length, started
-- again by a later volume change (the engine restarts it then), and stopped with CSoundPatch:Stop.
local LP = pba.Loops
local SND = "ambient/machines/machine1_hit2.wav"
local ply = player.GetHumans()[1]
local e = ents.Create("prop_physics")
e:SetModel("models/props_junk/PopCan01a.mdl")
e:SetPos(ply:EyePos() + ply:GetForward() * 300)
e:Spawn()
job:sleep(0.3)
local function mirror()
	for _, l in pairs(LP.active) do if l.ent == e and l.name == SND then return l end end
end
local res = { checks = {} }
local dur = SoundDuration(SND)
local p = CreateSound(e, SND)
p:Play()
job:sleep(0.4)
local m = mirror()
res.checks.taken = m ~= nil and m.once == true
res.checks.subscribed = m ~= nil and table.Count(m.subs) > 0
job:sleep(dur + 1.2)
res.checks.endedWithFile = mirror() == nil
p:ChangeVolume(0.8, 0)
job:sleep(0.4)
res.checks.restarted = mirror() ~= nil
p:Stop()
job:sleep(0.3)
res.checks.stopped = mirror() == nil
e:Remove()
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
