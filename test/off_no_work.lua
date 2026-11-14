-- pba_enable 0 does no work (client lua_job, any map; native module loaded or not). The perf bench saw PBA
-- cost up to 25 ms per frame in its "off" mode on d1_canals_01: the module's door / prop sync (every 0.1 s:
-- every entity walked, the scene committed) and its listener (every frame) ran with pba switched off.
-- Counts work done, not time: every pba_native call, the periodic ticks (A.perfTimers) and A.Process over
-- 2 s with pba off (pba_enable 0, the server convar, as the bench sets it: run from the listen host's console;
-- the client follows within pba_cfgpoll's 0.5 s). pass = 0 native calls and 0 ticks and 0 processed.
-- Then switched back on: the native calls resume (the counter is live), when the module is loaded.
local A, NA = pba, pba_native
local QUERY = { Stats = true, Version = true, ApiVersion = true } -- read-only probes others may poll
local counts = {}
local orig = {}
local function wrap()
	if not NA then return end
	for k, f in pairs(NA) do
		if isfunction(f) and not QUERY[k] then
			orig[k] = f
			NA[k] = function(...) counts[k] = (counts[k] or 0) + 1 return f(...) end
		end
	end
end
local function unwrap() for k, f in pairs(orig) do NA[k] = f end end
local function total() local n = 0 for _, c in pairs(counts) do n = n + c end return n end
local function ticks()
	local n = 0
	for _, t in pairs(A.perfTimers or {}) do n = n + t.n end
	return n
end
local prev = GetConVar("pba_enable"):GetString()
local function setEnable(v)
	RunConsoleCommand("pba_enable", v)
	job:wait(function() return (A.cfg.enable or 0) == tonumber(v) end, 3)
end
local res
local ok, err = pcall(function()
	setEnable("0")
	job:sleep(1)
	wrap()
	local t0, p0 = ticks(), A.stats.processed
	job:sleep(2)
	local offCalls = table.Copy(counts)
	local offN, offTicks, offProc = total(), ticks() - t0, A.stats.processed - p0
	setEnable(prev)
	table.Empty(counts)
	job:sleep(1)
	local onN = total()
	unwrap()
	res = { native = NA ~= nil and A.Native and A.Native.ready or false, offCalls = offCalls, offNative = offN,
		offTicks = offTicks, offProcessed = offProc, onNative = onN,
		pass = offN == 0 and offTicks == 0 and offProc == 0 and (not (NA and A.Native and A.Native.ready) or onN > 0) }
end)
unwrap()
if GetConVar("pba_enable"):GetString() ~= prev then RunConsoleCommand("pba_enable", prev) end
if not ok then return { pass = false, err = tostring(err) } end
return res
