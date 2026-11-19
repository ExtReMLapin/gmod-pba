-- A long line on a speaker (SND_SPEAKER: Breencast on a jumbotron) rendered natively, as a short one (audit
-- bug 6). sv_loops writes the speaker preset dsp_speaker into the mirror's DSP (a CSoundPatch cannot carry
-- the flag), so A.OwnDSP held the mirror on an engine patch (pba_keep_dsp): never native, the speaker EQ
-- branch of cl_loops (N.SPEAKER_EQ) dead, while the short speaker lines are native with that EQ. The preset
-- is pba's stand-in for the flag, not the sound's own DSP.
-- Client half (setup: speaker_long_native_setup.lua, server), native rendering on.
-- Pass: both lines' mirrors are native voices.
local A = pba
local LP = A.Loops
local N = A.Native
if not (N and N.render) then return { pass = nil, err = "native rendering off" } end
local function mirrorOf(i)
	local idx = GetGlobalInt("pba_test_spklong_" .. i, 0)
	for _, m in pairs(LP.mirrors) do if not m.client and m.idx == idx then return m end end
end
local res = {}
job:wait(function() local m = mirrorOf(1) return m and (m.nativeId or m.patch) end, 4)
local m1 = mirrorOf(1)
res.first = m1 and { native = m1.nativeId ~= nil, patch = m1.patch ~= nil, speaker = m1.speaker, dsp = m1.dsp } or false
job:wait(function() local m = mirrorOf(2) return m and (m.nativeId or m.patch) end, 6)
local m2 = mirrorOf(2)
res.second = m2 and { native = m2.nativeId ~= nil, patch = m2.patch ~= nil, speaker = m2.speaker, dsp = m2.dsp } or false
res.pass = res.first and res.first.native and res.second and res.second.native or false
return res
