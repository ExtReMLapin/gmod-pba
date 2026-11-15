-- meme_pipe (server lua_job): the metal pipe prop (lua/entities/pba_metal_pipe.lua, pba_metal_pipe_stack.lua).
--  1. its physics material is the silent one (no engine impact sound), and the entity hook drops every other sound the
--     pipe emits (the scrape loop of the default material) while ours (pba/pipe/*.wav) and other entities' pass
--  2. a dropped stack of four clangs only with our files (they exist), at a volume in (0, 1], each pipe at least 40 ms
--     between two of its clangs, and at least three clangs
--  3. pba_meme_pipe 0: the pipes on the map are removed, none can be spawned; back to 1: they can again
local res = { checks = {} }
local function check(name, ok, info) res.checks[#res.checks + 1] = { name = name, ok = ok and true or false, info = info } end
local function pipes() local o = {} for _, e in ipairs(ents.FindByClass("pba_metal_pipe")) do o[#o + 1] = e end return o end
for _, e in ipairs(pipes()) do e:Remove() end
RunConsoleCommand("pba_meme_pipe", "1")
job:wait(function() return pba.Pipe.Allowed() end, 3)
local ply = player.GetHumans()[1]
local S = scripted_ents.Get("pba_metal_pipe_stack")
if not (ply and S and S.SpawnStack) then return { pass = false, err = "no player or stack entity", res = res } end

-- 1. material and hook
local one = ents.Create("pba_metal_pipe")
one:SetPos(Vector(256, 256, 60)) one:Spawn()
local ph = one:GetPhysicsObject()
check("silent material", IsValid(ph) and ph:GetMaterial() == "gmod_silent", IsValid(ph) and ph:GetMaterial())
local silence = hook.GetTable().EntityEmitSound and hook.GetTable().EntityEmitSound.pba_metal_pipe_silence
check("the silencing hook is registered", isfunction(silence))
-- the hook's own verdict (other addons' and pba's own EntityEmitSound hooks answer too, so hook.Run would not tell)
local function ask(ent, name) if not silence then return "no hook" end return silence({ Entity = ent, SoundName = name, Volume = 1, Pitch = 100, SoundLevel = 75, Channel = CHAN_AUTO }) end
check("hook drops the engine's sound of a pipe", ask(one, "physics/plastic/plastic_box_scrape_smooth_loop1.wav") == false)
check("hook lets our sound through", ask(one, "pba/pipe/hard_1.wav") == nil)
local other = ents.Create("prop_physics") other:SetModel("models/props_c17/oildrum001.mdl") other:SetPos(Vector(300, 256, 60)) other:Spawn()
check("hook leaves other entities alone", ask(other, "physics/plastic/plastic_box_scrape_smooth_loop1.wav") == nil)
one:Remove() other:Remove()

-- 2. the stack
local log = {}
local t0 = CurTime()
hook.Add("EntityEmitSound", "meme_pipe_log", function(t)
	if IsValid(t.Entity) and t.Entity:GetClass() == "pba_metal_pipe" then
		log[#log + 1] = { t = CurTime() - t0, ent = t.Entity:EntIndex(), name = t.SoundName, vol = t.Volume }
	end
end)
local made = S.SpawnStack(ply, Vector(256, 256, 2), 0)
check("a stack is four pipes", #made == 4, #made)
job:sleep(4)
hook.Remove("EntityEmitSound", "meme_pipe_log")
local engine, missing, badvol, tooclose = 0, 0, 0, 0
local last = {}
for _, e in ipairs(log) do
	if not string.StartWith(e.name, "pba/pipe/") then engine = engine + 1
	elseif not file.Exists("sound/" .. e.name, "GAME") then missing = missing + 1 end
	if e.vol <= 0 or e.vol > 1 then badvol = badvol + 1 end
	if last[e.ent] and e.t - last[e.ent] < 0.04 then tooclose = tooclose + 1 end
	last[e.ent] = e.t
end
check("at least 3 clangs from the fall", #log >= 3, #log)
check("only our files (no engine sound)", engine == 0, engine)
check("the files exist", missing == 0, missing)
check("volumes in (0, 1]", badvol == 0, badvol)
check("a pipe never clangs twice within 40 ms", tooclose == 0, tooclose)
res.sounds = #log

-- 3. the option
RunConsoleCommand("pba_meme_pipe", "0")
job:wait(function() return not pba.Pipe.Allowed() end, 3)
job:sleep(1.6)
check("option 0: the pipes are removed", #pipes() == 0, #pipes())
check("option 0: no stack can be made", #S.SpawnStack(ply, Vector(256, 256, 2), 0) == 0)
local lone = ents.Create("pba_metal_pipe") lone:Spawn()
job:sleep(0.2)
check("option 0: a pipe spawned anyway removes itself", not IsValid(lone))
RunConsoleCommand("pba_meme_pipe", "1")
job:wait(function() return pba.Pipe.Allowed() end, 3)
check("option 1 again: a stack can be made", #S.SpawnStack(ply, Vector(256, 256, 2), 0) == 4)
job:sleep(0.5)
for _, e in ipairs(pipes()) do e:Remove() end

res.pass = true
for _, c in ipairs(res.checks) do if not c.ok then res.pass = false end end
return res
