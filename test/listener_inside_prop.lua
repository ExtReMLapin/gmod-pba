-- Listener inside an object (lua_job, server realm, pba_tworooms): a line traced from outside to a point
-- inside a prop's physics hull hit the prop again every 0.5 u (the trace restarting inside it, StartSolid):
-- up to 6 "walls" for one object. The object holding the listener is ignored (pba_listener_object), as the
-- object holding the source is (pba_source_object). A prop BETWEEN the two ends still counts once.
-- Pass: inside -> 0 walls of that prop; between -> exactly 1.
local P = pba.Paths
local res = { checks = {} }
local function chk(k, ok) res.checks[k] = ok and true or false end
local base = Entity(1):GetPos() + Vector(0, 0, 40)
local e = ents.Create("prop_physics")
e:SetModel("models/props_junk/wood_crate002a.mdl")
e:SetPos(base + Vector(150, 0, 0))
e:Spawn()
local po = e:GetPhysicsObject()
if IsValid(po) then po:EnableMotion(false) end
job:frames(3)
local function count(S, L)
	local n = 0
	for _, w in ipairs(P.Walls(S, L, 6)) do if w.ent == e then n = n + 1 end end
	return n
end
local C = e:WorldSpaceCenter()
-- source outside in the open, listener at the crate's center (and a little off it)
res.inside = count(C + Vector(-120, 0, 0), C)
res.insideOff = count(C + Vector(-120, 30, 10), C + Vector(5, 3, 2))
res.between = count(C + Vector(-120, 0, 0), C + Vector(120, 0, 0))
-- option off: the former count (proves the option is what changes it)
local was = pba.cfg.listener_object
pba.cfg.listener_object = 0
res.off = count(C + Vector(-120, 0, 0), C)
pba.cfg.listener_object = was
chk("optionOff", res.off >= 1)
chk("inside", res.inside == 0)
chk("insideOff", res.insideOff == 0)
chk("between", res.between == 1)
e:Remove()
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
