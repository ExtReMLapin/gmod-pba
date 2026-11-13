-- A sound's own DSP preset under native rendering (parity plan P1-9). The engine filters a sound that
-- carries its own preset (EmitSound's dsp argument: an addon's radio or walkie-talkie voice, presets
-- 55-59; a scene's m_nSpecialDSP) through that preset. The module has no DSP presets: a voice it plays
-- loses the effect. With pba_keep_dsp (on by default) such a sound stays with the engine, its preset
-- kept and muffled by volume, as without native rendering.
-- Client lua_job, native rendering on, pba_tworooms (any map with a wall near the player works).
-- Pass (res.checks): with DSP 55, a source behind a wall is re-emitted by the engine with preset 55 and
-- no native voice (ownMuffled), a clear one in "everything native" is left to the engine (ownClear);
-- a long sound taken over as a mirror (cl_loops, client long sounds) with DSP 55 is an engine patch, not a
-- native voice (loopOwn); controls: the same sound without DSP is played by the module (plainNative: the module is really
-- active), and pba_keep_dsp 0 gives it back to the module (optionOff).
local A = pba
local N = A.Native
if not (N and N.ready and N.render and pba_native) then
	return { pass = false, err = "native renderer not running (pba_native_render 1, module loaded)" }
end
local L = A.ListenerPos()
if not L then return { pass = false, err = "no listener" } end
local NAME = "vo/npc/male01/hi01.wav"
N.EnsureSound(NAME)
job:sleep(0.5)

-- one obstructed and one clear source near the listener
local blocked, clear
math.randomseed(3)
for _ = 1, 600 do
	if blocked and clear then break end
	local S = L + Vector(math.random(-900, 900), math.random(-900, 900), math.random(-40, 40))
	if bit.band(util.PointContents(S), MASK_SOLID) == 0 and S:Distance(L) > 150 then
		local r = A.Paths.Compute(S, L, 75)
		if r.clear then clear = clear or S
		elseif r.voices and #r.voices > 0 then blocked = blocked or S end
	end
	job:step()
end
if not (blocked and clear) then return { pass = false, err = "no blocked + clear source pair found", blocked = blocked, clear = clear } end

-- test-scoped wrappers (restored below): native voices started, engine emissions with their preset
local played, emitted = 0, {}
local playVoice, emit = N.PlayVoice, A.Emit
N.PlayVoice = function(...)
	local id = playVoice(...)
	if id then played = played + 1 end
	return id
end
A.Emit = function(fn, ...)
	local a = { ... }
	emitted[#emitted + 1] = a[#a] -- the DSP preset is the last argument of every EmitSound form
	return emit(fn, ...)
end
local keep, all = GetConVarNumber("pba_keep_dsp"), GetConVarNumber("pba_native_all")
local function data(S, dsp)
	return { SoundName = NAME, OriginalSoundName = NAME, Pos = S, SoundLevel = 75, Pitch = 100, Volume = 1,
		Channel = CHAN_AUTO, Flags = 0, DSP = dsp, Entity = game.GetWorld(), EntIndex = 0 }
end
local function run(S, dsp)
	played, emitted = 0, {}
	local taken = A.Process(data(S, dsp), true)
	job:sleep(0.6) -- propagation delays fire on timers
	return { taken = taken, played = played, dsp = emitted[1], emitted = #emitted }
end

local res = { checks = {} }
local ok, err = pcall(function()
	A.cfg.keep_dsp = 1
	A.cfg.native_all = 0
	res.plain = run(blocked, 0)
	res.own = run(blocked, 55)
	A.cfg.native_all = 1
	res.ownClear = run(clear, 55)
	A.cfg.native_all = 0
	A.cfg.keep_dsp = 0
	res.off = run(blocked, 55)
	A.cfg.keep_dsp = 1
	-- long client sound mirrored by cl_loops: a client prop behind the wall plays a long non-looping file
	local long
	for _, f in ipairs(file.Find("sound/music/*.mp3", "GAME")) do
		local d = A.SoundDuration("music/" .. f)
		if d and d > (A.cfg.max_duration or 10) + 5 then long = "music/" .. f break end
	end
	local LP = A.Loops
	-- the long file decoded first: a >512 KB file is decoded asynchronously (N.EnsureSound "pending", 0.15-0.25 s
	-- for this 1.7 MB mp3 on an idle game, more under load) and the mirror has no voice meanwhile; the step
	-- passed only when an earlier run left it in the module's sound cache, else failed under load (side bug 42)
	if long then
		N.EnsureSound(long)
		job:wait(function() return pba_native.HasSound(long) end, 10)
		res.longDecoded = pba_native.HasSound(long)
	end
	if long and LP and LP.HandleClient then
		local e = ClientsideModel("models/props_junk/PopCan01a.mdl")
		e:SetPos(blocked)
		local function mirror(dsp)
			local d = data(blocked, dsp)
			d.SoundName, d.Entity, d.Channel = long, e, CHAN_STATIC
			local taken = LP.HandleClient(d)
			local key = "cl:" .. e:EntIndex() .. ":" .. CHAN_STATIC .. ":" .. long
			job:sleep(0.3)
			local m = LP.mirrors[key]
			local out = { taken = taken, native = m and m.nativeId ~= nil, patch = m and m.patch ~= nil }
			LP.StopClient(e:EntIndex())
			return out
		end
		res.loopPlain = mirror(0)
		res.loopOwn = mirror(55)
		e:Remove()
	end
	res.long = long
end)
N.PlayVoice, A.Emit = playVoice, emit
A.cfg.keep_dsp, A.cfg.native_all = keep, all
if not ok then return { pass = false, err = tostring(err) } end

local c = res.checks
c.plainNative = res.plain.played >= 1
c.ownMuffled = res.own.played == 0 and res.own.dsp == 55
c.ownClear = res.ownClear.played == 0 and res.ownClear.taken == false
c.optionOff = res.off.played >= 1
c.loopPlainNative = res.loopPlain ~= nil and res.loopPlain.native == true
c.loopOwn = res.loopOwn ~= nil and res.loopOwn.taken == true and res.loopOwn.native == false and res.loopOwn.patch == true
res.fails = {}
for k, v in SortedPairs(c) do if not v then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
