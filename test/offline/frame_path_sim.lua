-- Offline check (run_pure.py extra): the per-frame path of the module's voices makes no Vector of its own
-- (cl_native.lua N.Doppler, N.Directivity: work vectors) and reads the listener's velocity once per frame
-- (N.FrameListenerVelocity). Found by the scouts (2026-11-19): 0.3-0.6 MB/s of garbage in a fight at 144-240 fps
-- from this path, and every Vector (userdata) lengthens the collector's atomic phase.
-- Pass: (1) N.Doppler and N.Directivity make no Vector (main: 1 and 2 per call) and (2) give the former formulas'
-- numbers; (3) N.FrameListenerVelocity gives the value the listener hook read in this frame, a live read otherwise.
local A, N = pba, pba.Native
local made = 0
local Vec = Vector
Vector = function(...) made = made + 1 return Vec(...) end
local res, ok = {}, true
local function chk(k, v) res[#res + 1] = (v and "PASS " or "FAIL ") .. k if not v then ok = false end end
local saved = { dop = A.cfg.native_doppler, dir = A.cfg.native_dir }
A.cfg.native_doppler, A.cfg.native_dir = 1, 0.4
local SPEED = 343 / 0.01905
-- (1)(2) Doppler
local S, L, vS, vL = Vec(100, 20, 3), Vec(-400, 70, 60), Vec(300, -10, 0), Vec(-50, 5, 0)
made = 0
local k = N.Doppler(S, vS, L, vL)
local nDop = made
local u = L - S
local d = u:Length()
u:Mul(1 / d)
local ref = math.Clamp((SPEED - vL:Dot(u)) / math.max(SPEED - vS:Dot(u), 1), 0.5, 2)
chk("doppler_same", k == ref)
-- Directivity: a shooter (an NPC) aiming along +x, the listener off to the side
local owner = { IsValid = function() return true end, IsPlayer = function() return false end, IsNPC = function() return true end,
	EyePos = function() return Vec(0, 0, 64) end, GetForward = function() return Vec(1, 0, 0) end, IsWeapon = function() return false end }
LocalPlayer = LocalPlayer or function() return nil end
-- (the mock's EyePos / GetForward stand for the engine's and are made through Vec: not counted)
made = 0
local g = N.Directivity(owner, L, CHAN_WEAPON, nil)
local nDir = made
local dd = (L - owner.EyePos()):GetNormalized()
local gref = math.max((1 - 0.4) + 0.4 * Vec(1, 0, 0):Dot(dd), 0.05)
chk("directivity_same", g == gref)
res[#res + 1] = string.format("Vectors made per call: Doppler %d, Directivity %d (besides the engine's own returns)", nDop, nDir)
chk("doppler_no_vector", nDop == 0)
chk("directivity_no_vector", nDir == 0)
-- (3) the listener's velocity once per frame
local frame = 7
FrameNumber = function() return frame end
local live = Vec(1, 2, 3)
local lv = N.ListenerVelocity
N.ListenerVelocity = function() return live end
if N.FrameListenerVelocity then
	N.vlFrame, N.vlFrameVal = 7, Vec(9, 9, 9)
	chk("frame_value_in_its_frame", N.FrameListenerVelocity().x == 9)
	frame = 8
	chk("live_read_in_another_frame", N.FrameListenerVelocity() == live)
else
	chk("frame_listener_velocity_exists", false)
end
N.ListenerVelocity = lv
Vector = Vec
A.cfg.native_doppler, A.cfg.native_dir = saved.dop, saved.dir
res[#res + 1] = (ok and "PASS" or "FAIL") .. " frame_path_sim"
print(table.concat(res, "\n"))
