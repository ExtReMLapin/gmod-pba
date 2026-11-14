-- Bursts of new sounds (pba_burst_budget_ms, pba_burst_mask_db): client lua_job, pba_tworooms. The player
-- stands in room A, six barrel impacts are processed in one frame behind the wall in room B (A.Process).
--   off (both 0): six full evaluations, no cheap one (the former path);
--   budget 0.001 ms: the first is full, the 2nd..6th take the degraded path (near: the cheap model, or the
--     slicer when far enough); a 7th from the 1st sound's emitter reuses its result;
--   mask 25 dB: a 140 dB explosion then five 80 dB impacts within 100 ms: the impacts are masked (cheap).
local A = pba
if game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms" } end
local P = A.Paths
local function set(name, v)
	RunConsoleCommand("pba_" .. name, tostring(v))
	job:wait(function() return A.cfg[name] == v end, 3)
end
local b0, m0, h0v = A.cfg.burst_budget_ms, A.cfg.burst_mask_db, A.cfg.burst_hold_ms
local lp = LocalPlayer()
local L0 = Vector(256, 256, 0)
if lp:GetPos():Distance(L0) > 1 then
	RunConsoleCommand("setpos", "256", "256", "0")
	job:sleep(0.5)
end
local name = "physics/metal/metal_barrel_impact_hard1.wav"
local spots = { Vector(900, 400, 40), Vector(1000, 400, 40), Vector(1100, 400, 40), Vector(900, 560, 40), Vector(1000, 560, 40), Vector(1100, 560, 40) }
local function sound(pos, lvl, ent)
	return { SoundName = name, OriginalSoundName = name, Pos = pos, Entity = ent or NULL, EntIndex = ent and ent:EntIndex() or 0,
		Channel = CHAN_AUTO, Volume = 1, SoundLevel = lvl or 85, Pitch = 100, Flags = 0, DSP = 0, SoundTime = 0 }
end
local nCompute, nCheap = 0, 0
local c0, h0 = P.Compute, P.Cheap
P.Compute = function(...) nCompute = nCompute + 1 return c0(...) end
P.Cheap = function(...) nCheap = nCheap + 1 return h0(...) end
-- one frame's burst: every A.Process in this step (no job:step in between); emitter: an entity for every sound
local emitters = {}
for i = 1, #spots do
	local e = ents.CreateClientProp("models/props_c17/oildrum001.mdl")
	e:SetPos(spots[i]) e:Spawn()
	emitters[i] = e
end
local function burst(extra)
	nCompute, nCheap = 0, 0
	A.ResetBurstStats()
	A.burst.frame, A.burst.spent, A.burst.loudT = -1, 0, -1
	local taken = 0
	job:frames(1)
	if extra == "mask" then A.Process(sound(Vector(1000, 480, 40), 140), false) end
	for i = 1, #spots do
		if A.Process(sound(spots[i], extra == "mask" and 80 or 85, emitters[i]), false) then taken = taken + 1 end
	end
	if extra == "reuse" then A.Process(sound(spots[1] + Vector(8, 0, 0), 85, emitters[1]), false) end
	local s = A.burstStats
	return { compute = nCompute, cheap = nCheap, taken = taken, full = s.full, reused = s.reused, deferred = s.deferred,
		cheapN = s.cheap, masked = s.masked }
end
local ok, res = pcall(function()
	local out = {}
	if h0v then A.SetOverride("burst_hold_ms", 0, true) end -- (the cheap path itself: burst_hold.lua tests the hold)
	set("burst_budget_ms", 0) set("burst_mask_db", 0)
	out.off = burst()
	out.offMask = burst("mask")
	set("burst_budget_ms", 0.001)
	burst() -- (the emitters' results recorded, then a fresh frame)
	out.budget = burst("reuse")
	set("burst_budget_ms", 0) set("burst_mask_db", 25)
	out.mask = burst("mask")
	return out
end)
P.Compute, P.Cheap = c0, h0
for _, e in ipairs(emitters) do if IsValid(e) then e:Remove() end end
set("burst_budget_ms", b0) set("burst_mask_db", m0)
if h0v then A.SetOverride("burst_hold_ms", nil, true) end
if not ok then return { pass = false, err = tostring(res) } end
local o, bu, ma = res.off, res.budget, res.mask
-- off: nothing degraded, every sound through the full model (P.Compute, cache hits included)
local offOk = o.cheap == 0 and o.full == 0 and o.compute >= 6 and res.offMask.cheap == 0
-- budget: one full evaluation, the five others degraded (cheap or deferred), the 7th reused
local budOk = bu.full == 1 and bu.cheapN + bu.deferred + bu.reused == 6 and bu.reused >= 1 and bu.cheap == bu.cheapN
-- mask: the explosion full, the six impacts masked (cheap)
local maskOk = ma.masked == #spots and ma.cheap == #spots and ma.full >= 1 -- (another sound of the frame may be evaluated too)
res.pass = offOk and budOk and maskOk
res.offOk, res.budOk, res.maskOk = offOk, budOk, maskOk
return res
