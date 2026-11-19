-- Dev tool (perf/lua-quick): per-item counters and costs on a live scene, client realm. Installed from a timer
-- (never measured inside a lua_job / lua_exec). OPTM.Start(secs) then OPTM.done / OPTM.res.
--   * pba ms/s of the per-frame listener hook (pba_native_listener) and of the mixer's Think (pba_mix), JIT state real
--   * Lua heap growth (KB/s) with the collector stopped for the window (all of the client realm)
--   * the mixer's tracked voices (#M.voice) and ducked count, kaX calls
--   * frame times (p50 / p99 / max)
OPTM = OPTM or {}
local O = OPTM
function O.Start(secs)
	O.done, O.res = false, nil
	timer.Simple(0, function()
		local ht = hook.GetTable().Think
		local wrapped = {}
		local acc = {}
		for _, id in ipairs({ "pba_native_listener", "pba_mix", "pba_sched" }) do
			local f = ht[id]
			if f then
				acc[id] = 0
				wrapped[id] = f
				hook.Add("Think", id, function(...)
					local t0 = SysTime()
					f(...)
					acc[id] = acc[id] + SysTime() - t0
				end)
			end
		end
		local frames, last = {}, SysTime()
		hook.Add("PostRender", "optm_frames", function()
			local t = SysTime()
			frames[#frames + 1] = (t - last) * 1000
			last = t
		end)
		collectgarbage("collect")
		collectgarbage("stop")
		local kb0, t0 = collectgarbage("count"), SysTime()
		timer.Simple(secs, function()
			local wall = SysTime() - t0
			local kb = collectgarbage("count") - kb0
			collectgarbage("restart")
			hook.Remove("PostRender", "optm_frames")
			for id, f in pairs(wrapped) do hook.Add("Think", id, f) end
			table.sort(frames)
			local function pct(p) return frames[math.max(1, math.ceil(#frames * p))] or 0 end
			local M = pba.Mix
			local nv = 0
			if M and M.voice then for _ in pairs(M.voice) do nv = nv + 1 end end
			local r = { wall = wall, heapKBs = kb / wall, fps = #frames / wall, p50 = pct(0.5), p99 = pct(0.99), max = frames[#frames] or 0,
				mixVoices = nv, nDucked = M and M.nDucked, follow = table.Count(pba.Native and pba.Native.follow or {}) }
			for id, s in pairs(acc) do r[id] = s * 1000 / wall end
			O.res, O.done = r, true
		end)
	end)
	return true
end
return true
