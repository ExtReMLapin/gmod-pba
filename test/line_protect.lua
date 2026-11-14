-- Spoken lines are dropped last past the native voice cap (pba_native_protect_lines, audit C-5): client lua_job,
-- pba_tworooms, native render. The engine never steals a CHAN_VOICE / CHAN_STREAM / CHAN_VOICE2 channel for another
-- sound, but the module's cap dropped the quietest voice whatever it was: a line behind a wall (quiet) died first in
-- a burst of shots (100 pistol shots in one frame killed a 5 s line 0.2 s into it). The module's Play takes a last
-- optional argument (protect) the cap honours (native/test/voice_cap_test.cpp checks the cap itself).
-- Pass: every sound PlayVoice hands to the module carries protect = true for CHAN_VOICE, CHAN_VOICE2 and
-- CHAN_STREAM, not for CHAN_WEAPON / CHAN_AUTO; with pba_native_protect_lines 0 for none.
local A = pba
if game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms" } end
local N = A.Native
if not (N and N.render and pba_native) then return { pass = false, err = "needs the native module rendering" } end
if LocalPlayer():GetPos():Distance(Vector(256, 256, 0)) > 1 then
	RunConsoleCommand("setpos", "256", "256", "0")
	job:sleep(0.5)
end
local line = "vo/npc/male01/question06.wav"
local shot = "weapons/pistol/pistol_fire2.wav"
for _, n in ipairs({ line, shot }) do
	N.EnsureSound(n, true)
	job:wait(function() return pba_native.HasSound(n) end, 5)
end
local calls = {}
local orig = pba_native.Play
pba_native.Play = function(n, ...)
	local a = { ... }
	calls[#calls + 1] = { name = n, protect = a[13] } -- (after pos: gain, l, m, h, pitch, loop, delay, sh, diffuse, send, offset, protect)
	return orig(n, ...)
end
local function snd(name, chan, pos)
	return { SoundName = name, OriginalSoundName = name, Pos = Vector(pos), Entity = NULL, EntIndex = 0,
		Channel = chan, Volume = 1, SoundLevel = 75, Pitch = 100, Flags = 0, DSP = 0, SoundTime = 0 }
end
local function run(opt)
	A.SetOverride("native_protect_lines", opt)
	job:frames(2)
	local got = {}
	for i, c in ipairs({ { "voice", line, CHAN_VOICE }, { "voice2", line, CHAN_VOICE2 }, { "stream", line, CHAN_STREAM }, { "weapon", shot, CHAN_WEAPON }, { "auto", shot, CHAN_AUTO } }) do
		calls = {}
		A.Process(snd(c[2], c[3], Vector(600 + i * 8, 300, 40)), false)
		job:sleep(0.3)
		local p
		for _, k in ipairs(calls) do p = p or k.protect end
		got[c[1]] = { voices = #calls, protect = p == true }
	end
	return got
end
local ok, res = pcall(function() return { on = run(1), off = run(0) } end)
pba_native.Play = orig
A.SetOverride("native_protect_lines", nil)
if not ok then return { pass = false, err = tostring(res) } end
local on, off = res.on, res.off
local function started(t) return t.voices >= 1 end
res.started = started(on.voice) and started(on.voice2) and started(on.stream) and started(on.weapon) and started(on.auto)
res.protectedOn = on.voice.protect and on.voice2.protect and on.stream.protect and not on.weapon.protect and not on.auto.protect
res.protectedOff = not (off.voice.protect or off.voice2.protect or off.stream.protect or off.weapon.protect or off.auto.protect)
res.pass = res.started and res.protectedOn and res.protectedOff
return res
