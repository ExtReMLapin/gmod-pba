-- A sound on a game channel >= 128 (CHAN_USER_BASE is 136: addons and SWEPs pick their own
-- channels) behind a wall. Why: the relay writes the channel as a signed 8-bit integer: 140 does not
-- fit, the client gets another channel, and the copy loses the engine's channel rule (a new sound on
-- the entity's channel cuts the previous one) or plays on the wrong one.
-- Map: pba_tworooms (source in room B, listener in room A, door closed). Realm: server (lua_job),
-- with a client probe of the copies (read back over net). Client pba_native_render 0 for the test.
-- Expected: at least one client copy, every copy on channel 140.
-- Returns { pass, copies = { chan, dsp } }.
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
local CHAN = 140
local NAME = "ambient/alarms/klaxon1.wav"
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
local src = ents.Create("prop_dynamic")
src:SetModel("models/props_junk/popcan01a.mdl")
src:SetPos(Vector(784, 256, 40))
src:Spawn()
local hookChan
local hooks = hook.GetTable().EntityEmitSound
local orig = hooks and hooks.pba
local ok, res = pcall(function()
	job:sleep(0.5)
	client([==[
		PBA_T = { copies = {}, native = GetConVar("pba_native_render"):GetString() }
		RunConsoleCommand("pba_native_render", "0")
		function PBA_T.reply(t) net.Start("pba_test_rep") net.WriteString(util.TableToJSON(t)) net.SendToServer() end
		hook.Add("EntityEmitSound", "!pba_test_probe", function(t)
			if pba.reemitting and string.find(t.SoundName, "klaxon1", 1, true) then
				table.insert(PBA_T.copies, { chan = t.Channel, dsp = t.DSP })
			end
		end)
	]==])
	job:sleep(1.5)
	if orig then
		hook.Add("EntityEmitSound", "pba", function(t)
			if t.Entity == src then hookChan = t.Channel end
			return orig(t)
		end)
	end
	src:EmitSound(NAME, 80, 100, 1, CHAN)
	job:sleep(0.2)
	if orig then hook.Add("EntityEmitSound", "pba", orig) end
	job:sleep(0.8)
	return ask([==[PBA_T.reply({ copies = PBA_T.copies })]==]) or { err = "no reply from the client" }
end)
if orig then hook.Add("EntityEmitSound", "pba", orig) end
client([==[
	hook.Remove("EntityEmitSound", "!pba_test_probe")
	if PBA_T then RunConsoleCommand("pba_native_render", PBA_T.native) end
	PBA_T = nil
	net.Receivers["pba_test_cl"] = nil
]==])
net.Receivers["pba_test_rep"] = nil
if IsValid(src) then src:StopSound(NAME) src:Remove() end
if not ok then return { pass = false, err = tostring(res) } end
if res.err then res.pass = false return res end
res.serverHookChannel = hookChan
local copies, right = res.copies or {}, 0
for _, c in ipairs(copies) do if c.chan == CHAN then right = right + 1 end end
if #copies == 0 or hookChan ~= CHAN then
	res.pass = nil
	res.note = "no client copy, or the engine did not keep channel " .. CHAN .. " itself: inconclusive"
else
	res.pass = right == #copies
end
res.expected = "every copy on channel " .. CHAN
return res
