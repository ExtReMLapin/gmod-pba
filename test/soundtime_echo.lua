-- The native echoes of a relayed sound started at once even when the sound itself waits for its own start
-- time (data.Delay, A.SoundTimeDelay): up to 0.5 s ahead of it. N.Echo now passes the delay to the module
-- (pba_native.Echo's 6th argument). Client lua_exec; the module's Echo and the sound lookup are stubbed
-- (what is tested is the argument). Pass: Delay 0.2 -> 0.2 passed; no Delay -> 0.
local A = pba
local N = A.Native
if not N or not pba_native then return { pass = false, err = "native module not loaded" } end
local res = { got = {} }
local saved = { echo = pba_native.Echo, ensure = N.EnsureSound, render = N.render, ne = A.cfg.native_echo, lvl = A.cfg.native_echo_lvl }
pba_native.Echo = function(...) local a = { ... } res.got[#res.got + 1] = a[6] return 0 end
N.EnsureSound = function() return true, "x" end
N.render = true
A.cfg.native_echo, A.cfg.native_echo_lvl = 1, 0
local ok, err = pcall(function()
	N.Echo({ SoundName = "weapons/smg1/smg1_fire1.wav", SoundLevel = 140, Volume = 1, Pitch = 100, Delay = 0.2 }, Vector(0, 0, 0), true, false)
	N.Echo({ SoundName = "weapons/smg1/smg1_fire1.wav", SoundLevel = 140, Volume = 1, Pitch = 100 }, Vector(0, 0, 0), true, false)
end)
pba_native.Echo, N.EnsureSound, N.render = saved.echo, saved.ensure, saved.render
A.cfg.native_echo, A.cfg.native_echo_lvl = saved.ne, saved.lvl
res.err = not ok and tostring(err) or nil
res.pass = ok and #res.got == 2 and math.abs((res.got[1] or 0) - 0.2) < 1e-6 and res.got[2] == 0
return res
