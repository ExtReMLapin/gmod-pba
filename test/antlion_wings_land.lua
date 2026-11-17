-- Antlion wings loop (part 3, server lua_job): the antlion leaps (wings open), glides, lands (wings closed, on the
-- ground); then 1.2 s. Pass: no wing loop of it still followed by pba (the engine stopped it: m_bWingsOpen is
-- false). Inconclusive (nil): the antlion never leapt.
local a = ANTLION_WINGS
local ply = player.GetHumans()[1]
if not IsValid(a) then return { pass = false, err = "no antlion" } end
local t0 = RealTime()
local st = ANTLION_ST
while RealTime() - t0 < 20 and not st.landed do
	if IsValid(ply) and IsValid(a) then a:UpdateEnemyMemory(ply, ply:GetPos()) end
	job:sleep(0.1)
end
hook.Remove("Think", "antlion_wings_watch")
local flew, landed = st.flew, st.landed
if not flew then return { pass = nil, err = "antlion never opened its wings", pos = tostring(a:GetPos()) } end
if not landed then return { pass = nil, err = "antlion never landed", pos = tostring(a:GetPos()) } end
job:sleep(math.max(0, 1.2 - (CurTime() - (st.landT or CurTime()))))
local left = 0
for _, l in pairs(pba.Loops.active) do
	if l.idx == a:EntIndex() and string.find(string.lower(l.name or ""), "fly1", 1, true) then left = left + 1 end
end
return { pass = left == 0, left = left, wings = a:GetInternalVariable("m_bWingsOpen"), health = a:Health() }
