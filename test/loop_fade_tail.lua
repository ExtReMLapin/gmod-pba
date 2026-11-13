-- A C++ fade to silence stops its sound one step above 0 (server lua_job, any map): CSoundPatch
-- FadeOut / SoundFadeOut test their deadline before the ramp's last update, then StopSound without any
-- event (SDK soundenvelope.cpp). Recorded in game on the jeep's gauss charge (EnableGun, attack2 held
-- 1.5 s): volume 1.00 -> 0.55 -> 0.10 at pitch 159, then nothing; the mirror stayed at 10 % for good.
-- Pass: after such a fade the mirror is at 0 within 0.5 s; a ramp that ends ABOVE one step (ChangeVolume
-- to 0.5) keeps its volume; a fade that does reach 0 is untouched.
local LP = pba.Loops
local NAME = "weapons/gauss/chargeloop.wav"
local e = ents.Create("prop_physics")
e:SetModel("models/props_junk/wood_crate001a.mdl")
e:SetPos(Vector(0, 0, 4000))
e:Spawn()
local key = e:EntIndex() .. ":" .. CHAN_STATIC .. ":" .. NAME
local function ev(vol, pitch, flags)
	LP.Handle({ Entity = e, SoundName = NAME, OriginalSoundName = NAME, Channel = CHAN_STATIC,
		Flags = flags or (SND_CHANGE_VOL + SND_CHANGE_PITCH), Volume = vol, Pitch = pitch, SoundLevel = 80, DSP = 0 })
end
local function vol() local l = LP.active[key] return l and l.vol end
local res = { checks = {} }
ev(1, 100, SND_CHANGE_VOL) -- start
ev(1, 159)
job:sleep(0.1)
ev(0.55, 159) job:frames(1) ev(0.10, 159)
job:sleep(0.5)
res.tail = vol()
res.checks.tailSilenced = res.tail == 0
ev(1, 100)
job:sleep(0.1)
ev(0.85, 100) job:frames(1) ev(0.7, 100) job:frames(1) ev(0.5, 100)
job:sleep(0.5)
res.held = vol()
res.checks.rampTargetKept = res.held == 0.5
LP.Stop(e:EntIndex(), nil)
e:Remove()
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
