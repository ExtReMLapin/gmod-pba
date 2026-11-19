-- A loop's range-edge fade-in reaches its native voice whatever pba_native_vol_now (client lua_job, pba_tworooms, native
-- rendering on, player in room A; review M7). pba_loops_edge_fade fades a loop joined midway in from -60 dB by scaling
-- its volume every frame; that volume went to the voice through the "volume change at once" path, which pba_native_vol_now
-- 0 switches off: the voice stayed at -60 dB until an evaluation (none for a still listener and source: reeval_adaptive).
-- A hidden client loop's mirror is put at the fade's floor (its voice sent there), then faded in over 1 s with
-- pba_native_vol_now 0. Pass: 1.3 s later the voice's last gain is within 1 dB of its gain before the floor.
-- pre: `local CONTROL = true` runs with pba_loops_edge_fade_direct 0: passes when the voice is still more than 3 dB under its gain (the old behaviour: -7.8 dB on main).
local A = pba
local N = A.Native
if not (N and N.render) then return { pass = false, err = "native renderer not running" } end
local LP = A.Loops
local NAME = "ambient/machines/spin_loop.wav"
local recv = net.Receivers and net.Receivers["pba_loop"]
local updateMirror
for i = 1, 60 do
	local n, v = debug.getupvalue(recv, i)
	if not n then break end
	if n == "updateMirror" then updateMirror = v end
end
if not updateMirror then return { pass = false, err = "updateMirror not found" } end
A.SetOverride("loops_edge_fade_direct", CONTROL and 0 or 1)
A.SetOverride("loops_edge_fade", 1)
local e = ClientsideModel("models/hunter/blocks/cube025x025x025.mdl", RENDERGROUP_OTHER)
e:SetNoDraw(true)
e:SetPos(Vector(784, 256, 40))
local gains = {}
local origUpdate = pba_native.Update
pba_native.Update = function(id, pos, g, ...)
	gains[id] = g
	return origUpdate(id, pos, g, ...)
end
local res = { checks = {} }
local ok, err = pcall(function()
	local p = CreateSound(e, NAME)
	p:SetSoundLevel(80)
	p:PlayEx(1, 100)
	job:sleep(1.5)
	local m
	for _, x in pairs(LP.mirrors) do if x.client and x.ent == e then m = x end end
	res.checks.mirrorNative = m ~= nil and m.nativeId ~= nil
	if not res.checks.mirrorNative then return end
	job:sleep(0.5) -- (its ramp over)
	local id = m.nativeId
	local full = m.lastEval and m.lastEval.gain
	res.full = full
	-- the fade's floor, sent to the voice (as at a join: the first value it plays)
	m.edgeK = LP.EDGE_FLOOR
	updateMirror(m, false, 1, m.pitch)
	res.floor = gains[id]
	-- then the fade, with the "volume at once" path off
	A.SetOverride("native_vol_now", 0)
	m.edgeT0 = RealTime()
	job:sleep(1.3)
	res.last = gains[m.nativeId or id]
	res.lastDb = res.last and full and 20 * math.log10(res.last / full)
	res.checks.floorSent = res.floor ~= nil and full ~= nil and res.floor < full * 0.01
	res.checks.fadedIn = res.lastDb ~= nil and res.lastDb > -1
	p:Stop()
end)
pba_native.Update = origUpdate
A.SetOverride("native_vol_now", nil)
A.SetOverride("loops_edge_fade", nil)
A.SetOverride("loops_edge_fade_direct", nil)
if IsValid(e) then e:Remove() end
if not ok then return { pass = false, err = tostring(err) } end
res.fails = {}
for k, okc in SortedPairs(res.checks) do if not okc then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
if CONTROL then
	res.controlRed = not res.pass
	res.pass = res.checks.mirrorNative and res.checks.floorSent and res.lastDb ~= nil and res.lastDb < -3 or false
end
return res
