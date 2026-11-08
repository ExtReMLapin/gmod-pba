-- Loops started CLIENT-side behind a wall: a CSoundPatch made by client Lua (CreateSound, the way
-- addon vehicles, weapons and machines play their engine loops) and a client Entity:EmitSound of a
-- looping file. Why: the client hook rejects loops (A.Eligible) and only long non-looping sounds are
-- followed on the client (Loops.HandleClient): such loops are left vanilla and cross every wall.
-- Map: pba_tworooms (prop in room B, listener in room A, door closed). Realm: server (lua_job); the
-- client part runs over net and reports how pba's client hook answered.
-- Expected: pba takes both loops over (its client hook returns false, or a client mirror "cl:..." of
-- the loop exists).
-- Returns { pass, patch = { seen, taken, mirror }, emit = { seen, taken, mirror } }.
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
ply:SetPos(Vector(256, 256, 0))
local door = ents.FindByName("door1")[1]
if IsValid(door) then door:Fire("Close") end
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
e:SetPos(Vector(784, 256, 40))
e:Spawn()
local ok, res = pcall(function()
	job:sleep(1) -- networked to the client
	local idx = e:EntIndex()
	return ask(([==[
		local idx, NAME1, NAME2 = %d, "ambient/machines/spin_loop.wav", "ambient/machines/lab_loop1.wav"
		local ent = Entity(idx)
		local function reply(t) net.Start("pba_test_rep") net.WriteString(util.TableToJSON(t)) net.SendToServer() end
		if not IsValid(ent) then reply({ err = "entity not on the client" }) return end
		local hooks = hook.GetTable().EntityEmitSound
		local orig = hooks and hooks.pba
		if not orig then reply({ err = "pba client hook not installed" }) return end
		local out = { patch = { seen = false, taken = false }, emit = { seen = false, taken = false } }
		local cur
		hook.Add("EntityEmitSound", "pba", function(t)
			local r = orig(t)
			if cur and t.Entity == ent and not pba.reemitting then
				out[cur].seen = true
				if r == false then out[cur].taken = true end
			end
			return r
		end)
		local function mirror(name)
			for k, m in pairs(pba.Loops.mirrors) do if m.client and m.idx == idx and m.name == name then return true end end
			return false
		end
		cur = "patch"
		local p = CreateSound(ent, NAME1)
		p:Play()
		cur = "emit"
		ent:EmitSound(NAME2, 75, 100, 1, CHAN_STATIC)
		cur = nil
		timer.Simple(1, function()
			hook.Add("EntityEmitSound", "pba", orig)
			out.patch.mirror, out.emit.mirror = mirror(NAME1), mirror(NAME2)
			p:Stop()
			if IsValid(ent) then ent:StopSound(NAME2) end
			reply(out)
		end)
	]==]):format(idx), 6) or { err = "no reply from the client" }
end)
client([==[net.Receivers["pba_test_cl"] = nil]==])
net.Receivers["pba_test_rep"] = nil
if IsValid(e) then e:Remove() end
if not ok then return { pass = false, err = tostring(res) } end
if res.err then res.pass = false return res end
local function took(x) return x and (x.taken or x.mirror) end
res.pass = took(res.patch) and took(res.emit)
res.expected = "patch and emit both taken (hook returned false, or a client mirror exists)"
return res
