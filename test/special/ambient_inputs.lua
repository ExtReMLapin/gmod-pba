-- A looping ambient_generic driven by its inputs while pba follows it: Volume, Pitch, ToggleSound
-- (off then on), FadeOut. Why: each input reaches EntityEmitSound as a change or stop event of the
-- running loop (SND_CHANGE_VOL / SND_CHANGE_PITCH / SND_STOP, the start of an ambient also carries
-- change flags); the follower must apply them to its mirror, not ignore them nor start a second one.
-- Map: pba_tworooms (ambient in room B, listener in room A). Realm: server (lua_job).
-- Expected: Volume 3 -> mirror volume 0.3 (+-0.05); Pitch 150 -> mirror pitch 150 (+-2); ToggleSound
-- -> no mirror; ToggleSound -> one mirror again; FadeOut 1 then 2.5 s -> no mirror or volume <= 0.05.
-- Returns { pass, start, vol, pitch, off, on, fade }.
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
ply:SetPos(Vector(256, 256, 0))
local NAME = "ambient/machines/spin_loop.wav"
util.PrecacheSound(NAME)
local amb = ents.Create("ambient_generic")
amb:SetPos(Vector(784, 256, 64))
amb:SetKeyValue("message", NAME)
amb:SetKeyValue("radius", "1250")
amb:SetKeyValue("health", "10")
amb:SetKeyValue("pitch", "100")
amb:SetKeyValue("pitchstart", "100")
amb:SetKeyValue("spawnflags", "16")
amb:Spawn()
amb:Activate()
local function entries()
	local t = {}
	for _, l in pairs(pba.Loops.active) do if l.ent == amb and l.name == NAME then t[#t + 1] = l end end
	return t
end
local function snap()
	local t = entries()
	return { n = #t, vol = t[1] and math.Round(t[1].vol, 3), pitch = t[1] and t[1].pitch }
end
local ok, res = pcall(function()
	job:sleep(0.2)
	amb:Fire("PlaySound")
	job:sleep(0.6)
	local r = { start = snap() }
	amb:Fire("Volume", "3")
	job:sleep(0.6)
	r.vol = snap()
	amb:Fire("Pitch", "150")
	job:sleep(0.6)
	r.pitch = snap()
	amb:Fire("ToggleSound")
	job:sleep(0.6)
	r.off = snap()
	amb:Fire("ToggleSound")
	job:sleep(0.6)
	r.on = snap()
	amb:Fire("FadeOut", "1")
	job:sleep(2.5)
	r.fade = snap()
	return r
end)
if IsValid(amb) then amb:Fire("StopSound") end
job:sleep(0.3)
if IsValid(amb) then amb:Remove() end
if not ok then return { pass = false, err = tostring(res) } end
local okVol = res.vol.n == 1 and math.abs((res.vol.vol or 0) - 0.3) <= 0.05
local okPitch = res.pitch.n == 1 and math.abs((res.pitch.pitch or 0) - 150) <= 2
local okFade = res.fade.n == 0 or (res.fade.vol or 1) <= 0.05
res.pass = res.start.n == 1 and okVol and okPitch and res.off.n == 0 and res.on.n == 1 and okFade
res.checks = { volume = okVol, pitch = okPitch, off = res.off.n == 0, on = res.on.n == 1, fade = okFade }
res.expected = "start 1 mirror; vol 0.3; pitch 150; off 0; on 1; fade 0 or vol <= 0.05"
return res
