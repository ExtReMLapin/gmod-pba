-- Diffuse model (pba_diffuse) in room 14 of pba_demo ("the long way round"): the music behind the thick
-- wall is heard through the corridor (almost 4x the straight line, 4 corners). With the model on, that
-- corridor voice is mostly diffuse (reverberant tunnel preset on the engine path, blurred and reverbed in
-- the module) and a few dB lower (the corridor's walls absorb), never faded out; off, it is a clean
-- voice. lua_job, client realm, pba_demo (any demo mode: computed directly).
-- Returns { pass, on = {...}, off = {...} }.
if game.GetMap() ~= "pba_demo" then return { pass = false, err = "needs pba_demo" } end
local A = pba
local src
for _, e in ipairs(ents.FindInBox(Vector(6256, -640, 0), Vector(6640, -384, 192))) do
	if IsValid(e) and e:GetModel() and string.find(e:GetModel(), ".mdl", 1, true) and not e:IsPlayer() then src = e break end
end
-- the speaker (pba_detour_src) is not networked while the player is elsewhere: its map position then
local S = IsValid(src) and src:WorldSpaceCenter() or Vector(6448.26, -512.36, 14.97)
local L = Vector(6448, -176, 64)
local old = A.override.diffuse
local function measure(on)
	A.SetOverride("diffuse", on and 1 or 0)
	A.Paths.InvalidateCache()
	local r = A.Paths.Compute(S, L, 80)
	local best
	for _, v in ipairs(r.voices or {}) do if v.kind == "portal" and (not best or v.level > best.level) then best = v end end
	local p = r.paths and r.paths[1]
	return { voice = best ~= nil, level = best and math.Round(best.level, 1), diffuse = best and math.Round(best.diffuse or 0, 2),
		dsp = best and A.AC.DSPForVoice(best.lp, best.diffuse), lp = best and best.lp, absorbDb = p and math.Round(p.absorbDb or 0, 1),
		ratio = p and p.direct and math.Round(p.length / math.max(p.direct, 1), 2), bend = p and p.bendDeg and math.Round(p.bendDeg) }
end
local on, off = measure(true), measure(false)
A.SetOverride("diffuse", old)
A.Paths.InvalidateCache()
local pass = on.voice and off.voice and on.diffuse >= 0.5 and (on.dsp == 116 or on.dsp == 117) and off.diffuse == 0
	and off.level - on.level >= 3 and off.level - on.level <= 20.5
return { pass = pass, on = on, off = off }
