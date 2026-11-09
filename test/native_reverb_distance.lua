-- Native module, room reverb send independent from the direct gain (Play arg 12, Update arg 9,
-- PlayStream arg 8). A room's reverberant field is the same everywhere while the direct sound falls as
-- 1/r, so the farther a source the more the reverb dominates; the game's distance laws are much gentler
-- than 1/r, and with the send following the direct gain every source kept the reverb/direct balance of
-- a source ~1 m away (pba_native_reverb 0.15: right near, dry far). Lua now sends gain x distance / 1 m
-- (pba.Native.SendK, pure test); this test checks the module honours the send, one voice at a fixed gain:
--  * send 0: no reverb at all, direct unchanged (a DLL without the parameter keeps its reverb: pass false);
--  * send 4 vs 1: much more reverb (> 6 dB; the energy "total - direct" holds a direct x early-reflection
--    cross term that does not scale with the send, so the ratio is not exactly 16: measured 9.7 dB);
--  * no send = send equal to the gain (old behaviour, within 1.5 dB).
-- The listener must stay still (the reverb is simulated at the listener: walking changes it), and other
-- natively rendered sounds count in the energies (radio streams are paused here).
-- lua_job, client realm, any map, native renderer running.
-- Returns { pass, zeroShare, upDb, noSendDb, directDb, rows }.
local N, NA = pba.Native, pba_native
job:wait(function() return N.ready and N.render end, 15)
if not (N.ready and N.render) then return { pass = nil, note = "native renderer not running" } end
local ok, n = N.EnsureSound("ambient/machines/spin_loop.wav")
job:wait(function() ok, n = N.EnsureSound("ambient/machines/spin_loop.wav") return ok end, 10)
if not ok then return { pass = false, err = "sound not decoded" } end
local paused = {}
for ch in pairs(pba.Streams and pba.Streams.chans or {}) do
	if IsValid(ch) and ch:GetState() == GMOD_CHANNEL_PLAYING then ch:Pause() paused[#paused + 1] = ch end
end
job:sleep(2) -- their reverb tails die
local ply = LocalPlayer()
local pos = ply:EyePos() + ply:GetForward() * 60
local function measure(gain, send)
	local id = NA.Play(n, pos, gain, 1, 1, 1, 100, true, 0, nil, nil, send)
	job:sleep(1.5) -- the reverb builds up
	NA.RenderDebug()
	N.energyL, N.energyR = 0, 0
	job:sleep(2)
	local l = NA.RenderDebug()
	local total, direct = (N.energyL or 0) + (N.energyR or 0), l.y + l.z
	NA.StopVoice(id)
	job:sleep(2) -- the tail dies before the next one
	return { gain = gain, send = send or "gain", direct = direct, rev = math.max(total - direct, 1e-9), id = id }
end
local rows = { measure(1, 1), measure(1, 0), measure(1, 4), measure(1, nil) }
for _, ch in ipairs(paused) do if IsValid(ch) then ch:Play() end end
for _, r in ipairs(rows) do if r.id <= 0 then return { pass = false, err = "Play failed" } end end
local db = function(x, y) return 10 * math.log10(x / y) end
local zeroShare = rows[2].rev / rows[1].rev          -- send 0: ~0
local up = db(rows[3].rev, rows[1].rev)              -- send 4 vs 1: > 6 dB
local noSend = db(rows[4].rev, rows[1].rev)          -- no send = send at the gain (1): ~0
local directDb = db(rows[1].direct, rows[2].direct)  -- same gain: ~0
for _, r in ipairs(rows) do r.direct, r.rev = math.Round(r.direct), math.Round(r.rev) end
local res = { zeroShare = math.Round(zeroShare, 3), upDb = math.Round(up, 1), noSendDb = math.Round(noSend, 1),
	directDb = math.Round(directDb, 1), rows = rows }
if zeroShare > 0.5 then
	res.pass, res.note = false, "module without the send parameter (the reverb ignores it)"
else
	res.pass = zeroShare < 0.05 and up > 6 and math.abs(noSend) <= 1.5 and math.abs(directDb) <= 1.5
end
return res
