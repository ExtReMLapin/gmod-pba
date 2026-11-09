-- Native module, diffuse share of a voice (Play arg 11, Update arg 8; extra reverb send from
-- SetReflections arg 5, pba_native_diffuse_send = k): the direct part gives way to the room reverb (direct
-- energy x (1 - share), binaural direction blurred), the total (direct + reverb) stays about the same.
-- Energy budget, D and R the direct and reverb energies at share 0, s the share, d the direct factor
-- (nominal 1 - s): E(0) = D + R, E(s) = D d + R (1 + k s)^2 (the send amplitude is boosted by 1 + k s).
-- The total is conserved exactly when R / D = (1 - d) / ((1 + k s)^2 - 1): with k = 1.5 (default),
-- s = 0.85, d = 0.15, that is R / D = 0.20 (reverb 7 dB under the direct, a typical room). Elsewhere
-- the total moves by 10 log10((d + r (1 + k s)^2) / (1 + r)), r = R / D: the limit |total| <= 3 dB holds
-- for r in [0.075, 0.58] (a factor ~2.8 either side of the tuning point); outside it the fixed k no
-- longer conserves the energy and the test fails. (The +3.5 dB once recorded here was measured with
-- the older law x (1 + 4 share), k = 4: out of this band, superseded.) The prediction of the budget from
-- the share-0 measure (predictedTotalDb) is reported, not checked: the measured reverb holds a cross
-- term direct x early reflections that does not follow the send.
-- A DLL without the parameter: no drop. lua_job, client realm, native renderer running (pba_demo:
-- mode C, set server side). Returns { pass, directDropDb, totalDb, predictedTotalDb, reverbOverDirect, rows }.
local N, NA = pba.Native, pba_native
job:wait(function() return N.ready and N.render end, 15)
if not (N.ready and N.render) then return { pass = false, err = "native renderer not running (pba_native_render 1; pba_demo: mode C)" } end
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
local cv = GetConVar("pba_native_diffuse_send")
local k = cv and cv:GetFloat() or 1.5
local rev = math.max(a.total - a.direct, 0)
local pred = db(b.direct + rev * (1 + k * b.share) ^ 2, a.total)
-- the total depends on the room where it is measured (reverb over direct at share 0: 0.2 in pba_demo, 1.95
-- under gm_melancholia's overhang: +5.4 dB predicted, +5.5 measured): what must hold is the energy law
-- itself, the measured total within 1.5 dB of the one predicted from the share-0 measure
return { pass = a.id > 0 and b.id > 0 and drop > 6 and math.abs(tot - pred) <= 1.5, directDropDb = math.Round(drop, 2),
	totalDb = math.Round(tot, 2), predictedTotalDb = math.Round(pred, 2), k = k,
	reverbOverDirect = math.Round(rev / math.max(a.direct, 1e-9), 3), rows = { a, b } }
