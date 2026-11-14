-- Client lua_job (propagation_delay.py): one sound of a prop (DL.idx, at DL.S) played through the whole
-- pipeline (A.Process) for the listener standing at DL.L (feet), and the delay the pipeline gave its copy:
-- the start time of the copy it registered (native voice or engine copy) minus the time of the call.
-- Returns JSON { taken, n (copies registered), delay (s), len (path length of the first voice, units),
-- clear (the line is free), native (the copy is a native voice) }.
local A = pba
local S = Vector(unpack(DL.S))
job:wait(function() return A.ListenerPos():Distance(Vector(DL.L[1], DL.L[2], DL.L[3] + 64)) < 8 end)
-- the sound decoded first (pba_native_predecode, on by default: the first play of a sound not decoded yet
-- is left to the engine, and this test measures the delay of the copy pba registers)
local N = A.Native
if N and N.render and N.EnsureSound then job:wait(function() return N.EnsureSound("buttons/button14.wav") end, 10) end
A.Paths.InvalidateCache()
A.Paths.cache, A.Paths.timeMemo = {}, {}
A.emitted[DL.idx] = nil
local tReq = RealTime()
local taken = A.Process({ SoundName = "buttons/button14.wav", Pos = S, EntIndex = DL.idx, SoundLevel = 75, Volume = 1, Pitch = 100,
	Channel = CHAN_AUTO, Flags = 0, DSP = 0 })
local out = { taken = taken and true or false }
local hs = A.emitted[DL.idx] or {}
out.n = #hs
if hs[1] then out.delay = hs[1].t0 - tReq out.native = hs[1].id ~= nil end
local r = A.Paths.Compute(S, A.ListenerPos(), 75)
out.clear = r.clear and true or false
out.len = r.voices and r.voices[1] and r.voices[1].len or nil
return util.TableToJSON(out)
