-- T14 glass_window, part 2 (client lua_job, pba_window): the 16 x 112 x 80 u opening in the wall between the rooms
-- (x 512-528, y 336-448, z 48-128), source in the far room at (784, 256, 40), listener at (256, 256, 64).
-- The dominant voice is the portal one, at the opening (its apparent position inside the opening's box, 8 u of
-- slack), loud: -16.3 dB measured (the path to the near edge of the opening) +-3 dB, whereas the wall itself would
-- give 60 dB of loss. Red proof (RED_WINDOW prepended): the edge diffraction loss switched off (diff_max_edge 0)
-- gives -10.6 dB. (The map has no areaportal entity at run time to shut.)
local P = pba.Paths
if RED_WINDOW then pba.SetOverride("diff_max_edge", 0) job:sleep(0.3) end
P.InvalidateCache()
local r = P.Compute(Vector(784, 256, 40), Vector(256, 256, 64), 75)
local v = r.voices and r.voices[1]
local res = { kind = v and v.kind, lvl = v and 20 * math.log10(v.gain), pos = v and v.pos and { x = v.pos.x, y = v.pos.y, z = v.pos.z } }
local fails = {}
local function chk(k, ok) if not ok then fails[#fails + 1] = k end end
chk("portal voice " .. tostring(res.kind), res.kind == "portal")
if v then
	local p = v.pos
	chk("voice in the opening", p.x >= 504 and p.x <= 536 and p.y >= 328 and p.y <= 456 and p.z >= 40 and p.z <= 136)
	chk("level " .. string.format("%.1f", res.lvl), res.lvl >= -19.3 and res.lvl <= -13.3)
end
if RED_WINDOW then pba.SetOverride("diff_max_edge", nil) end
res.fails = fails
res.pass = #fails == 0
return res
