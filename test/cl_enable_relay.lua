-- A player who switched pba off on his side (pba_cl_enable 0) gets the engine's own sounds: the server
-- relays nothing to him and does not muffle them for him (side bug 40). Server lua_job, pba_tworooms
-- closed (a wall between the host and a source).
-- The host's preference is changed through his console (Player:ConCommand), as he would in the menu; the
-- client tells the server (pba_ready with its state). Three sounds behind a wall are emitted with pba on
-- for him (control: relayed or muffled), then three with pba_cl_enable 0. Pass: control relayed, none
-- relayed nor muffled for him once off, and relayed again once back on.
local A = pba
local ply = player.GetHumans()[1]
if not IsValid(ply) then return { pass = false, err = "no human player" } end
local NAME = "vo/npc/male01/hi01.wav"
local eye = A.PlayerEar(ply)
local S
math.randomseed(7)
for _ = 1, 800 do
	local p = eye + Vector(math.random(-700, 700), math.random(-700, 700), math.random(-30, 30))
	if bit.band(util.PointContents(p), MASK_SOLID) == 0 and p:Distance(eye) > 200 and #A.Paths.Walls(p, eye, 1) > 0 then S = p break end
	job:step()
end
if not S then return { pass = false, err = "no source behind a wall found" } end

-- what reaches him: relays (net.Send to a list holding him) and muffled re-emissions (stats)
local sends = 0
local origSend = net.Send
net.Send = function(to, ...)
	local hit = to == ply or (istable(to) and table.HasValue(to, ply))
	if hit and A.relaying then sends = sends + 1 end
	return origSend(to, ...)
end
local function phase(on)
	ply:ConCommand("pba_cl_enable " .. (on and 1 or 0))
	job:sleep(1.5) -- the convar, then the client's message to the server
	sends = 0
	local m0, r0 = A.stats.relayMuffled or 0, A.stats.relayed or 0
	for _ = 1, 3 do
		A.relaying = true
		EmitSound(NAME, S, 0, CHAN_AUTO, 1, 75, 0, 100)
		A.relaying = nil
		job:sleep(0.4)
	end
	return { sends = sends, relayed = (A.stats.relayed or 0) - r0, muffled = (A.stats.relayMuffled or 0) - m0 }
end
local res = { checks = {} }
local ok, err = pcall(function()
	res.on = phase(true)
	res.off = phase(false)
	res.back = phase(true)
end)
net.Send = origSend
A.relaying = nil
ply:ConCommand("pba_cl_enable 1")
if not ok then return { pass = false, err = tostring(err) } end
local c = res.checks
c.controlRelayed = res.on.relayed + res.on.muffled > 0
c.offVanilla = res.off.sends == 0 and res.off.relayed == 0 and res.off.muffled == 0
c.backRelayed = res.back.relayed + res.back.muffled > 0
res.option = A.cfg.relay_cl_enable
res.fails = {}
for k, v in SortedPairs(c) do if not v then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
