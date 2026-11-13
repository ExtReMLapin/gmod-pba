-- Source reverb slot of a far moving source (client lua_job, native rendering, module with SetSourceNear).
-- A slot keeps the response simulated at one place while its source stays near it. With a fixed 1.5 m,
-- a gunship ~90 m away flying at 6 m/s got a new place every 0.25 s: each restarted the slot's average
-- from one noisy pass, its reverb swinging +-4 dB, heard as an echo that jumps (d1_trainstation_04, user
-- report 2026-11-13). pba_native_src_near keeps the response over a fraction of the distance.
-- Measure: a silent looping voice bound to a source slot, moved 6 m/s for 4 s (SourceReflect every 0.1 s
-- as the loop mirrors do), far (90 m) then near (8 m); new generations of its slot counted.
-- Pass: far, at most 5 generations with the option (about 16 at 1.5 m); near, unchanged by the option
-- (still a new place every 1.5 m).
local N = pba.Native
if not (N and N.render) then return { pass = false, err = "native renderer not running" } end
local setNear = pba_native.SetSourceNear or function() end -- (module before 2026-11-13: fixed 1.5 m)
local file = "npc/combine_gunship/engine_whine_loop1.wav"
for i = 1, 100 do
	local ok, _, why = N.EnsureSound(file)
	if ok then break end
	if why ~= "pending" then return { pass = false, err = "cannot load " .. file } end
	job:sleep(0.1)
end
local M = 52.49 -- units per metre
local function slotGen(slot)
	for _, s in ipairs(pba_native.SrcSlotStats()) do if s.slot == slot then return s.gen end end
end
-- the option through its convar: cl_native's settings timer pushes pba.cfg.native_src_near to the module every
-- 0.5 s (N.ApplySettings), so a value set on the module alone was undone within the measure
local function setFrac(frac)
	RunConsoleCommand("pba_native_src_near", tostring(frac))
	for i = 1, 50 do
		if math.abs((pba.cfg.native_src_near or -1) - frac) < 1e-6 then break end
		job:sleep(0.05)
	end
	setNear(frac)
end
local function run(distM, frac)
	setFrac(frac)
	local L = LocalPlayer():EyePos()
	local dir = Angle(0, LocalPlayer():EyeAngles().y, 0)
	local base = L + dir:Forward() * distM * M + Vector(0, 0, 2 * M)
	local side = dir:Right()
	local id = pba_native.Play(file, base, 0.0001, 1, 1, 1, 100, true, 0, nil, 0, 0)
	if not id or id <= 0 then return { err = "play failed" } end
	local slot = pba_native.SourceReflect(id, base, 1)
	job:sleep(0.5)
	local g0 = slot >= 0 and slotGen(slot)
	local t0 = RealTime()
	while RealTime() - t0 < 4 do
		local p = base + side * (RealTime() - t0) * 6 * M
		pba_native.Update(id, p, 0.0001, 1, 1, 1, 100)
		slot = pba_native.SourceReflect(id, p, 1)
		job:sleep(0.1)
	end
	local g1 = slot >= 0 and slotGen(slot)
	pba_native.StopVoice(id)
	job:sleep(1.2)
	return { slot = slot, gens = (g1 and g0) and (g1 - g0) or -1 }
end
local saved = pba.cfg.native_src_near or 0.1
local res = { checks = {} }
res.farOff = run(90, 0)
res.farOn = run(90, 0.1)
res.nearOff = run(8, 0)
res.nearOn = run(8, 0.1)
setFrac(saved)
res.checks.cfgFollowed = math.abs((pba.cfg.native_src_near or -1) - saved) < 1e-6
res.checks.api = pba_native.SetSourceNear ~= nil
res.checks.farFewer = res.farOn.gens >= 1 and res.farOn.gens <= 5
res.checks.farOffMany = res.farOff.gens >= 10 -- the fixed 1.5 m (proves the measure sees the restarts)
res.checks.nearUnchanged = res.nearOn.gens >= 10 and math.abs(res.nearOn.gens - res.nearOff.gens) <= 3
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
