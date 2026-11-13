-- Stereo files rendered natively (client lua_job, native rendering on, any map; Concon's report 6, parity
-- plan P1-1). The module used to decode every file to mono (L + R) / 2:
--   decode: a stereo file is reported stereo by LoadSound (3rd value), a mono one is not;
--   variant: a "^" file (Source: left = near, right = far) gets sel 1 next to the listener, -1 at 2000 u
--     (pba_native.SetVoiceStereo, recorded);
--   width: a ")" stereo gunshot 100 u ahead gets sel 0 and width 1, the same at 2000 u width 0;
--   image: the left channel is heard on the left: a synthetic ")" file with sound in its left channel only,
--     played 100 u ahead, has a left / (left + right) ear energy balance at least 0.15 higher with width 1
--     than with width 0 (measured: 0.43 -> 0.84). (A real gunshot was tried first: HL2's stereo shots are
--     nearly centred, 0.46 to 0.55 of their energy on the left, so their image moves by about 1 %: below
--     what the reverb lets a 3 % threshold see.)
--   off: pba_native_stereo 0 sends nothing (the old downmix).
-- Red with a module without stereo support (no SetVoiceStereo / no 3rd LoadSound value).
local N = pba.Native
local NA = pba_native
if not (N and N.ready and N.render and NA) then return { pass = false, err = "native renderer not running" } end
local res = { checks = {} }
if not NA.SetVoiceStereo then
	res.checks.module = false
	res.fails = { "module" }
	res.pass = false
	return res
end
local saved = {}
for _, n in ipairs({ "native_stereo", "native_stereo_width" }) do saved[n] = GetConVar("pba_" .. n):GetString() end
local function set(n, v)
	RunConsoleCommand("pba_" .. n, tostring(v))
	job:wait(function() return pba.cfg[n] == v end, 5)
end
set("native_stereo", 1)
set("native_stereo_width", 1)

-- (MONO: a one-channel file; weapons/pistol/pistol_fire2.wav, used first, is a stereo file)
local STEREO, VARIANT, MONO = ")weapons/357/357_fire2.wav", "^ambient/energy/ion_cannon_shot1.wav", "npc/combine_soldier/vo/on1.wav"
-- 1. decode
local function stereoOf(f)
	local data = file.Read("sound/" .. f, "GAME")
	if not data then return nil end
	local _, _, st = NA.LoadSound("stereotest/" .. f, data)
	return st
end
res.stereoFile = stereoOf(pba.SoundFile(STEREO))
res.monoFile = stereoOf(MONO)
res.checks.decode = res.stereoFile == true and res.monoFile == false

-- 2-3. what PlayVoice sends
local sent = {}
local orig = NA.SetVoiceStereo
NA.SetVoiceStereo = function(id, sel, w) sent[id] = { sel, w } return orig(id, sel, w) end
local ply = LocalPlayer()
local eye, fwd = ply:EyePos(), ply:EyeAngles():Forward()
local function play(name, d)
	N.EnsureSound(name)
	job:wait(function() return NA.HasSound(string.lower(pba.SoundFile(name))) end, 5)
	local id = N.PlayVoice(name, eye + fwd * d, 0.3, 0, 100, { len = d })
	return id, id and sent[id]
end
local ok, err = pcall(function()
	local _, near = play(VARIANT, 100)
	local _, far = play(VARIANT, 2000)
	res.variantNear, res.variantFar = near, far
	res.checks.variant = near ~= nil and far ~= nil and near[1] > 0.99 and far[1] < -0.99
	job:sleep(0.5)
	local _, wn = play(STEREO, 100)
	local _, wf = play(STEREO, 2000)
	res.widthNear, res.widthFar = wn, wf
	res.checks.width = wn ~= nil and math.abs(wn[1]) < 1e-6 and wn[2] > 0.99 and (wf == nil or wf[2] < 1e-6)
	job:sleep(1)
	-- 4. image: L / R balance of a left-only stereo file, with and without width
	local function u32(n) return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256) end
	local function u16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
	local parts = {}
	math.randomseed(1)
	for i = 1, 22050 do -- 0.5 s of noise in the left channel, silence in the right
		parts[i] = u16(math.floor((math.random() * 2 - 1) * 12000) % 65536) .. "\0\0"
		if i % 2000 == 0 then job:step() end
	end
	local pcm = table.concat(parts)
	local wav = "RIFF" .. u32(36 + #pcm) .. "WAVEfmt " .. u32(16) .. u16(1) .. u16(2) .. u32(44100) .. u32(44100 * 4)
		.. u16(4) .. u16(16) .. "data" .. u32(#pcm) .. pcm
	local LEFT = "stereotest/leftonly.wav"
	local _, _, st = NA.LoadSound(LEFT, wav)
	N.stereo[LEFT] = st == true
	local function balance(w)
		set("native_stereo_width", w)
		job:sleep(0.5)
		N.energyL, N.energyR = 0, 0
		N.PlayVoice(")" .. LEFT, eye + fwd * 100, 0.3, 0, 100, { len = 100 })
		job:sleep(0.4)
		local l, r = N.energyL or 0, N.energyR or 0
		job:sleep(0.6)
		return l / math.max(l + r, 1e-12)
	end
	res.balanceMono = balance(0)
	res.balanceWide = balance(1)
	res.checks.image = res.balanceWide - res.balanceMono > 0.15
	-- 5. off
	set("native_stereo", 0)
	local n0 = table.Count(sent)
	play(VARIANT, 100)
	res.checks.off = table.Count(sent) == n0
end)
NA.SetVoiceStereo = orig
for n, v in pairs(saved) do RunConsoleCommand("pba_" .. n, v) end
if not ok then res.err = err end
res.fails = {}
for k, v in SortedPairs(res.checks) do if not v then res.fails[#res.fails + 1] = k end end
res.pass = ok and #res.fails == 0
return res
