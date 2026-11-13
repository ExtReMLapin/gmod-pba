-- SoundTime relay, part 1 (client lua_job): records when every relayed SMG shot is scheduled to start.
-- With the server running several ticks per frame (host fps_max 8 on a listen server), a bot's SMG fires
-- 2 shots in one network packet, stamped 75 ms apart (SoundTime). The engine keeps that spacing on the
-- client (fDelay synced to the mixer; snd_show 2 prints e.g. -0.030 / +0.044). pba relays the shot: the
-- start it schedules (native voice: RealTime() + delay; engine copy: its emission) is recorded here.
-- soundtime_fire.lua makes the bot fire, soundtime_check.lua judges.
local A = pba
local N = A.Native
pba_soundtime_log = {}
if N and not N.pba_stOrigPlay then N.pba_stOrigPlay = N.PlayVoice end
if N then
	N.PlayVoice = function(name, pos, g, lp, pitch, opts, ...)
		if isstring(name) and string.find(name, "smg1_fire", 1, true) then
			local t = pba_soundtime_log
			t[#t + 1] = RealTime() + (istable(opts) and opts.delay or 0)
		end
		return N.pba_stOrigPlay(name, pos, g, lp, pitch, opts, ...)
	end
end
return { ok = N ~= nil, render = N and N.render or false }
