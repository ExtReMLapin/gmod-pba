-- Perf bench diagnostic counters (client, docs/PLAN_PERF.md §5 action 2; diagnostic passes only, never
-- in a timed pass: computing the cache key again costs one trace per call). Needs pba_allow_debug 1.
-- Wraps P.Compute (pba.Paths): per frame, counts the calls, the path cache hits,
-- the group_time reuses, the full computations, the distinct cache keys against the distinct 32 u
-- source cells (H1b: one emitter per key, 20 barrels in one cell share nothing), and the calls made
-- synchronously (not inside a slicer job's coroutine: the near sounds, H1). Totals and per-frame maxima go to
-- pba.stats.perfDiag and to PBA_PERF.diag() (read by collector.lua's Result).
local A = pba
local dbg = GetConVar("pba_allow_debug") -- server setting: on the client it exists only when replicated
if dbg and not dbg:GetBool() then
	return { ok = false, err = "pba_allow_debug 0" }
end
local P = A.Paths
PBA_PERF = PBA_PERF or {}
local D = { calls = 0, hits = 0, reused = 0, computed = 0, sync = 0, maxCallsFrame = 0, maxSyncFrame = 0,
	maxKeysFrame = 0, maxCellsFrame = 0, frames = 0 }
A.stats.perfDiag = D
local frame, fCalls, fSync, fKeys, fCells, nKeys, nCells = -1, 0, 0, {}, {}, 0, 0

local function roll()
	local fr = FrameNumber()
	if fr == frame then return end
	if frame >= 0 and fCalls > 0 then
		D.frames = D.frames + 1
		D.maxCallsFrame = math.max(D.maxCallsFrame, fCalls)
		D.maxSyncFrame = math.max(D.maxSyncFrame, fSync)
		D.maxKeysFrame = math.max(D.maxKeysFrame, nKeys)
		D.maxCellsFrame = math.max(D.maxCellsFrame, nCells)
	end
	frame, fCalls, fSync, fKeys, fCells, nKeys, nCells = fr, 0, 0, {}, {}, 0, 0
end

PBA_PERF.diagOrig = PBA_PERF.diagOrig or P.Compute
local origCompute = PBA_PERF.diagOrig

P.Compute = function(S, L, sndlvl, cfg, srcEnt)
	roll()
	local c = cfg or A.cfg
	local se = P.SourceObject(S, srcEnt)
	local key = P.CacheKey(P.FreeSource(S), L, sndlvl, se, c)
	local hit = P.cache[key] and RealTime() - P.cache[key].t < c.cache_ttl
	local reused0 = P.timeStats.reused
	D.calls, fCalls = D.calls + 1, fCalls + 1
	if coroutine.running() == nil then D.sync, fSync = D.sync + 1, fSync + 1 end
	if not fKeys[key] then fKeys[key] = true nKeys = nKeys + 1 end
	local cell = math.floor(S.x / 32) .. ":" .. math.floor(S.y / 32) .. ":" .. math.floor(S.z / 32) .. ":" .. sndlvl
	if not fCells[cell] then fCells[cell] = true nCells = nCells + 1 end
	local r = origCompute(S, L, sndlvl, cfg, srcEnt)
	if hit then D.hits = D.hits + 1
	elseif P.timeStats.reused > reused0 then D.reused = D.reused + 1
	else D.computed = D.computed + 1 end
	return r
end
function PBA_PERF.diag()
	roll()
	local t = {}
	for k, v in pairs(D) do t[k] = v end
	return t
end
function PBA_PERF.diagReset()
	for k in pairs(D) do D[k] = 0 end
end
function PBA_PERF.diagOff()
	P.Compute = origCompute
	PBA_PERF.diag = nil
end

return { ok = true }
