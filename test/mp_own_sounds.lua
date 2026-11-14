-- Own server sounds in multiplayer (server lua_job, pba_tworooms, listen server, the host rendering every
-- sound natively: pba_native_all). Audit A-P2-2: sounds the server plays on a player outside his own
-- command (pain, fall damage, the suit's HEV lines) are his own; the engine plays them on him, attached,
-- never placed in the room. pba's "own" rule existed in singleplayer only: in multiplayer they were
-- relayed to him and rendered as a foreign source at his position (room reverb, a HEV line left behind).
-- Pass: with pba_native_own 0 none of the player's own sounds is relayed to him, while the same sounds
-- from a bot standing at the same spot are (the relay is live), with the host wanting every sound
-- natively; with pba_native_own 1 his own are relayed too (his module plays them, centered on him).
local A = pba
local ply = player.GetHumans()[1]
if not IsValid(ply) or game.GetMap() ~= "pba_tworooms" then return "needs pba_tworooms with a human" end
if game.SinglePlayer() then return "needs a listen server (maxplayers > 1)" end
if ply:GetInfoNum("pba_native_all_want", 0) < 1 then return "needs pba_native_all on the host" end
ply:SetPos(Vector(256, 256, 0))
local bot = player.GetBots()[1] or player.CreateNextBot("apown")
job:sleep(0.5)
bot:SetPos(Vector(256, 320, 0))
job:sleep(0.3)
local SOUNDS = { "HL2Player.BurnPain", "Player.FallDamage", "Player.Death", "!HEV_DMG4" }
local function relays(ent, name)
	local r0 = A.stats.relayed
	ent:EmitSound(name)
	return A.stats.relayed - r0
end
-- pba_native_own (client option, its userinfo pba_native_own_want): 0 = the engine plays his own sounds
-- (none relayed, the audit's rule); 1 = his module plays them like every other sound (relayed)
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
	other[s] = relays(bot, s)
	otherN = otherN + other[s]
	job:sleep(0.2)
end
setOwn(1)
local ownNative = 0
for _, s in ipairs(SOUNDS) do
	ownNative = ownNative + relays(ply, s)
	job:sleep(0.2)
end
ply:ConCommand("pba_native_own " .. savedOwn)
bot:Kick("test done")
return { pass = ownN == 0 and otherN >= #SOUNDS - 1 and ownNative >= #SOUNDS - 1, own = own, other = other, ownNative = ownNative }
