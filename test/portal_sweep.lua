-- Sweep over every areaportal of the current map (client, lua_exec_file / lua_job): source a
-- few units behind the opening, listener in front; the computed path must cross that portal
-- (apparent position within the opening). Works on any map: real-map sanity check.
local A = pba
local g = A.Graph.current
if not g then return "no graph" end
local res = { total = 0, tested = 0, ok = 0, skipped = 0, fails = {} }
local function free(p) return bit.band(util.PointContents(p), CONTENTS_SOLID) == 0 end
for _, p in ipairs(g.portals) do
	res.total = res.total + 1
	local done = false
	for _, d in ipairs({ 96, 160, 256 }) do
		local base = p.center + Vector(0, 0, -p.radius * 0.3)
		local L, S = base + p.normal * d, base - p.normal * d
		if free(L) and free(S) then
			local aL, aS = A.Graph.Area(g, L), A.Graph.Area(g, S)
			if aL ~= 0 and aS ~= 0 and aL ~= aS then
				A.Paths.cache = {}
				local r = A.Paths.Compute(S, L, 75)
				res.tested = res.tested + 1
				done = true
				local good = false
				if r.clear then
					good = true -- straight through the opening: nothing to do, also correct
				elseif r.paths and r.paths[1] then
					local last = r.paths[1].chain and r.paths[1].chain[#r.paths[1].chain]
					good = (last and last.key == p.key) or r.paths[1].pos:Distance(p.center) <= p.radius * 1.5
				end
				-- glazed window or closed door in the opening: the direct line only crosses that
				-- entity, rendered as a transmission voice ON the opening (also correct)
				if not good and r.voices and r.voices[1] and r.voices[1].pos:Distance(p.center) <= p.radius * 1.5 then
					good = true
					res.viaEntity = (res.viaEntity or 0) + 1
				end
				if good then res.ok = res.ok + 1
				else res.fails[#res.fails + 1] = string.format("#%d clear=%s paths=%d", p.key, tostring(r.clear), r.paths and #r.paths or -1) end
				break
			end
		end
	end
	if not done then res.skipped = res.skipped + 1 end
end
return res
