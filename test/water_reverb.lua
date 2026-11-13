-- Client lua_job on d1_canals_06, native rendering on (audit C-7): with the listener's head under water the
-- engine swaps its room DSP for dsp_water; the module's room reverb and echoes (simulated in the air) must
-- go too, and come back on surfacing. The listener is moved by overriding pba.ListenerPos (what the
-- module's Think reads); the reflection levels the module gets are read by wrapping SetReflections.
-- Pass: under water room and echo levels ~0 (but > 0: the reflection thread keeps simulating), back to the
-- options' levels in the air; with pba_native_water_reverb 0 the levels stay.
local A, N = pba, pba.Native
if game.GetMap() ~= "d1_canals_06" then return { pass = false, err = "run on d1_canals_06" } end
if not (N and N.render) then return { pass = false, err = "native rendering off" } end
local top = util.TraceLine({ start = Vector(384, 4992, 0), endpos = Vector(384, 4992, -900), mask = MASK_WATER })
if not top.Hit then return { pass = false, err = "canal water not found" } end
local deep, air = top.HitPos - Vector(0, 0, 150), top.HitPos + Vector(0, 0, 64)
local res = { checks = {} }
local function chk(k, ok) res.checks[k] = ok and true or false end
local last
local origSR, origLP = pba_native.SetReflections, A.ListenerPos
pba_native.SetReflections = function(room, echo, ...) last = { room = room, echo = echo } return origSR(room, echo, ...) end
local at = air
A.ListenerPos = function() local _, ang = origLP() return at, ang end
local savedOpt = A.cfg.native_water_reverb
local ok, err = pcall(function()
	local function settle() job:sleep(0.5) end
	local R, E = A.cfg.native_reverb, A.cfg.native_echo
	-- under water
	at = deep
	settle()
	res.under = last and table.Copy(last)
	chk("underRoom", last and last.room > 0 and last.room < R * 0.01)
	chk("underEcho", last and (E <= 0 or (last.echo > 0 and last.echo < E * 0.01)))
	-- back in the air
	at = air
	settle()
	res.air = last and table.Copy(last)
	chk("airRoom", last and math.abs(last.room - R) < 1e-4)
	chk("airEcho", last and math.abs(last.echo - E) < 1e-4)
	-- option off: the reverb stays under water
	A.cfg.native_water_reverb = 0
	last = nil
	at = deep
	settle()
	chk("optionOff", last == nil or math.abs(last.room - R) < 1e-4)
	at = air
	A.cfg.native_water_reverb = savedOpt
	settle()
end)
pba_native.SetReflections, A.ListenerPos = origSR, origLP
A.cfg.native_water_reverb = savedOpt
if N.ApplySettings then N.ApplySettings() end
if not ok then return { pass = false, err = tostring(err) } end
res.fails = {}
for k, v in SortedPairs(res.checks) do if not v then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
