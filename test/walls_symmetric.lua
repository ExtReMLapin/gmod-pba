-- Displacements (terrain) are one-sided for traces: P.Walls must find the same walls from both ends,
-- else level(S, L) and level(L, S) differ by a whole wall (50 dB on gm_construct, perceptual bench).
-- lua_job, client realm, gm_construct. Pairs from the bench's reciprocity outliers.
-- Returns { pass, pairs = { { fwd, rev } } }.
if game.GetMap() ~= "gm_construct" then return { pass = false, err = "needs gm_construct" } end
local P = pba.Paths
local pairs_ = {
	{ Vector(-3008, -320, 204), Vector(-2368, -448, -436) },
	{ Vector(-1856, 4032, -308), Vector(-2240, 4288, -916) },
	{ Vector(-960, -448, 172), Vector(-1216, -192, -436) },
}
local out, pass = {}, true
for _, p in ipairs(pairs_) do
	local f, r = #P.Walls(p[1], p[2], 6), #P.Walls(p[2], p[1], 6)
	out[#out + 1] = { fwd = f, rev = r }
	if f ~= r then pass = false end
end
return { pass = pass, pairs = out }
