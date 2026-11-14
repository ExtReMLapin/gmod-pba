-- T14 glass_window, part 1 (client lua_job, pba_materials; RED_GLASS = true prepended makes the glass concrete-like for
-- the red proof). The six cells of the map are sealed behind a 16 u wall of one material each; P.Compute from the
-- corridor to a source in each cell returns one transmission voice whose gain is the wall's loss (measured: it
-- matches AC.WallLoss of the surface under the line within 1.7 dB for the six materials).
-- Asserts for the glass: its loss within 3 dB of AC.WallLoss(glass), the lightest muffling class (lp 1), the voice on
-- the glass (its plane, 2 u before the near face, in front of the source), losing at least 15 dB less than the concrete
-- cell and at least 1 dB less than the metal one beside it (measured: 39.4 dB; concrete 61.3, metal 41.3).
local A, P, AC = pba, pba.Paths, pba.AC
local names = { "concrete", "brick", "wood", "metal", "glass", "plaster" }
local old = AC.MAT_TABLE[MAT_GLASS]
local res = { cells = {} }
local ok, err = pcall(function()
	for i, n in ipairs(names) do
		local x0 = (i - 1) * 272
		local S, L = Vector(x0 + 128, 400, 40), Vector(x0 + 128, 128, 64)
		P.InvalidateCache()
		if RED_GLASS then AC.MAT_TABLE[MAT_GLASS] = AC.MAT_TABLE[MAT_CONCRETE] end
		local r = P.Compute(S, L, 75)
		AC.MAT_TABLE[MAT_GLASS] = old
		local v = r.voices and r.voices[1]
		local tr = util.TraceLine({ start = S, endpos = L, mask = MASK_SOLID_BRUSHONLY })
		local sp = util.GetSurfaceData(tr.SurfaceProps)
		local exp, lp = AC.WallLoss(tr.MatType, sp and sp.name, 16)
		res.cells[n] = { kind = v and v.kind, loss = v and -20 * math.log10(v.gain) or nil, exp = exp, lp = v and v.lp,
			pos = v and v.pos and { x = v.pos.x, y = v.pos.y, z = v.pos.z } or nil, x0 = x0 }
	end
end)
AC.MAT_TABLE[MAT_GLASS] = old
if not ok then return { pass = false, err = tostring(err) } end
local c, fails = res.cells, {}
local function chk(k, ok) if not ok then fails[#fails + 1] = k end end
for n, t in pairs(c) do chk("transmission " .. n, t.kind == "transmission") end
local g = c.glass
if g.loss then
	chk("glass loss " .. string.format("%.1f vs %.1f", g.loss, g.exp), math.abs(g.loss - g.exp) <= 3)
	chk("glass lp class", g.lp == 1)
	chk("glass voice on the pane " .. (g.pos and string.format("%.1f %.1f", g.pos.x, g.pos.y) or "nil"), g.pos and math.abs(g.pos.x - (g.x0 + 128)) <= 8 and g.pos.y >= 248 and g.pos.y <= 272)
	chk("glass lighter than concrete", c.concrete.loss and g.loss <= c.concrete.loss - 15)
	chk("glass lighter than metal", c.metal.loss and g.loss <= c.metal.loss - 1)
else
	chk("glass voice", false)
end
res.fails = fails
res.pass = #fails == 0
return res
