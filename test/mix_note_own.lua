-- Mixer ducker fed from the own-sound path (client, lua_exec): pba.ListenerPos() returns the position AND the
-- eye angle; passed straight into Mix.NoteSound, the angle landed in `secs` and RealTime() + Angle raised
-- "bad argument #1 to '__add' (Angle expected, got number)" on every own sound (user report 2026-11-13).
-- Pass: NoteSound called exactly as the own-sound path calls it raises nothing, and a non-number `secs`
-- falls back to the sound's duration.
local A = pba
if not (A and A.Mix and A.Mix.NoteSound) then return { pass = false, err = "cl_mix not loaded" } end
local res = { checks = {} }
local data = { SoundName = "weapons/pistol/pistol_fire2.wav", Pos = A.ListenerPos() + Vector(100, 0, 0), SoundLevel = 90,
	Volume = 1, Channel = CHAN_WEAPON, Entity = LocalPlayer() }
local ok1, e1 = pcall(A.Mix.NoteSound, data, A.ListenerPos())
res.checks.ownPathNoError = ok1
res.err1 = not ok1 and tostring(e1) or nil
local ok2, e2 = pcall(A.Mix.NoteSound, data, A.ListenerPos(), Angle(1, 2, 3))
res.checks.badSecsNoError = ok2
res.err2 = not ok2 and tostring(e2) or nil
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
