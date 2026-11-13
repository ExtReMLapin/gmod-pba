-- Mix groups (client, lua_exec; no module needed): the engine scales every sound it plays by the value of
-- its mix group in the current sound mixer (scripts/soundmixers.txt, snd_soundmixer; audit C-2 / C-3).
-- pba.Mix reads the same file and must put each sound in the same groups as the engine, then give the
-- same value. Ground truth: the engine's own list (developer 1 + snd_showclassname 2 prints
-- "Default_Mix:<name>: <groups>" for each sound it starts), recorded on gm_construct 2026-11-13.
-- Pass: the groups of 13 sounds equal the engine's (order kept), their Default_Mix values, the
-- Citadel_Dialog_Only values, and the duck of a ducked group applied up to the deciding group.
local M = pba.Mix
if not M then return { pass = false, err = "pba.Mix missing (cl_mix not loaded)" } end
local res = { checks = {}, got = {} }
local function chk(k, ok) res.checks[k] = ok and true or false end
-- { name, classname, channel, level, engine's groups }
local CASES = {
	{ "*vo/npc/female01/squad_reinforce_single04.wav", "npc_citizen", CHAN_VOICE, 75, "Citizen_Dialog NPC_Voice NPC Dialog Medium All" },
	{ "weapons/smg1/smg1_fire1.wav", "player", CHAN_WEAPON, 140, "Player_Weapons_Loud Player_Weapons Combat Weapons VeryLoud All" },
	{ "player/footsteps/concrete3.wav", "npc_citizen", CHAN_BODY, 75, "NPC_Body NPC Medium All" },
	{ "weapons/smg1/smg1_fire1.wav", "player", CHAN_WEAPON, 100, "Player_Weapons Loud All" },
	{ "player/footsteps/concrete1.wav", "player", CHAN_BODY, 75, "Player Medium All" },
	{ "physics/metal/metal_box_impact_hard1.wav", "player", CHAN_AUTO, 75, "Player Physics Medium All" },
	{ "ambient/atmosphere/thunder1.wav", nil, CHAN_STATIC, 75, "Ambient_Atmosphere Ambient Medium All" },
	{ "ambient/explosions/explode_1.wav", nil, CHAN_AUTO, 140, "Explosions Ambient Combat VeryLoud All" },
	{ "vo/npc/male01/hi01.wav", nil, CHAN_AUTO, 75, "Citizen_Dialog Dialog Medium All" },
	{ "items/smallmedkit1.wav", nil, CHAN_AUTO, 75, "Items Medium All" },
	{ "weapons/smg1/smg1_fire1.wav", "npc_citizen", CHAN_WEAPON, 140, "NPC_Weapons_Loud NPC_Weapons NPC Combat Weapons VeryLoud All" },
	{ "weapons/pistol/pistol_fire2.wav", "npc_citizen", CHAN_WEAPON, 100, "NPC_Weapons NPC Loud All" },
	{ "weapons/fx/nearmiss/bulletltor03.wav", nil, CHAN_AUTO, 75, "bulletmiss Medium All" },
	{ "ambient/machines/thumper_hit.wav", nil, CHAN_AUTO, 90, "Ambient_Machines Ambient Medium All" },
}
local mix = M.Load and M.Load() -- (re)reads scripts/soundmixers.txt
chk("loaded", mix and mix.rules and #mix.rules > 50 and mix.mixers and mix.mixers.Default_Mix)
local okAll = true
for i, c in ipairs(CASES) do
	local g = M.Groups(c[1], c[2], c[3], c[4])
	local s = table.concat(g.names or {}, " ")
	res.got[i] = s
	if s ~= c[5] then okAll = false res.checks["groups" .. i] = false end
end
chk("groups", okAll)
-- values in Default_Mix (no ducking: nothing playing)
local function val(i, mixer) return M.ValueIn(M.Groups(CASES[i][1], CASES[i][2], CASES[i][3], CASES[i][4]), mixer, true) end
local function near(a, b) return a and math.abs(a - b) < 1e-4 end
chk("v_player_loud", near(val(2, "Default_Mix"), 1.0))
chk("v_npc_smg", near(val(11, "Default_Mix"), 0.79))
chk("v_explosion", near(val(8, "Default_Mix"), 0.90))
chk("v_all", near(val(10, "Default_Mix"), 0.72))
chk("v_dialog", near(val(9, "Default_Mix"), 0.72))
chk("v_citadel_all", near(val(10, "Citadel_Dialog_Only"), 0.01))
chk("v_citadel_dialog", near(val(9, "Citadel_Dialog_Only"), 0.72))
-- ducking: a ducked group (Ambient_Atmosphere, duck to 60 %) before the deciding group (All) scales the
-- value; a group after it does not
local gThunder = M.Groups(CASES[7][1], CASES[7][2], CASES[7][3], CASES[7][4])
local saved = M.duck
M.duck = { Ambient_Atmosphere = 0.6 }
chk("duck_applies", near(M.ValueIn(gThunder, "Default_Mix", false), 0.72 * 0.6))
M.duck = { Items = 0.5 } -- (not a ducked group in the file: ignored)
chk("duck_only_ducked", near(val(10, "Default_Mix"), 0.72) and near(M.ValueIn(M.Groups(CASES[10][1], nil, CHAN_AUTO, 75), "Default_Mix", false), 0.72))
M.duck = saved
res.fails = {}
for k, ok in SortedPairs(res.checks) do if not ok then res.fails[#res.fails + 1] = k end end
res.pass = #res.fails == 0
return res
