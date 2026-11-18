-- Two copies of one emission (the Breencast's two jumbotron speakers playing br_welcome05 in the same tick) must play
-- in sync: the same sample of the file at the same moment. Heard behind a closed door the two copies reach the
-- listener at about the same level; started apart they are a comb filter (equal copies 114-131 ms apart: the
-- output's autocorrelation 0.44-0.48 at that lag, 0.05 for copies in step) and the speech warbles. Measured on
-- main (pba_tworooms, the speakers not networked behind the shut door): the long-line mirrors of a source the
-- client does not know wait three of their 0.25 s evaluation turns, staggered by loops_stagger, and each starts at
-- its own turn from the top of the file: 134 ms apart, the later one not even skipping what the first had played.
-- Client lua_job (server half: loops_copy_sync_sv.lua, fires the emission 1 s after it starts), native rendering.
-- Pass: both copies are module voices (none handed to the engine) and their file start times (the moment of the Play
-- minus its offset into the file) are within 12 ms (one mix block is 10.7 ms).
-- args.control / PBA_COPYSYNC_CONTROL (the battery's variant): pba_loops_start_sync 0 (the old behaviour): the same measure must then be RED (pass = the bug shows).
local A = pba
local N = A.Native
if not (N and N.render and pba_native and pba_native.Play) then return { pass = nil, err = "native rendering off" } end
local NAME = "vo/breencast/br_welcome05.wav"
local control = (job.args and job.args.control) or PBA_COPYSYNC_CONTROL
A.SetOverride("loops_start_sync", control and 0 or nil)
-- the file decoded first: a copy waiting for its decode starts when it ends, which is not what this measures
job:wait(function() return (N.EnsureSound(NAME)) end, 15)
local plays = {}
local orig = pba_native.Play
pba_native.Play = function(n, pos, gain, l, m, h, pitch, loop, delay, sh, diffuse, send, offset, ...)
	local id = orig(n, pos, gain, l, m, h, pitch, loop, delay, sh, diffuse, send, offset, ...)
	if n == NAME and id and id > 0 then plays[#plays + 1] = { t = RealTime(), off = offset or 0, id = id, gain = gain } end
	return id
end
job:wait(function() return #plays >= 2 end, 8)
job:sleep(0.5)
pba_native.Play = orig
A.SetOverride("loops_start_sync", nil)
local patches = 0
for _, m in pairs(A.Loops.mirrors) do if m.name == NAME and (m.patch or m.handBack) then patches = patches + 1 end end
local res = { n = #plays, plays = plays, enginePatches = patches }
if #plays == 2 then
	res.startA, res.startB = plays[1].t - plays[1].off, plays[2].t - plays[2].off
	res.spread_ms = math.floor(math.abs(res.startA - res.startB) * 10000 + 0.5) / 10
	res.callGap_ms = math.floor(math.abs(plays[1].t - plays[2].t) * 10000 + 0.5) / 10
end
local ok = #plays == 2 and patches == 0 and res.spread_ms <= 12
-- the later copy's offset: a copy starting 0.2 s after the first of its emission plays from 0.2 s into the file (the
-- offset path is not reached when both copies start in one frame, as here; a stamped emission, not an unstamped one)
local now = RealTime()
A.Loops.emissions["pba_test|1"] = { t = now - 0.2, off = 0 }
local off = A.Loops.SyncOffset({ once = true, stKey = "pba_test|1", name = NAME, pitch = 100 }, now)
local none = A.Loops.SyncOffset({ once = true, name = NAME, pitch = 100 }, now)
A.Loops.emissions["pba_test|1"] = nil
res.offset = off
ok = ok and off ~= nil and math.abs(off - 0.2) < 0.001 and none == nil
res.pass = control and not ok or (not control and ok)
return res
