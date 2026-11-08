-- Loop on an entity the client does not have yet (outside its PVS when the loop starts: a train or an
-- NPC behind a wall, a long way off), which later reaches the client and moves. Why: the client
-- mirror waits ~3 updates for the entity, then plays on an invisible anchor at the start position
-- and never looks for the entity again (it only retries when it has no anchor, and Entity(idx) taken
-- before the entity existed stays NULL): the loop stays where it started while its source moves on.
-- Map: pba_tworooms (prop in room B, listener in room A). Realm: server (lua_job), client state read
-- back over net. The PVS miss is forced with Entity:SetPreventTransmit for 1.5 s.
-- Expected: once the entity is networked and moved 320 u, the mirror's sound position is within 48 u
-- of the entity (anchor dropped, or anchor following).
-- Returns { pass, onClient, anchored, mirrorPos, entPos, dist }.
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
local NAME = "ambient/machines/spin_loop.wav"
ply:SetPos(Vector(256, 256, 0))
util.AddNetworkString("pba_test_cl")
util.AddNetworkString("pba_test_rep")
local rep
net.Receive("pba_test_rep", function() rep = util.JSONToTable(net.ReadString()) or {} end)
ply:SendLua([[net.Receive("pba_test_cl",function() RunString(net.ReadString(),"pba_test_cl") end)]])
local function client(code) net.Start("pba_test_cl") net.WriteString(code) net.Send(ply) end
local function ask(code, timeout)
	rep = nil
	client(code)
	job:wait(function() return rep ~= nil end, timeout or 5)
	return rep
end
local e = ents.Create("prop_dynamic")
e:SetModel("models/props_junk/popcan01a.mdl")
e:SetPos(Vector(784, 96, 40))
e:Spawn()
e:SetPreventTransmit(ply, true)
local ok, res = pcall(function()
	job:sleep(0.5)
	client([==[function PBA_T_REPLY(t) net.Start("pba_test_rep") net.WriteString(util.TableToJSON(t)) net.SendToServer() end]==])
	e:EmitSound(NAME, 75, 100, 1, CHAN_STATIC)
	job:sleep(1.5) -- the client mirror gives up waiting and anchors at the start position
	e:SetPreventTransmit(ply, false)
	job:sleep(0.7)
	e:SetPos(Vector(784, 416, 40))
	job:sleep(1.5) -- several mirror updates
	local idx = e:EntIndex()
	return ask(([==[
		local idx = %d
		local out = { onClient = IsValid(Entity(idx)) }
		for _, m in pairs(pba.Loops.mirrors) do
			if m.idx == idx then
				local anchored = IsValid(m.anchor)
				local src = anchored and m.anchor:GetPos() or (IsValid(m.ent) and m.ent:WorldSpaceCenter()) or m.pos
				out.anchored, out.mirrorPos = anchored, tostring(src)
				if out.onClient then out.dist = src:Distance(Entity(idx):WorldSpaceCenter()) out.entPos = tostring(Entity(idx):WorldSpaceCenter()) end
			end
		end
		PBA_T_REPLY(out)
	]==]):format(idx)) or { err = "no reply from the client" }
end)
client([==[PBA_T_REPLY = nil net.Receivers["pba_test_cl"] = nil]==])
net.Receivers["pba_test_rep"] = nil
if IsValid(e) then e:StopSound(NAME) e:Remove() end
if not ok then return { pass = false, err = tostring(res) } end
if res.err then res.pass = false return res end
if res.mirrorPos == nil then
	res.pass = nil
	res.note = "no client mirror for the entity: inconclusive"
elseif not res.onClient then
	res.pass = nil
	res.note = "entity never networked to the client: inconclusive"
else
	res.pass = (res.dist or math.huge) <= 48
end
res.expected = "dist <= 48 (the mirror follows the networked entity)"
return res
