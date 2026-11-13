-- Client side of impact_inside_prop.lua (run right after it, props left in place): a world sound at a
-- physics object's origin (its own collision around it) computed from the listener in plain sight is
-- clear (P.Compute), not muffled by the object itself.
-- Client lua_job, pba_tworooms.
local P = pba.Paths
local L = LocalPlayer():EyePos() -- (EyePos() is only valid while rendering)
local res = { props = {} }
local ok, n = true, 0
for _, e in ipairs(ents.FindByClass("prop_physics")) do
	do
		n = n + 1
		P.InvalidateCache()
		local r = P.Compute(e:GetPos(), L, 75)
		ok = ok and r.clear
		res.props[#res.props + 1] = string.format("%s clear=%s", string.match(e:GetModel(), "[^/]+$"), tostring(r.clear))
	end
end
res.pass = ok and n >= 4
res.n = n
return res
