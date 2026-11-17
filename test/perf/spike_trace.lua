-- Frame spike attribution (client lua_job): records the real frame time of every frame for args.seconds (default 20)
-- and wraps a list of functions (args.wrap, "pba.Native.SyncDoors" style paths, plus pba_native.* calls) to log their
-- calls over args.logMs (default 3 ms) with the frame they ran in. Returns the frame-time stats and, for the
-- frames over args.spikeMs (default 40), the calls logged in that frame (same or previous: a call and the frame
-- that pays for it are one apart for timers).
local wrap = (args and args.wrap) or { "pba.Native.SyncDoors", "pba.Native.ApplySettings", "pba.Slicer.Run", "pba.Native.UpdateFollowers",
	"pba_native.SetListener", "pba_native.DynamicCommit", "pba_native.RoomReverb", "pba_native.Stats", "pba_native.SetLimits" }
local seconds, logMs, spikeMs = (args and args.seconds) or 20, (args and args.logMs) or 3, (args and args.spikeMs) or 40
local function resolve(path)
	local t = _G
	local parts = string.Explode(".", path)
	for i = 1, #parts - 1 do t = t and t[parts[i]] end
	return t, parts[#parts]
end
local log, orig = {}, {}
for _, path in ipairs(wrap) do
	local t, k = resolve(path)
	if t and type(t[k]) == "function" then
		local f = t[k]
		orig[#orig + 1] = { t, k, f }
		t[k] = function(...)
			local t0 = SysTime()
			local a, b, c, d = f(...)
			local ms = (SysTime() - t0) * 1000
			if ms >= logMs then log[#log + 1] = { fr = FrameNumber(), ms = ms, what = path } end
			return a, b, c, d
		end
	end
end
local frames, last, t0 = {}, SysTime(), SysTime()
while SysTime() - t0 < seconds do
	job:yield()
	local now = SysTime()
	frames[#frames + 1] = { fr = FrameNumber(), ms = (now - last) * 1000 }
	last = now
end
for _, o in ipairs(orig) do o[1][o[2]] = o[3] end
local ms = {}
for _, f in ipairs(frames) do ms[#ms + 1] = f.ms end
table.sort(ms)
local n = #ms
local spikes = {}
for _, f in ipairs(frames) do
	if f.ms >= spikeMs then
		local near = {}
		for _, l in ipairs(log) do
			if l.fr >= f.fr - 1 and l.fr <= f.fr then near[#near + 1] = string.format("%s %.1f", l.what, l.ms) end
		end
		spikes[#spikes + 1] = { fr = f.fr, ms = math.Round(f.ms, 1), calls = near }
	end
end
return { frames = n, mean = math.Round(t0 and (SysTime() - t0) * 1000 / n, 1), p50 = ms[math.ceil(n * 0.5)], p95 = ms[math.ceil(n * 0.95)], p99 = ms[math.ceil(n * 0.99)],
	max = ms[n], over = #spikes, spikes = spikes, loggedCalls = #log }
