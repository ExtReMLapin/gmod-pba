-- ambient_generic "Play everywhere" (spawnflag 1: SNDLVL_NONE, a 2D announcement heard at the same
-- level everywhere), looping and long one-shot. Why: such sounds are global on purpose and must stay
-- untouched: no mirror, no relay, no muffling, also when the map started them before pba's hooks
-- (AdoptAmbients skips them) and when they are long.
-- Map: pba_tworooms (ambients in room B, listener in room A). Realm: server (lua_job).
-- Expected: neither ambient is followed by Loops nor taken by pba's hook (never returns false).
-- Returns { pass, loop = { followed, taken }, long = { followed, taken } }.
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return { pass = false, err = "needs pba_tworooms with a human" } end
ply:SetPos(Vector(256, 256, 0))
local function ambient(msg, flags)
	util.PrecacheSound(msg)
	local a = ents.Create("ambient_generic")
	a:SetPos(Vector(784, 256, 64))
	a:SetKeyValue("message", msg)
	a:SetKeyValue("radius", "1250")
	a:SetKeyValue("health", "10")
	a:SetKeyValue("pitch", "100")
	a:SetKeyValue("pitchstart", "100")
	a:SetKeyValue("spawnflags", tostring(flags))
	a:Spawn()
	a:Activate()
	return a
end
local LOOP, LONG = "ambient/machines/spin_loop.wav", "vo/breencast/br_overwatch07.wav"
local a1 = ambient(LOOP, 1 + 16)       -- everywhere, start silent
local a2 = ambient(LONG, 1 + 16 + 32)  -- everywhere, start silent, not looped
local hooks = hook.GetTable().EntityEmitSound
local orig = hooks and hooks.pba
local taken = {}
local function followed(name)
	for _, l in pairs(pba.Loops.active) do if l.name == name then return true end end
	return false
end
local ok, res = pcall(function()
	if not orig then error("pba hook not installed") end
	job:sleep(0.3)
	hook.Add("EntityEmitSound", "pba", function(t)
		local name = t.SoundName
		local r = orig(t)
		if r == false then taken[name] = true end
		return r
	end)
	a1:Fire("PlaySound")
	a2:Fire("PlaySound")
	job:sleep(1)
	hook.Add("EntityEmitSound", "pba", orig)
	return { loop = { followed = followed(LOOP), taken = taken[LOOP] == true },
		long = { followed = followed(LONG), taken = taken[LONG] == true } }
end)
if orig then hook.Add("EntityEmitSound", "pba", orig) end
for _, a in ipairs({ a1, a2 }) do if IsValid(a) then a:Fire("StopSound") end end
job:sleep(0.3)
for _, a in ipairs({ a1, a2 }) do if IsValid(a) then a:Remove() end end
if not ok then return { pass = false, err = tostring(res) } end
res.pass = not (res.loop.followed or res.loop.taken or res.long.followed or res.long.taken)
res.expected = "all false"
return res
