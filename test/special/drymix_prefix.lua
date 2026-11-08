-- A dry-mix sound ("#" sound character: "wav bypasses dsp fx" in the engine) behind a wall. Why: pba
-- muffles engine copies with a DSP preset; if the engine skips DSP for "#" sounds, the copy is only
-- quieter, not muffled. Whether the per-sound DSP preset is bypassed too is not known from Lua:
-- REPORT ONLY (pass = nil). The copies are listed with their name and DSP; a "#" copy with a DSP
-- preset is the suspicious case to check by ear or with the FFT bench (dsp_slope.py).
-- Map: pba_tworooms (source in room B, listener in room A, door closed). Realm: server (lua_job),
-- client probe of the copies. Client pba_native_render 0 for the test.
-- Returns { pass = nil, copies = { name, dsp }, dryWithDsp }.
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
local NAME = "#ambient/alarms/klaxon1.wav"
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
local ok, res = pcall(function()
	job:sleep(0.5)
	client([==[
		PBA_T = { copies = {}, native = GetConVar("pba_native_render"):GetString() }
		RunConsoleCommand("pba_native_render", "0")
		function PBA_T.reply(t) net.Start("pba_test_rep") net.WriteString(util.TableToJSON(t)) net.SendToServer() end
		hook.Add("EntityEmitSound", "!pba_test_probe", function(t)
			if pba.reemitting and string.find(t.SoundName, "klaxon1", 1, true) then
				table.insert(PBA_T.copies, { name = t.SoundName, dsp = t.DSP })
			end
		end)
	]==])
	job:sleep(1.5)
	src:EmitSound(NAME, 80, 100, 1, CHAN_AUTO)
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
local dry = 0
for _, c in ipairs(res.copies or {}) do
	if string.sub(c.name or "", 1, 1) == "#" and (c.dsp or 0) > 0 then dry = dry + 1 end
end
res.dryWithDsp = dry
res.pass = nil
res.note = "report only: a '#' copy with a DSP preset may not be muffled at all (engine dry mix)"
return res
