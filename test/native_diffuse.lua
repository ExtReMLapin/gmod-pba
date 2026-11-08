-- Native module, diffuse share of a voice (Play arg 11, Update arg 8; extra reverb send from
-- SetReflections arg 5, pba_native_diffuse_send): the direct part gives way to the room reverb (direct
-- energy x (1 - share), binaural direction blurred), the total (direct + reverb) stays about the same.
-- A DLL without the parameter: no drop. lua_job, client realm, native renderer running (pba_demo:
-- mode C, set server side). Measured 2026-11-09 with a send x (1 + 4 share): total +3.5 dB at 0.85.
-- Returns { pass, directDropDb, totalDb, rows }.
local N, NA = pba.Native, pba_native
job:wait(function() return N.ready and N.render end, 15)
if not (N.ready and N.render) then return { pass = nil, note = "native renderer not running" } end
local ok, n = N.EnsureSound("ambient/machines/spin_loop.wav")
job:wait(function() ok, n = N.EnsureSound("ambient/machines/spin_loop.wav") return ok end, 10)
if not ok then return { pass = false, err = "sound not decoded" } end
local L = LocalPlayer():EyePos()
local pos = L + LocalPlayer():GetForward() * 200
local function measure(share)
	local id = NA.Play(n, pos, 0.5, 1, 1, 1, 100, true, 0, nil, share)
	job:sleep(0.5)
	NA.RenderDebug()
	N.energyL, N.energyR = 0, 0
	job:sleep(1.5)
	local l = NA.RenderDebug()
	local total, direct = (N.energyL or 0) + (N.energyR or 0), l.y + l.z
	NA.StopVoice(id)
	job:sleep(0.8) -- the reverb tail of this voice dies before the next one
	return { share = share, total = math.Round(total), direct = math.Round(direct), id = id }
end
local a, b = measure(0), measure(0.85)
local db = function(x, y) return 10 * math.log10(math.max(x, 1e-9) / math.max(y, 1e-9)) end
local drop, tot = db(a.direct, b.direct), db(b.total, a.total)
return { pass = a.id > 0 and b.id > 0 and drop > 6 and math.abs(tot) <= 3, directDropDb = math.Round(drop, 2),
	totalDb = math.Round(tot, 2), rows = { a, b } }
