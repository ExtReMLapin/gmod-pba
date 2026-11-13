-- Perf bench collector (server): PBA's EntityEmitSound hook timed per sound, and the tick time.
-- Loaded by perf_suite.py's load() (from a file, JIT on); the wrapper runs later, in the game's frames. In singleplayer the
-- server ticks in the game's main thread: its time is inside the client's frame time.
PBA_PERF_SV = PBA_PERF_SV or {}
local P = PBA_PERF_SV

local function wrapHook()
	local t = hook.GetTable().EntityEmitSound
	local fn = t and t.pba
	if not fn or fn == P.wrapped then return P.wrapped ~= nil end
	P.inner = fn
	P.wrapped = function(data)
		local t0 = SysTime()
		local a, b = P.inner(data)
		if P.on then
			local ms = (SysTime() - t0) * 1000
			P.n, P.ms, P.max = P.n + 1, P.ms + ms, math.max(P.max, ms)
		end
		return a, b
	end
	hook.Add("EntityEmitSound", "pba", P.wrapped)
	return true
end

function P.Arm(secs)
	wrapHook()
	P.n, P.ms, P.max, P.ticks, P.tickMax, P.tickSum = 0, 0, 0, 0, 0, 0
	P.last = SysTime()
	P.untilT = SysTime() + secs
	P.on = true
	P.relayed0 = pba.stats and pba.stats.relayed or 0
end

hook.Add("Tick", "pba_perf_tick", function()
	if not P.on then return end
	local t = SysTime()
	local dt = (t - P.last) * 1000
	P.last = t
	P.ticks = P.ticks + 1
	P.tickSum = P.tickSum + dt
	if dt > P.tickMax then P.tickMax = dt end
	if t > P.untilT then P.on = false end
end)

function P.Result()
	return { sounds = P.n, hook_ms = math.Round(P.ms, 3), hook_max = math.Round(P.max, 3),
		us_per_sound = P.n > 0 and math.Round(P.ms / P.n * 1000, 1) or 0,
		ticks = P.ticks, tick_max = math.Round(P.tickMax, 2),
		relayed = (pba.stats and pba.stats.relayed or 0) - (P.relayed0 or 0), wrapped = P.wrapped ~= nil }
end

return wrapHook()
