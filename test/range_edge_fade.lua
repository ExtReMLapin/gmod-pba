-- Client half of range_edge_fade.py: records the module's output (pba_native.CaptureStart) for job.args.dur seconds
-- and the times of the Play / StopVoice of the voices of sound job.args.name, relative to the capture's start, with
-- the feed of their source reverb slot (pba_native.SourceReflect's srcSend).
-- The wrapped functions are restored even when the job fails.
local nat = pba_native
local DUR, NAME, CAP = job.args.dur or 10, job.args.name, job.args.cap or "range_edge_fade"
local oPlay, oStop, oRefl = nat.Play, nat.StopVoice, nat.SourceReflect
local ids, rows, t0 = {}, {}, nil
nat.Play = function(n, ...)
	local r = { oPlay(n, ...) }
	if t0 and n == NAME and (r[1] or 0) > 0 then
		ids[r[1]] = true
		rows[#rows + 1] = { t = SysTime() - t0, f = "play", id = r[1] }
	end
	return unpack(r)
end
nat.SourceReflect = function(id, pos, send, ...)
	if t0 and ids[id] then rows[#rows + 1] = { t = SysTime() - t0, f = "slot", id = id, send = send } end
	return oRefl(id, pos, send, ...)
end
nat.StopVoice = function(id, ...)
	if t0 and ids[id] then rows[#rows + 1] = { t = SysTime() - t0, f = "stop", id = id } end
	return oStop(id, ...)
end
local ok, err = pcall(function()
	nat.CaptureStart(DUR + 1)
	t0 = SysTime()
	job:sleep(DUR)
	t0 = nil
end)
nat.Play, nat.StopVoice, nat.SourceReflect = oPlay, oStop, oRefl
local path = nat.CaptureStop(CAP)
if not ok then error(err) end
return util.TableToJSON({ path = path, rows = rows })
