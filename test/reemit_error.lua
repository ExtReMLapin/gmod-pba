-- pba's own re-emissions on the client go through A.Emit (client lua_exec, any map). They set A.reemitting, which
-- lets the sound through the EntityEmitSound hook untouched. Before, they set it and reset it by hand: an error
-- in PlayEx or ChangeVolume left it true for good, and every later sound then bypassed PBA.
-- Two of them are reachable from here: a loop mirror's engine patch at its start (PlayEx) and at a gain change
-- (ChangeVolume). Both run here on a fake patch whose call throws.
-- Pass: A.reemitting is false after each call.
local A = pba
local LP = A.Loops
local MIRROR = A.Render and A.Render.Strategy and A.Render.Strategy("mirror")
if not (LP and MIRROR and MIRROR.engine) then return { pass = false, err = "cl_loops mirror not loaded" } end
local function boom() error("test: the engine call failed") end
local fake = { SetSoundLevel = function() end, SetDSP = function() end, PlayEx = boom, ChangeVolume = boom,
	ChangePitch = boom }
local res = { checks = {} }
local saved = LP.origCreateSound
A.reemitting = false

-- start: LP.origCreateSound gives the fake patch, its PlayEx throws
LP.origCreateSound = function() return fake end
local m1 = { name = "ambient/atmosphere/tone_alley.wav", lvl = 75, vol = 1, pitch = 100 }
pcall(MIRROR.engine.start, m1, LocalPlayer(), 1, 0)
LP.origCreateSound = saved
res.checks.start = A.reemitting == false
A.reemitting = false

-- gain change: the patch's ChangeVolume throws
local m2 = { patch = fake, vol = 1, g = 1, curDsp = 0 }
pcall(MIRROR.engine.update, m2, 0.5, 0, 0.1)
res.checks.update = A.reemitting == false
A.reemitting = false

res.pass = res.checks.start and res.checks.update
return res
