"""End to end, native rendering, rp_downtown_v4c_v2: a 3D stream (another addon's radio, sound.PlayFile) in
the brick building's upper room, heard in that room then from the street outside.
  * in the room (~252 u from the radio): the reverb heard is the source slot's, with the slot fed by the
    sound's 1 m power (N.SlotSend, the one reverb rule): its reverb over direct = the one measured 1 m from
    the radio in the same run + the rule's shift ((send / law) here over at 1 m: ~0 dB for this flat law)
    + the change of the slot's simulated response (SrcSlotStats energy: -4.5 dB, the early reflections
    spread 1/r while the direct keeps the addon's flat law), within 3 dB; and the send is the rule's at both
    points. The bugs: the send following the direct gain (the empty room sounded dry, +1 dB at the 1.0
    default), a x distance factor on the send (+13.6 dB here, caught: a mutant run fails room and street).
  * just outside the room's doorway, in the corridor, no line of sight: the room's reverb spills out of
    the doorway (source reverb slot, pba_native.SourceReflect): >= +3 dB.
  * in the street (open sky, ~1424 u away through the building): at most the source's 1 m power spread by
    its own law over the straight distance (free field: walls and detours only take away; measured 43 dB
    under it), and the sends never grow with the distance (the bug: the send grew with the distance
    everywhere, x24 there: +28 dB, an ambience with no direction, still under the free-field bound, so the
    send is checked against the rule). What leaks out is reverberant by nature: the ratio is no criterion.
Energies are the module's own mix (RenderDebug, pba.Native.energyL/R): total - direct = reverb.
The signal is a stationary machine loop: music changes its energy from one measurement to the next
(9 dB seen between two measures at the same spot).
Usage: python -I downtown_stream.py <mcp.py>   (loads the map if needed; restores pba_* settings)
"""
import json
import math
import os
import subprocess
import sys
import time

MCP = sys.argv[1]


def call(tool, args, mx=2_000_000):
    out = subprocess.run([sys.executable, "-I", MCP, "call", tool, json.dumps(args), str(mx)],
                         capture_output=True, text=True, encoding="utf-8").stdout
    try:
        return json.loads(out)
    except Exception:
        return {}


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _cvsnap  # restores every pba_* setting at exit, even on failure
_cvsnap.guard(call)


def lua(realm, code):
    v = call("lua_exec", {"realm": realm, "code": code}).get("values")
    return v[0] if v else None


MAP = "rp_downtown_v4c_v2"
RADIO = (-2120.3, -6872.2, -50.0)
ROOM = (-1968.5, -6676.3, -68.0)     # feet; the radio ~290 u away in the same room
STREET = (-838.9, -6258.4, -204.0)  # feet; outside, open sky
DOOR = (-2202.6, -6940.2, -68.0)     # feet; in the corridor just outside the room's doorway, no line of sight

if call("status", {}).get("map") != MAP:
    call("map_load", {"map": MAP}, mx=5_000_000)
    time.sleep(4)
call("console_exec", {"realm": "client", "cmd": "pba_native_render 1"})
for _ in range(60):
    if lua("client", "return pba.Native.ready == true and pba.Native.render == true"):
        break
    time.sleep(2)


def goto(p):
    lua("server", "local p = player.GetHumans()[1] p:SetPos(Vector(%f, %f, %f)) p:SetVelocity(-p:GetVelocity()) return true" % p)



def measure():
    lua("client", "pba_native.RenderDebug() pba.Native.energyL, pba.Native.energyR = 0, 0 pba_native.SrcSlotStats() return true")
    time.sleep(2.5)
    r = lua("client", """local N = pba.Native local l = pba_native.RenderDebug() local ch = PBA_T_CH
local rec = IsValid(ch) and pba.Streams.chans[ch]
local L = LocalPlayer():EyePos() local d = rec and rec.pos:Distance(L) or 0
local mn = IsValid(ch) and ch:Get3DFadeDistance() or 0
local slotE = 0
for _, s in ipairs(pba_native.SrcSlotStats()) do if s.active then slotE = slotE + s.energy / math.max(s.seconds, 1e-6) end end
return { total = (N.energyL or 0) + (N.energyR or 0), direct = l.y + l.z, native = rec and rec.nativeId or false,
  enclosure = N.enclosure, d = d, law = d <= mn and 1 or mn / d, send = rec and rec.nativeId and PBA_T_SEND[rec.nativeId] or false,
  bound = rec and rec.srcBound or false, vol = rec and rec.vol or 1, ng = pba.cfg.native_gain or 1, entryG = rec and rec.entryG or false, gNative = rec and rec.gNative or false, slotE = slotE }""")
    if not r:
        return None
    rev = max(r["total"] - r["direct"], 1e-30)
    r["revOverDirDb"] = round(10 * math.log10(rev / max(r["direct"], 1e-30)), 1)
    return r


def goto_near():
    # feet placed so that the EYE (the listener) is 1 m (52.49 u) from the radio, toward the room point
    lua("server", """local p = player.GetHumans()[1] local R, F = Vector(%f, %f, %f), Vector(%f, %f, %f)
local h = p:GetViewOffset().z local dz = R.z - (F.z + h)
local dir = Vector(F.x - R.x, F.y - R.y, 0):GetNormalized()
local hd = math.sqrt(math.max(52.49 ^ 2 - dz * dz, 0))
p:SetPos(Vector(R.x + dir.x * hd, R.y + dir.y * hd, F.z)) p:SetVelocity(-p:GetVelocity()) return true""" % (RADIO + ROOM))


