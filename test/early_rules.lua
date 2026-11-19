-- The early-line takeover follows this client's rules (client lua_job, pba_tworooms, native rendering on, player in room
-- A; review M8). A line the engine started before this client was ready reaches it marked "blocked" whatever its verdict
-- (sv_sound noteEarly), and LP.TakeEarly hands it to the module:
--  1. clear: in clear sight with pba_native_all 0 every other sound is the engine's; the early line was taken all the same.
--     Pass: LP.TakeEarly answers "clear" (no mirror).
--  2. dry: a "#" line behind a wall is re-emitted muffled for an unready player WITHOUT its "#" (sv_sound reemitMuffled, ev
--     under its volume). Muting the engine copy sent SND_CHANGE_VOL to the "#" name: no such sound, the engine started a
--     new one and the copy stayed audible under the module's voice. Pass: the mute is sent to the name without "#".
local A = pba
local N = A.Native
if not (N and N.render) then return { pass = false, err = "native renderer not running" } end
local LP = A.Loops
local LINE = "vo/trainyard/al_thisday.wav"
local res = { checks = {} }
local names = {}
local meta = FindMetaTable("Entity")
local origEnt, origGlobal = meta.EmitSound, EmitSound
local function spy(name, flags)
	if flags and bit.band(flags, SND_CHANGE_VOL) ~= 0 and string.find(name or "", "al_thisday", 1, true) then names[#names + 1] = name return true end
end
meta.EmitSound = function(self, name, lvl, pitch, vol, chan, flags, ...)
	if spy(name, flags) then return end
	return origEnt(self, name, lvl, pitch, vol, chan, flags, ...)
end
EmitSound = function(name, pos, idx, chan, vol, lvl, flags, ...)
	if spy(name, flags) then return end
	return origGlobal(name, pos, idx, chan, vol, lvl, flags, ...)
end
local L = A.ListenerPos()
local ok, err = pcall(function()
	job:wait(function() return (N.EnsureSound(LINE)) end, 10)
	-- 1. clear, native_all 0
	A.SetOverride("native_all", 0)
	local d1 = { SoundName = LINE, Pos = L + Vector(120, 0, -20), SoundLevel = 80, Pitch = 100, Volume = 1, Channel = CHAN_VOICE, Flags = 0, DSP = 0,
		EntIndex = 0, elapsed = 0.3, ev = 1, blocked = true }
	res.clearWhy = LP.TakeEarly(d1)
	for k, m in pairs(LP.mirrors) do if m.early then LP.mirrors[k] = nil if m.nativeId then pba_native.StopVoice(m.nativeId) end end end
	A.SetOverride("native_all", nil)
	for i = #names, 1, -1 do names[i] = nil end
	-- 2. a "#" line muffled behind the wall (room B), native_all 1
	local d2 = { SoundName = "#" .. LINE, Pos = Vector(784, 256, 40), SoundLevel = 80, Pitch = 100, Volume = 1, Channel = CHAN_VOICE, Flags = 0, DSP = 0,
		EntIndex = 0, elapsed = 0.3, ev = 0.25, blocked = true }
	res.dryWhy = LP.TakeEarly(d2)
	job:wait(function() return #names > 0 end, 2)
	res.muteNames = names
	for k, m in pairs(LP.mirrors) do if m.early then LP.mirrors[k] = nil if m.nativeId then pba_native.StopVoice(m.nativeId) end end end
	res.checks.clearLeft = res.clearWhy == "clear"
	res.checks.dryTaken = res.dryWhy == "taken"
	res.checks.dryMuteName = names[1] == LINE
end)
meta.EmitSound, EmitSound = origEnt, origGlobal
A.SetOverride("native_all", nil)
if not ok then return { pass = false, err = tostring(err) } end
res.fails = {}
for k, okc in SortedPairs(res.checks) do if not okc then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
