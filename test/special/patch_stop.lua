-- Server CSoundPatch (CreateSound) stopped with :Stop() / faded with :FadeOut() while its entity
-- lives on. Why: CSoundPatch:Stop() ends in the engine's C++ StopSound (CSoundPatch::Shutdown),
-- which does not go through Entity:StopSound (wrapped by pba) nor, probably, EntityEmitSound: the
-- mirror would play forever. Addons use server patches for every engine, siren and machine loop;
-- the existing tests always removed the entity right after :Stop(), which hides this.
-- Map: pba_tworooms (prop in room B). Realm: server (lua_job).
-- Expected: 1 mirror while playing; 0 mirrors 1.5 s after :Stop(); after :FadeOut(0.5) + 2 s, no
-- mirror or a mirror at volume <= 0.05.
-- Returns { pass, playing, afterStop, fadeLeft, fadeVol }.
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
ply:SetPos(Vector(256, 256, 0))
local NAME = "ambient/machines/spin_loop.wav"
local e = ents.Create("prop_dynamic")
e:SetModel("models/props_junk/popcan01a.mdl")
e:SetPos(Vector(784, 256, 40))
e:Spawn()
local function entries()
	local t = {}
	for _, l in pairs(pba.Loops.active) do if l.ent == e and l.name == NAME then t[#t + 1] = l end end
	return t
end
local snd
local ok, res = pcall(function()
	job:sleep(0.2)
	snd = CreateSound(e, NAME)
	snd:Play()
	job:sleep(1)
	local playing = #entries()
	snd:Stop()
	job:sleep(1.5)
	local afterStop = #entries()
	snd:Play()
	job:sleep(1)
	snd:FadeOut(0.5)
	job:sleep(2)
	local left = entries()
	return { playing = playing, afterStop = afterStop, fadeLeft = #left, fadeVol = left[1] and left[1].vol or nil,
		patchPlaying = snd:IsPlaying() }
end)
if snd then snd:Stop() end
if IsValid(e) then e:Remove() end
if not ok then return { pass = false, err = tostring(res) } end
local fadeOk = res.fadeLeft == 0 or (res.fadeVol or 1) <= 0.05
res.pass = res.playing == 1 and res.afterStop == 0 and fadeOk
res.expected = "playing = 1, afterStop = 0, then fadeLeft = 0 or fadeVol <= 0.05"
return res
