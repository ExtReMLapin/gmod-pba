-- Probe graph coverage (client lua_job, map d1_town_01, Ravenholm). Reported case: a fire
-- (ambient/fire/fire_small_loop2.wav) heard only in direct line, never through the opening of its
-- room. Source and listener are in the same areaportal area, so only the probe graph can find the
-- opening; the room had no probe: its cell centres lie on the floor plane (z = -3776 = (k + 0.5)
-- * 128) or inside geometry, and a cell was kept only if its CENTRE was valid.
-- The opening is right beside the straight line (it grazes the frame): a point 9 u aside sees both
-- ends, path 284 u for 283 u direct, a 9 degree turn. Pass: a probe within one spacing of the fire,
-- a probe path, and that path hugs the frame edge (length within 10 % of the straight line, loss
-- under 8 dB) instead of zig-zagging through grid probes.
local A = pba
if game.GetMap() ~= "d1_town_01" then return { pass = false, error = "load d1_town_01" } end
job:wait(function() return A.Probes.current ~= nil end, 300)
local g = A.Probes.current
local S = Vector(2163.93, -1799.15, -3771.29)  -- the fire loop
local L = Vector(2176.77, -1521.23, -3711.97)  -- where the player stood, behind the opening
local best
for _, n in ipairs(g.nodes) do
	local d = n.pos:Distance(S)
	if not best or d < best then best = d end
end
local paths = A.Probes.FieldRoutes(S, L, A.cfg.max_paths, A.cfg)
-- Paths() may answer from a background solve: give it a few frames
for _ = 1, 60 do
	if #paths > 0 then break end
	job:frames(2)
	paths = A.Probes.FieldRoutes(S, L, A.cfg.max_paths, A.cfg)
end
A.Paths.InvalidateCache()
local r = A.Paths.Compute(S, L, 75)
local v = r.voices and r.voices[1]
local p1 = r.paths and r.paths[1]
local direct = S:Distance(L)
local ok = best < g.spacing and #paths > 0 and v ~= nil and v.kind ~= "transmission"
	and p1 ~= nil and p1.length <= direct * 1.1 and (p1.lossDb or 99) < 8
return { pass = ok, nodes = #g.nodes, nearestProbe = math.Round(best), spacing = g.spacing, probePaths = #paths,
	pathLength = p1 and math.Round(p1.length), direct = math.Round(direct), pathLossDb = p1 and math.Round(p1.lossDb or -1, 1),
	voice = v and v.kind, gain = v and math.Round(v.gain, 4), lp = v and v.lp, viaProbes = r.viaProbes }
