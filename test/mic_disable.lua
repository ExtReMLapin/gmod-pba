-- env_microphone Disable (audit B-12). A microphone routes what it hears to its speaker; Disable stops the
-- speaker's copy in C++ (StopSound on the last routed sound, never seen by Lua). In vanilla it is the ONLY
-- stop of a looped / long copy on the speaker (the original's SND_STOP has volume 0: the microphone does not
-- route it). pba's mirror of the speaker copy never stopped.
-- Server lua_job, any map with a human: an info_target speaker, an env_microphone routing to it and a looped
-- ambient_generic in its range.
-- Pass: the speaker mirror exists before Disable and is gone 1 s after; the source's own mirror stays;
-- with pba_loops_mic_disable 0 the speaker mirror stays (the old behaviour).
local LP = pba.Loops
local ply = player.GetHumans()[1]
if not (LP and IsValid(ply)) then return { pass = false, err = "needs pba loops and a human" } end
local function run(tag)
	local base = ply:GetPos() + Vector(0, 0, 40)
	local spk = ents.Create("info_target")
	spk:SetName("pba_test_spk_" .. tag)
	spk:SetPos(base + Vector(600, 0, 0))
	spk:Spawn()
	local mic = ents.Create("env_microphone")
	mic:SetPos(base + Vector(-600, 0, 0))
	mic:SetKeyValue("SpeakerName", "pba_test_spk_" .. tag)
	mic:SetKeyValue("Sensitivity", "1")
	mic:SetKeyValue("MaxRange", "400")
	mic:SetKeyValue("spawnflags", "1")
	mic:Spawn()
	mic:Activate()
	local amb = ents.Create("ambient_generic")
	amb:SetPos(base + Vector(-550, 0, 0))
	amb:SetKeyValue("message", "ambient/machines/spin_loop.wav")
	amb:SetKeyValue("health", "10")
	amb:SetKeyValue("radius", "1250")
	amb:SetKeyValue("spawnflags", "16")
	amb:Spawn()
	amb:Activate()
	job:sleep(0.3)
	amb:Fire("PlaySound")
	job:sleep(1)
	local function has(e)
		for _, l in pairs(LP.active) do if l.idx == e:EntIndex() then return true end end
		return false
	end
	local r = { spkBefore = has(spk), ambBefore = has(amb) }
	mic:Fire("Disable")
	job:sleep(1)
	r.spkAfter, r.ambAfter = has(spk), has(amb)
	amb:Fire("StopSound")
	job:sleep(0.3)
	for _, e in ipairs({ spk, mic, amb }) do if IsValid(e) then e:Remove() end end
	job:sleep(0.3)
	return r
end
local res = { checks = {} }
local saved = pba.cfg.loops_mic_disable
local ok, err = pcall(function()
	local on = run("on")
	pba.cfg.loops_mic_disable = 0
	local off = run("off")
	res.on, res.off = on, off
	res.checks.speakerMirrored = on.spkBefore
	res.checks.speakerStopped = not on.spkAfter
	res.checks.sourceKept = on.ambBefore and on.ambAfter
	res.checks.optionOff = off.spkBefore and off.spkAfter
end)
pba.cfg.loops_mic_disable = saved
if not ok then return { pass = false, err = tostring(err) } end
res.fails = {}
for k, v in SortedPairs(res.checks) do if not v then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
