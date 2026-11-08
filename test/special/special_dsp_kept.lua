-- A sound with its own DSP preset (55: radio / loudspeaker family, as scenes and addons set for a
-- radio voice) behind a wall. Why: the client copy's DSP is replaced by pba's muffling preset (30/31)
-- whenever the path is muffled, so a radio voice behind a door loses its radio effect (vanilla keeps
-- it, through the wall).
-- Map: pba_tworooms (source in room B, listener in room A, door closed). Realm: server (lua_job),
-- with a probe on the client (copies pba re-emits, read back over net). Client pba_native_render is
-- set to 0 for the test (engine copies) and restored.
-- Expected: at least one client copy, and every copy keeps DSP 55.
-- Returns { pass, copies = { dsp, chan, name } }.
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
local DSP = 55
local NAME = "ambient/alarms/klaxon1.wav"
ply:SetPos(Vector(256, 256, 0))
local door = ents.FindByName("door1")[1]
if IsValid(door) then door:Fire("Close") end
-- client bridge: run code on the client, get a table back
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
local ok, res = pcall(function()
	job:sleep(0.5)
	client([==[
		PBA_T = { copies = {}, native = GetConVar("pba_native_render"):GetString() }
		RunConsoleCommand("pba_native_render", "0")
		function PBA_T.reply(t) net.Start("pba_test_rep") net.WriteString(util.TableToJSON(t)) net.SendToServer() end
		hook.Add("EntityEmitSound", "!pba_test_probe", function(t)
			if pba.reemitting and string.find(t.SoundName, "klaxon1", 1, true) then
				table.insert(PBA_T.copies, { name = t.SoundName, dsp = t.DSP, chan = t.Channel })
			end
		end)
	]==])
	job:sleep(1.5)
	src:EmitSound(NAME, 80, 100, 1, CHAN_AUTO, 0, DSP)
	job:sleep(1)
	return ask([==[PBA_T.reply({ copies = PBA_T.copies })]==]) or { err = "no reply from the client" }
end)
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
local copies, kept = res.copies or {}, 0
for _, c in ipairs(copies) do if c.dsp == DSP then kept = kept + 1 end end
if #copies == 0 then
	res.pass = nil
	res.note = "no client copy (sound not muffled / not relayed): inconclusive"
else
	res.pass = kept == #copies
end
res.kept = kept
res.expected = "every copy has DSP " .. DSP
return res
