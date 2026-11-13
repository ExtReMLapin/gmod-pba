-- Source reverb slot reused by a later shot (client lua_job, native rendering, sv_cheats 1 for setpos;
-- gm_construct: the field by the spawn).
-- A shot's source reverb comes from a slot simulated at its position; a later shot near it reuses that
-- response without a new simulation. Two ways the reused slot came out wrong (side bug "first shot after
-- moving gets a stale reverb, sometimes none"):
--  * idle: after ~3 s without input the renderer reset the slot's reflection effect (to drop its old
--    tail). Steam Audio's reset also clears the impulse response the effect holds, and a reused response
--    is never sent again until the slot is simulated anew: the first shot after a pause had NO source
--    reverb (measured 0.002 vs 2.9, the next shot 1.5 s later normal);
--  * listener moved: the slot is simulated from a listener anchor that follows the listener; the first
--    shot after walking away must get the response of where the listener now is (it fed banks left
--    silent by two anchor moves while the slot was idle: no reverb). A listener crossing the anchor
--    radius and stopping back inside it left the slots waiting for a bank swap forever (never simulated
--    again).
-- Measure: the slot's wet output energy (SrcSlotStats) over 1.2 s per shot, a pistol shot 400 u away.
-- Pass: the shot after a 4.5 s pause within x0.5..x2 of the shot that follows it; the first shot after
-- walking 800 u (4 s) within x0.4..x2.5 of the settled level there (mean of the 4th and 5th); stepping
-- out of the anchor radius and back, never left waiting to move the anchor 1.5 s later.
local N = pba.Native
if not (N and N.render and pba_native.SrcSlotStats) then return { pass = false, err = "native renderer not running" } end
if game.GetMap() ~= "gm_construct" then return { pass = false, err = "needs gm_construct" } end
local P1 = Vector(968.6, 721.7, -143.1)
local S = P1 + Vector(0, 400, 64)
local P2 = P1 + Vector(-800, 0, 0)
local snd = "weapons/pistol/pistol_fire2.wav"
local function tp(p)
	RunConsoleCommand("setpos", p.x, p.y, p.z)
	job:wait(function() return LocalPlayer():GetPos():Distance(p) < 32 end, 3)
end
job:wait(function() return N.EnsureSound(snd) end, 5)
local function shot()
	pba_native.SrcSlotStats() -- starts a new energy window
	N.PlayVoice(snd, S, 0.5, 0, 100, { srcPos = S, srcSend = 1 })
	local e = 0
	for _ = 1, 12 do
		job:sleep(0.1)
		for _, r in ipairs(pba_native.SrcSlotStats()) do e = e + r.energy end
	end
	return e
end
local res = { checks = {} }
-- idle
tp(P1)
job:sleep(1)
shot() job:sleep(0.3) shot()
job:sleep(4.5)
local idle = shot()
job:sleep(0.3)
local after = shot()
res.idle, res.idleNext = idle, after
res.checks.idle = after > 0 and idle >= 0.5 * after and idle <= 2 * after
-- walk 800 u at 200 u/s (setpos every 0.1 s), then shoot on arrival
for _ = 1, 3 do shot() end
for i = 1, 40 do
	local p = LerpVector(i / 40, P1, P2)
	RunConsoleCommand("setpos", p.x, p.y, p.z)
	job:sleep(0.1)
end
tp(P2)
local m = {}
for i = 1, 5 do m[i] = shot() end
local ref = (m[4] + m[5]) / 2
res.moved, res.movedRef = m[1], ref
res.checks.moved = ref > 0 and m[1] >= 0.4 * ref and m[1] <= 2.5 * ref
-- step out of the anchor radius and back: the listener moves 1.9 m (the anchor follows: banks swap),
-- 1.9 m further while the previous bank still sounds (the anchor must wait for it to fade), then back
-- within the radius before that; standing there, the slot must go on averaging passes (not frozen
-- waiting for a bank swap that never comes). Tried a few times: the step back must fall between passes.
tp(P1)
local stuck = 0
local function pos(du) local p = P1 + Vector(du, 0, 0) RunConsoleCommand("setpos", p.x, p.y, p.z) end
for _ = 1, 6 do
	shot()
	pos(100) job:sleep(0.6)
	pos(200) job:wait(function() return pba_native.Stats().srcRetiring end, 1)
	pos(100) job:sleep(1.5)
	if pba_native.Stats().srcRetiring then stuck = stuck + 1 end
	pos(0) job:sleep(1)
end
local st, r = pba_native.Stats(), pba_native.SrcSlotStats()[1] or {}
res.stuck, res.passes = stuck, r.n
res.checks.settles = stuck == 0 and st.srcRetiring == false
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
