-- Reverb of loud sounds in the open (client lua_job, native rendering, pba_native_all 1, the player standing
-- in the open air, e.g. gm_construct's field at (-1750, 2000, -20) facing yaw 45).
-- The engine keeps loud sounds dry: above dsp_db_min (95 dB in GMod) their room DSP wet mix is multiplied by
-- dsp_db_mixdrop (0.1 in GMod, about -20 dB). With pba_native_all the module fed a loud sound's source reverb
-- slot at its full 1 m power: an SMG shot at 300 u in the open got as much reflected energy as direct sound
-- (+1.4 dB, mostly the ground; the echo-only mode put the same reflections ~19 dB below), heard as muddled
-- gunfire (Workshop report). pba_native_loud_dry applies the engine's rule to the module's reverb sends.
-- Measure: the module's own mix energy (N.energyL/R) of one shot, with pba_native_reverb 0 (direct only) and
-- at the player's setting; reverb = total - direct. Each shot after a warm-up shot (the slot's simulation).
-- Pass: a level 105 shot's reverb at most -10 dB re its direct with the option on; a level 75 sound's
-- unchanged by the option (within 1.5 dB).
local N = pba.Native
if not (N and N.render) then return { pass = false, err = "native renderer not running" } end
if (pba.cfg.native_all or 0) < 0.5 then return { pass = false, err = "needs pba_native_all 1" } end
local ply = LocalPlayer()
local up = util.TraceLine({ start = ply:EyePos(), endpos = ply:EyePos() + Vector(0, 0, 16384), mask = MASK_SOLID_BRUSHONLY })
if not up.HitSky then return { pass = false, err = "stand in the open air (sky above)" } end
local saved = { reverb = GetConVar("pba_native_reverb"):GetString(), dry = GetConVar("pba_native_loud_dry"):GetString() }
-- (a model without physics: a client prop falls, and the terrain then hides it)
local e = ClientsideModel("models/props_junk/PopCan01a.mdl")
e:SetPos(ply:EyePos() + Angle(0, ply:EyeAngles().y, 0):Forward() * 300 + Vector(0, 0, -16))
local clear = not util.TraceLine({ start = ply:EyePos(), endpos = e:GetPos(), mask = MASK_SOLID_BRUSHONLY }).Hit
if not clear then e:Remove() return { pass = false, err = "no clear line to a point 300 u ahead" } end
local function shot(name, lvl, vol)
	local e0 = (N.energyL or 0) + (N.energyR or 0)
	e:EmitSound(name, lvl, 100, vol, CHAN_WEAPON)
	job:sleep(3)
	return (N.energyL or 0) + (N.energyR or 0) - e0
end
local function measure(name, lvl, vol)
	shot(name, lvl, vol) -- warm-up: the slot's simulation
	local s = 0
	for _ = 1, 2 do s = s + shot(name, lvl, vol) end
	return s / 2
end
local function set(cv, v)
	RunConsoleCommand(cv, v)
	job:wait(function() return GetConVar(cv):GetString() == v end, 5)
	job:sleep(0.5)
end
local LOUD, QUIET = "^weapons/smg1/npc_smg1_fire1.wav", "vo/npc/male01/hi01.wav"
local res = {}
set("pba_native_reverb", "0")
local dLoud, dQuiet = measure(LOUD, 105, 0.7), measure(QUIET, 75, 1)
res.direct = { loud = math.Round(10 * math.log10(math.max(dLoud, 1e-12)), 2), quiet = math.Round(10 * math.log10(math.max(dQuiet, 1e-12)), 2) }
set("pba_native_reverb", saved.reverb == "0" and "0.4" or saved.reverb)
local function revDb(tot, dir) return math.Round(10 * math.log10(math.max(tot - dir, 1e-9) / math.max(dir, 1e-9)), 1) end
for _, dry in ipairs({ "0", "1" }) do
	set("pba_native_loud_dry", dry)
	res["loud" .. dry] = revDb(measure(LOUD, 105, 0.7), dLoud)
	res["quiet" .. dry] = revDb(measure(QUIET, 75, 1), dQuiet)
end
e:Remove()
RunConsoleCommand("pba_native_reverb", saved.reverb)
RunConsoleCommand("pba_native_loud_dry", saved.dry)
-- measured: -10.4 dB on (2026-11-13), -9.9 dB on (2026-11-14, same map): the bound -10 sat on the noise; the option's
-- effect (+2.4 / +3.0 off, 12.8 dB lower on) is the criterion: at most -8 dB on and at least 8 dB under off
res.pass = res.loud1 <= -8 and res.loud0 - res.loud1 >= 8 and math.abs(res.quiet1 - res.quiet0) <= 1.5
return res
