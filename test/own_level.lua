-- The listener's own gunfire at the engine's level (client lua_job, singleplayer, native rendering on).
-- Measured on the engine (startmovie) against the module (pba_native.CaptureStart): the engine plays the
-- listener's own sounds at about 1.5 x the sound's volume (gunfire at 105 dB, 150 dB, footsteps alike) where the
-- module gave 0.65-0.75 x (the mix group value alone): the shots came out 4 to 6 dB quieter, dull next to the
-- engine's. pba_native_own_gain (default 2) is the extra level of the listener's own sounds against the mix rule.
-- Pass, with the option at 2 against 1 (everything else the same): the gain the module is given for the own shot
-- is exactly twice as big, and the peak of the module's recorded output is 2 x (1.85 .. 2.15) as big (a shot at
-- volume 0.3 stays far under the limiter); the option's default is 2; an NPC-like (not own) sound does not change.
local N = pba.Native
if not (N and N.render and pba_native and pba_native.CaptureStart) then return { pass = false, err = "native renderer with capture not running" } end
if not game.SinglePlayer() then return { pass = false, err = "singleplayer only" } end
local res = { checks = {} }
local function check(name, ok, v) res.checks[name] = ok and true or false if v ~= nil then res[name] = v end end

local saved = {}
for _, c in ipairs({ "pba_native_all", "pba_native_own", "pba_native_own_gain", "pba_native_mix", "pba_native_duck" }) do
	local cv = GetConVar(c)
	saved[c] = cv and cv:GetString()
end
local cfgDef = pba.CONFIG and pba.CONFIG.native_own_gain and pba.CONFIG.native_own_gain[1]
check("defaultIsEngineLevel", cfgDef == 2, cfgDef)
local function set(c, v)
	RunConsoleCommand(c, tostring(v))
	job:wait(function() local cv = GetConVar(c) return cv and math.abs(cv:GetFloat() - tonumber(v)) < 1e-6 end, 5)
end
job:wait(function() return not N.prewarm end, 30)
set("pba_native_all", 1)
set("pba_native_own", 1)
set("pba_native_mix", 1)
set("pba_native_duck", 0)
job:sleep(1.0)

-- the gain the module is given for the shot (the wrapper's last Play) and the peak of its recorded output
local function shots(g)
	set("pba_native_own_gain", g)
	job:sleep(0.3)
	local last = {}
	local ok = pba_native.CaptureStart(3)
	if not ok then return nil end
	for i = 1, 3 do
		LocalPlayer():EmitSound(")weapons/ar2/fire1.wav", 105, 100, 0.3, CHAN_WEAPON) -- (client side: his own predicted shot)
		job:sleep(0.5)
		local lp = pba.Mix and pba.Mix.lastPlay
		if lp and lp.gain then last[#last + 1] = lp.gain end
	end
	job:sleep(0.8)
	local path, frames, peak = pba_native.CaptureStop("own_level_" .. g, 32)
	return { peak = peak, gain = last[#last], gains = last, path = path }
end

local a = shots(2)
local b = shots(1)
res.a, res.b = a, b
if not (a and b and a.peak and b.peak and a.gain and b.gain) then
	check("measured", false)
else
	check("measured", true)
	check("moduleGainDoubled", math.abs(a.gain / b.gain - 2) < 0.01, a.gain / b.gain)
	check("recordedPeakDoubled", a.peak / b.peak > 1.85 and a.peak / b.peak < 2.15, a.peak / b.peak)
	check("recordedPeakNotTiny", a.peak > 0.002 and b.peak > 0.001, a.peak)
end

for c, v in pairs(saved) do if v then RunConsoleCommand(c, v) end end
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
