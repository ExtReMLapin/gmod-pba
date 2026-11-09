-- Server-side check of the echo relay (server lua_job, listen server, client rendering natively
-- with echoes on): a loud server sound in clear sight of the player must reach the client as an
-- "echo only" message, a quiet one must not.
-- Returns { pass, want, loudBytes, quietBytes }: pass = the client asks for echoes (pba_echo_want 1: the
-- runner sets pba_native_render 1 and pba_native_echo 1), the loud shots were relayed (bytes > 0) and the
-- quiet voice was not (0 bytes).
local ply = player.GetHumans()[1]
if not IsValid(ply) then return { pass = false, err = "no human player" } end
local want = ply:GetInfoNum("pba_echo_want", 0)
if want < 1 then return { pass = false, err = "client does not render echoes (pba_native_render 1, pba_native_echo 1)", want = want } end
local A = pba
local b0 = A.stats.echoBytes or 0
local pos = ply:EyePos() + ply:GetForward() * 120
for _ = 1, 3 do
	EmitSound("weapons/ar2/fire1.wav", pos, 0, CHAN_AUTO, 1, 140, 0, 100)
	job:sleep(0.3)
end
local loud = (A.stats.echoBytes or 0) - b0
b0 = A.stats.echoBytes or 0
for _ = 1, 3 do
	EmitSound("vo/npc/male01/hi01.wav", pos, 0, CHAN_AUTO, 1, 75, 0, 100)
	job:sleep(0.3)
end
local quiet = (A.stats.echoBytes or 0) - b0
return { pass = loud > 0 and quiet == 0, want = want, loudBytes = loud, quietBytes = quiet }
