-- Offline check (run_pure.py extra): an entity's sound position is worked out once per frame (sh_core.lua
-- A.EntSoundPos / A.SoundPos, pba_sound_pos_memo). Found by the perf scout (2026-11-19): A.SoundPos ran 8 times a
-- frame for 1.3 sounds, a shot's muzzle (two attachment lookups) about 6 times per sound.
-- Pass: (1) 6 placements of an NPC's shot in one frame look the muzzle up once (6 times on main); (2) the next frame
-- looks it up again; (3) the same positions as worked out afresh; (4) pba_sound_pos_memo 0: every call.
local A = pba
local frame = 100
FrameNumber = function() return frame end
local lookups = 0
local muzzle = Vector(10, 20, 30)
local npc, wep = {}, {}
local function ent(t, cls)
	t.IsValid = function() return true end
	t.IsWorld = function() return false end
	t.IsPlayer = function() return false end
	t.IsNPC = function() return cls == "npc" end
	t.IsWeapon = function() return cls == "weapon" end
	t.GetPos = function() return Vector(1, 2, 3) end
	t.GetModel = function() return "models/x.mdl" end
	t.GetModelScale = function() return 1 end
	t.WorldSpaceCenter = function() return Vector(1, 2, 40) end
	t.EyePos = function() return Vector(1, 2, 64) end
	return t
end
ent(npc, "npc")
ent(wep, "weapon")
npc.GetActiveWeapon = function() return wep end
wep.GetOwner = function() return npc end
wep.LookupAttachment = function() lookups = lookups + 1 return 1 end
wep.GetAttachment = function() return { Pos = Vector(muzzle.x + frame, muzzle.y, muzzle.z) } end
npc.LookupAttachment = function() return 0 end
A.NativeOwn = function() return false end
local res, ok = {}, true
local function chk(k, v) res[#res + 1] = (v and "PASS " or "FAIL ") .. k if not v then ok = false end end
local saved = A.cfg.sound_pos_memo
A.cfg.sound_pos_memo = 1
local first
for _ = 1, 6 do
	local p = A.SoundPos({ Entity = npc, Channel = CHAN_WEAPON })
	first = first or p
	chk("same_position_" .. _, p and p.x == muzzle.x + frame and p.y == muzzle.y and p.z == muzzle.z)
end
res[#res + 1] = "muzzle lookups for 6 placements in one frame: " .. lookups
chk("one_lookup_per_frame", lookups == 1)
frame = frame + 1
local p2 = A.SoundPos({ Entity = npc, Channel = CHAN_WEAPON })
chk("next_frame_again", lookups == 2 and p2.x == muzzle.x + frame)
A.cfg.sound_pos_memo = 0
lookups = 0
for _ = 1, 6 do A.SoundPos({ Entity = npc, Channel = CHAN_WEAPON }) end
chk("option_off_every_call", lookups == 6)
A.cfg.sound_pos_memo = saved
res[#res + 1] = (ok and "PASS" or "FAIL") .. " soundpos_memo_sim"
print(table.concat(res, "\n"))
