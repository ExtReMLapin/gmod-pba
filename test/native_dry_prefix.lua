-- "#" sound character in native rendering (parity P2-10). The engine runs no DSP on a "#" sound
-- (soundchars.h CHAR_DRYMIX): no room reverb. The module gave such a voice a source reverb slot, a room send
-- and echoes like any other.
-- Client lua_job, native render on. pba_native.Play / SourceReflect / Echo are wrapped to record the calls
-- (the voices still play); the same file is played with and without "#".
-- Pass: the "#" voice gets a room send of 0, no source reverb slot and no echoes; the plain one keeps its
-- slot and echoes; with pba_native_dry_prefix 0 the "#" voice gets them back.
local A = pba
local N = A.Native
if not (N and N.render and pba_native) then return { pass = false, err = "needs the native render" } end
local FILE = "vo/npc/male01/hi01.wav"
for _ = 1, 100 do
	if N.EnsureSound(FILE) then break end
	job:sleep(0.1)
end
local L = A.ListenerPos()
local pos = L + Vector(200, 0, 0)
local orig = { Play = pba_native.Play, SourceReflect = pba_native.SourceReflect, Echo = pba_native.Echo }
local rec
pba_native.Play = function(...)
	local a = { ... }
	rec.room = a[12]
	return orig.Play(...)
end
pba_native.SourceReflect = function(...) rec.slot = true return orig.SourceReflect(...) end
pba_native.Echo = function(...) rec.echo = true return orig.Echo(...) end
local savedEcho, savedAll = A.cfg.native_echo, A.cfg.native_all
local function run(name)
	rec = { slot = false, echo = false }
	local id = N.PlayVoice(name, pos, 0.1, 0, 100, { srcPos = pos, srcSend = 0.1 })
	A.cfg.native_echo, A.cfg.native_all = 1, 0
	N.Echo({ SoundName = name, SoundLevel = 140, Volume = 1, Pitch = 100, EntIndex = 0 }, pos, true, false)
	if id then pba_native.StopVoice(id) end
	return { id = id and true or false, room = rec.room, slot = rec.slot, echo = rec.echo }
end
local res = { checks = {} }
local ok, err = pcall(function()
	local plain = run(FILE)
	local dry = run("#" .. FILE)
	local savedOpt = A.cfg.native_dry_prefix
	A.cfg.native_dry_prefix = 0
	local off = run("#" .. FILE)
	A.cfg.native_dry_prefix = savedOpt
	res.plain, res.dry, res.off = plain, dry, off
	res.checks.played = plain.id and dry.id
	res.checks.plainSlot = plain.slot
	res.checks.plainEcho = plain.echo
	res.checks.dryNoRoom = dry.room == 0
	res.checks.dryNoSlot = not dry.slot
	res.checks.dryNoEcho = not dry.echo
	res.checks.optionOff = off.slot and off.echo
end)
pba_native.Play, pba_native.SourceReflect, pba_native.Echo = orig.Play, orig.SourceReflect, orig.Echo
A.cfg.native_echo, A.cfg.native_all = savedEcho, savedAll
if not ok then return { pass = false, err = tostring(err) } end
res.fails = {}
for k, v in SortedPairs(res.checks) do if not v then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
