-- pba_twodoors with BOTH brush doors closed (side bug 39). The doors close their areaportals: the client
-- then no longer receives them (dormant: no collision for its traces), and the routes through the doorways
-- paid no door, two voices at -19/-21 dB as if open, while with one door closed (the area still
-- connected, both doors received) its route paid the leaf (-43 dB). Client lua_job; the runner closes both
-- doors (server) first. Listener in the west room, three sources in the east room (option_sweep's points).
-- Pass: every source's loudest voice is at least 15 dB under the both-open level, the doors are dormant
-- (else the case is not exercised: inconclusive), and the replicated state says closed.
local A = pba
local L = Vector(256, 384, 64)
local SRC = { Vector(784, 384, 40), Vector(784, 200, 40), Vector(784, 560, 40) }
local D = A.Doors
local dormant, closed = 0, 0
for idx, st in pairs(D and D.byEnt or {}) do
	local e = Entity(idx)
	if IsValid(e) and e:IsDormant() then dormant = dormant + 1 end
	if st.frac < 0.01 then closed = closed + 1 end
end
if closed < 2 then return { pass = false, why = "both doors not closed in the replicated state (inconclusive)", closed = closed } end
A.Paths.InvalidateCache()
local res = { dormant = dormant, levels = {}, option = A.cfg.door_dormant }
local worst = -math.huge
for i, S in ipairs(SRC) do
	local r = A.Paths.Compute(S, L, 75)
	local best = 0
	for _, v in ipairs(r.voices or {}) do best = math.max(best, v.gain or 0) end
	local db = 20 * math.log10(math.max(best, 1e-6))
	res.levels[i] = math.Round(db, 1)
	worst = math.max(worst, db)
	job:step()
end
res.loudest = math.Round(worst, 1)
-- both doors open: about -19..-21 dB at these points (measured); closed doors cost their leaf (34 dB)
local why = {}
if dormant < 2 then why[#why + 1] = "the doors are not dormant (never received by this client: not covered yet)" end
if worst > -19 - 15 then why[#why + 1] = "loudest voice " .. res.loudest .. " dB: the closed doors are not heard" end
res.pass = #why == 0
res.why = table.concat(why, "; ")
return res
