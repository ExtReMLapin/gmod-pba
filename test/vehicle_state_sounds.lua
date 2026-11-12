-- Vehicle state sounds (server, lua_exec or lua_job): a quick throttle on / off must not leave a loop
-- playing. CBaseServerVehicle::PlayLoopingSound fades the current state sound out and destroys the one
-- still fading with a StopSound Lua never sees; the events below are the ones a jeep sends (recorded
-- in game: a Play is one SND_CHANGE_VOL + SND_CHANGE_PITCH update at volume 1, a fade volume-only steps).
-- Pass: the sound destroyed by the next Play is no longer taken over (LP.active), the playing ones are.
local LP = pba.Loops
local e = ents.Create("prop_vehicle_jeep")
e:SetModel("models/buggy.mdl")
e:SetKeyValue("vehiclescript", "scripts/vehicles/jeep_test.txt")
e:SetPos(Vector(0, 0, 4000))
e:Spawn()
e:Activate()
local idx = e:EntIndex()
local A, B, C = "vehicles/v8/v8_start_loop1.wav", "vehicles/v8/v8_idle_loop1.wav", "vehicles/v8/v8_rev_short_loop1.wav"
local function ev(name, flags, vol)
	LP.Handle({ Entity = e, SoundName = name, OriginalSoundName = name, Channel = CHAN_STATIC, Flags = flags,
		Volume = vol, Pitch = 100, SoundLevel = 80, DSP = 0 })
end
local function play(name) ev(name, SND_CHANGE_VOL, 1) ev(name, SND_CHANGE_VOL + SND_CHANGE_PITCH, 1) end
local function active(name) return LP.active[idx .. ":" .. CHAN_STATIC .. ":" .. name] ~= nil end
local res = { checks = {} }
play(A)
play(B)
ev(A, SND_CHANGE_VOL, 0.94) -- A starts fading
play(C) -- before A's fade ends: A destroyed, B fades
ev(B, SND_CHANGE_VOL, 0.94)
res.checks.fadingDestroyed = not active(A)
res.checks.playing = active(B) and active(C)
play(C) -- the same sound again (re-used at full volume): the fading B is destroyed
res.checks.reuseDestroysFade = not active(B) and active(C)
LP.Stop(idx, nil)
e:Remove()
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
