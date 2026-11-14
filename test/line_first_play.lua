-- Bug 60 (d1_trainstation_01 Breencast, "line after line switches to a radio effect without echo"): with
-- pba_native_predecode every file decodes on a worker thread and the first play of a file not decoded yet is
-- left to the engine. A Breencast line is played once (two loudspeaker copies): every short line went to the
-- engine with its SND_SPEAKER flag (the engine's speaker radio preset, no module reverb), while the long line
-- br_welcome05, a mirror that waits for its decode, was rendered by the module (measured: PlayVoice failed
-- 'pending' for br_welcome01/02/03/06/07, native only for 04's second copy and 05).
-- Client lua_job (module rendering): the first play of two spoken lines never decoded in this game (one on a
-- loudspeaker, SND_SPEAKER; one on CHAN_VOICE) relayed 200 u from the listener. Pass: both are module voices
-- (PlayVoice gives an id) at that first play.
local N = pba.Native
if not (N and N.render and pba_native) then return { pass = false, err = "needs native rendering" } end
local function fresh(n)
	local f = "vo/" .. n
	return not pba_native.HasSound(f) and not (pba_native.SoundPending and pba_native.SoundPending(f)) and not (N.loading and N.loading[f])
end
local pick = {}
for _, dir in ipairs({ "breencast", "k_lab", "k_lab2", "trainyard", "npc/barney", "eli_lab", "citadel" }) do
	for _, f in ipairs(file.Find("sound/vo/" .. dir .. "/*.wav", "GAME") or {}) do
		-- a short line (<= pba_max_duration; longer ones are long line mirrors, which wait for their decode)
		if #pick < 2 and fresh(dir .. "/" .. f) and SoundDuration("vo/" .. dir .. "/" .. f) <= (pba.cfg.max_duration or 8) then pick[#pick + 1] = "vo/" .. dir .. "/" .. f end
	end
	if #pick >= 2 then break end
end
if #pick < 2 then return { pass = false, err = "no undecoded line left: restart the map" } end
local got, why = {}, {}
local oE = N.EnsureSound
N.EnsureSound = function(name, now)
	local ok, n, w = oE(name, now)
	if name == pick[1] or name == pick[2] then why[#why + 1] = string.format("%s now=%s ok=%s %s", name, tostring(now), tostring(ok), tostring(w)) end
	return ok, n, w
end
local oV = N.PlayVoice
N.PlayVoice = function(name, ...)
	local id = oV(name, ...)
	if name == pick[1] or name == pick[2] then got[name] = id or false end
	return id
end
local L = pba.ListenerPos()
local S = L + Vector(0, 0, 60)
local ok, err = pcall(function()
	for i, name in ipairs(pick) do
		pba.Process({ SoundName = name, Pos = S, Channel = i == 1 and CHAN_STATIC or CHAN_VOICE, Flags = i == 1 and 64 or 0, -- (SND_SPEAKER: no such global in GMod)
			SoundLevel = 80, Volume = 1, Pitch = 100, EntIndex = 0, DSP = 0 }, true)
	end
end)
local t0 = RealTime()
while RealTime() - t0 < 1.5 and (got[pick[1]] == nil or got[pick[2]] == nil) do job:frames(1) end
N.PlayVoice, N.EnsureSound = oV, oE
if not ok then return { pass = false, err = err } end
local function native(n) return got[n] ~= nil and got[n] ~= false end
return { pass = native(pick[1]) and native(pick[2]), speaker = { pick[1], got[pick[1]] }, voice = { pick[2], got[pick[2]] }, ensure = why,
	option = pba.cfg.native_line_decode, predecode = pba.cfg.native_predecode }
