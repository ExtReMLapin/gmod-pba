-- Own server sounds in singleplayer (server lua_job, pba_tworooms, singleplayer, the host rendering every
-- sound natively: pba_native_all). Counterpart of mp_own_sounds (multiplayer, audit A-P2-2): sounds the server
-- plays on the player outside his own command (pain, fall damage, the suit's HEV lines) are his own; the
-- engine plays them on him, attached, never placed in the room (pba_native_own 0: his module leaves them to
-- the engine). Singleplayer and multiplayer share one rule (snd.own, option mp_own): it once keyed on
-- GetPredictionPlayer() in singleplayer, which left every sound outside his command relayed.
-- With mp_own 0 his own sounds are relayed like any sound (the option is live).
-- Pass: with pba_native_own 0 none of the player's own sounds is relayed to him, while the same sounds
-- from an NPC standing at the same spot are (the relay is live); with pba_native_own 1 his own are relayed
-- too (his module plays them, centered on him).
local A = pba
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return "needs pba_tworooms with a human" end
if not game.SinglePlayer() then return "needs singleplayer" end
if ply:GetInfoNum("pba_native_all_want", 0) < 1 then return "needs pba_native_all on the host" end
ply:SetPos(Vector(256, 256, 0))
local npc = ents.Create("npc_citizen")
npc:SetPos(Vector(256, 320, 0))
npc:Spawn()
npc:Activate()
job:sleep(0.5)
local SOUNDS = { "HL2Player.BurnPain", "Player.FallDamage", "Player.Death", "!HEV_DMG4" }
local function relays(ent, name)
	local r0 = A.stats.relayed
	ent:EmitSound(name)
	return A.stats.relayed - r0
end
local function setOwn(v)
	ply:ConCommand("pba_native_own " .. v)
	job:wait(function() return ply:GetInfoNum("pba_native_own_want", -1) == v end, 5)
end
local savedOwn = ply:GetInfoNum("pba_native_own_want", 0) >= 1 and 1 or 0
setOwn(0)
local own, other = {}, {}
local ownN, otherN = 0, 0
for _, s in ipairs(SOUNDS) do
	own[s] = relays(ply, s)
	ownN = ownN + own[s]
	job:sleep(0.2)
	other[s] = relays(npc, s)
	otherN = otherN + other[s]
	job:sleep(0.2)
end
A.SetOverride("mp_own", 0)
local ownOff = 0
for _, s in ipairs(SOUNDS) do
	ownOff = ownOff + relays(ply, s)
	job:sleep(0.2)
end
A.SetOverride("mp_own", nil)
setOwn(1)
local ownNative = 0
for _, s in ipairs(SOUNDS) do
	ownNative = ownNative + relays(ply, s)
	job:sleep(0.2)
end
ply:ConCommand("pba_native_own " .. savedOwn)
npc:Remove()
local fails = {}
if ownN ~= 0 then fails[#fails + 1] = "own sounds relayed with pba_native_own 0" end
if otherN < #SOUNDS - 1 then fails[#fails + 1] = "NPC sounds not relayed (relay not live)" end
if ownOff < #SOUNDS - 1 then fails[#fails + 1] = "own sounds not relayed with mp_own 0 (option dead)" end
if ownNative < #SOUNDS - 1 then fails[#fails + 1] = "own sounds not relayed with pba_native_own 1" end
return { pass = #fails == 0, fails = fails, own = own, other = other, ownNative = ownNative, ownOff = ownOff }