goto(ROOM)
time.sleep(1)
# other natively rendered streams count in the energies: paused during the test. The slot sends the
# stream passes to the module are recorded (PBA_T_SEND) to check the rule, not inferred.
lua("client", """PBA_T_PAUSED = {}
for ch in pairs(pba.Streams.chans) do if IsValid(ch) and ch:GetState() == GMOD_CHANNEL_PLAYING then ch:Pause() PBA_T_PAUSED[#PBA_T_PAUSED + 1] = ch end end
PBA_T_SEND = {}
if not PBA_T_SR then PBA_T_SR = pba_native.SourceReflect
  pba_native.SourceReflect = function(id, S, send, ...) PBA_T_SEND[id] = send return PBA_T_SR(id, S, send, ...) end end
sound.PlayFile("sound/ambient/machines/spin_loop.wav", "3d noplay noblock", function(ch)
	if not IsValid(ch) then return end
	ch:SetPos(Vector(%f, %f, %f)) ch:Set3DFadeDistance(250, 10000) ch:EnableLooping(true) ch:SetVolume(1) ch:Play()
	PBA_T_CH = ch
end)
return true""" % RADIO)
try:
    time.sleep(5)  # PBA takes the stream over, the room's reverb is simulated
    room = measure()
    goto_near()
    time.sleep(4)
    near = measure()
    goto(DOOR)
    time.sleep(4)
    door = measure()
    goto(STREET)
    time.sleep(4)  # re-evaluation, ramps, the street's reverb
    street = measure()
finally:
    lua("client", "if IsValid(PBA_T_CH) then PBA_T_CH:Stop() end PBA_T_CH = nil "
                  "if PBA_T_SR then pba_native.SourceReflect = PBA_T_SR PBA_T_SR = nil end "
                  "for _, ch in ipairs(PBA_T_PAUSED or {}) do if IsValid(ch) then ch:Play() end end return true")


def db(x):
    return 10 * math.log10(max(x, 1e-30))


def live(m):
    # the system measured was active: a native voice holding a source reverb slot whose output is heard
    return bool(m and m["native"] and m["bound"] and m["send"] and m["slotE"] > 0)


res = {"room": room, "near": near, "door": door, "street": street}


def rule_send(m):
    # N.SlotSend with the channel's law: the source's power at 1 m (law(1 m) = 1 here), never more than
    # law(d) x d / 1 m; times the volume and native_gain (cl_streams.streamSend)
    d = max(m["d"], 52.49)
    return m["vol"] * min(1.0, m["law"] * d / 52.49) * m["ng"]


def send_ok(m):
    return abs(m["send"] - rule_send(m)) <= 1e-3 * max(rule_send(m), 1e-9)


ok_room = ok_street = False
if live(room) and live(near):
    # the room: the reverb heard where the listener stands is the source slot's (simulated FROM the radio in
    # its room), fed with the 1 m power. Reference: the same measure 1 m from the radio in this run. Between
    # the two points two things change, and only two:
    #  * the rule: (send / direct law) here over (send / direct law) at 1 m. This radio's law is flat up to
    #    250 u (Set3DFadeDistance(250, ...)) and the slot keeps its 1 m power: ~0 dB;
    #  * the room's response at the listener, Steam Audio's (the slot output's energy, SrcSlotStats, is that
    #    response x the send). It is not flat: the early reflections (the floor 18 u under the radio, the
    #    near walls) spread like a real sound, 1/r, while the direct keeps the addon's flat law, so the
    #    reverb over direct falls with the distance (-4 to -6 dB from 1 m to 4.8 m measured, with or without
    #    the slot averaging). Physics, not the rule: it is measured, not assumed.
    # Criterion: the heard reverb over direct = the 1 m one + the rule's shift + the slot response's change,
    # within 3 dB (L+R binaural mix against the slot's W channel, other ambient sounds in the mix).
    # And the send itself is the rule's at both points (the bugs: a send following the direct gain, a
    # x distance factor: +13.6 dB here).
    shift = 20 * math.log10((room["send"] / room["law"]) / (near["send"] / near["law"]))
    resp = db(room["slotE"] / room["send"] ** 2) - db(near["slotE"] / near["send"] ** 2)
    res["roomShiftDb"] = round(shift, 2)
    res["roomResponseDb"] = round(resp, 1)
    res["expectRoomDb"] = round(near["revOverDirDb"] + shift + resp, 1)
    ok_room = bool(abs(room["revOverDirDb"] - res["expectRoomDb"]) <= 3 and send_ok(room) and send_ok(near))
if live(near) and street and street["native"]:
    # the street: through a building, the most that can arrive is the source's power at 1 m spread by its
    # own law over the straight distance (free field: no wall, no detour; any wall, opening or longer path
    # only takes away). P1m = the direct heard 1 m away in clear sight; bound = P1m x (law(d) / law(1 m))^2
    # (this radio: 250 u / 1424 u, -15 dB). Measured ~43 dB under it.
    bound = near["direct"] / max(near["law"], 1e-9) ** 2 * street["law"] ** 2
    res["streetVsBoundDb"] = round(db(street["total"]) - db(bound), 1)
    # the bug it was written for (the send grew with the distance: x24 at the street, an ambience with no
    # direction) stays well under that bound (~-15 dB), so the sends are checked against the rule directly:
    # the slot keeps the 1 m power, what enters the listener's space is at most that power
    ok_street = bool(street["total"] <= bound and street["send"] and send_ok(street)
                     and (not street["entryG"] or street["entryG"] <= 1.0 + 1e-6))
# just outside the doorway the room's reverb spills out (source reverb slot): clearly there, not the
# corridor's thin one (listener-centric only: ~-3 dB measured before the slots)
ok_door = bool(door and door["native"] and door["revOverDirDb"] >= 3)
res["pass"] = bool(ok_room and ok_street and ok_door)
res["ok"] = {"room": ok_room, "street": ok_street, "door": ok_door}
print(json.dumps(res))
