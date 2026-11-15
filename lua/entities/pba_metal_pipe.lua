-- A metal pipe that clangs when it falls (the meme). Every physical impact plays one of our own synthesized
-- pipe sounds (sound/pba/pipe/, made by tools/meme_pipe/) with EmitSound, so pba carries it like any sound of the
-- world: reverb, walls, distance. The engine's own physics impact and scrape sounds are silenced for this prop.
-- The rules (speed -> tier, volume, cooldown, variant) are pba.Pipe (lua/pba/sh_pipe.lua).
AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Metal pipe"
ENT.Author = "pba"
ENT.Category = "PBA"
ENT.Spawnable = true
ENT.AdminOnly = false
ENT.Model = "models/props_canal/mattpipe.mdl"
ENT.IconOverride = "entities/pba_metal_pipe.png"

-- 95 dB: the loudest level that keeps the room's reverb. Above dsp_db_min (95 by default) the engine, and pba with
-- pba_native_loud_dry, lower a sound's reverb as for gunfire in the open (by dsp_db_mixdrop, -20 dB): at 100 dB the
-- clangs were nearly dry, even in the metal pipe hall.
local SOUND_LEVEL = 95

local function allowed()
	return pba and pba.Pipe and pba.Pipe.Allowed()
end

if CLIENT then
	-- the module decodes the clangs ahead (a file not decoded yet at its first play goes to the engine, without pba)
	function ENT:Initialize()
		local N = pba and pba.Native
		if N and N.PrewarmFiles then N.PrewarmFiles(pba.Pipe.Files()) end
	end
end

if SERVER then
	-- servers that do not ship the addon through the Workshop send the sound files to the players
	if pba and pba.Pipe then
		for tier, n in pairs(pba.Pipe.VARIANTS) do
			for i = 1, n do resource.AddFile("sound/pba/pipe/" .. tier .. "_" .. i .. ".wav") end
		end
	end

	-- The engine's impact / scrape / roll sounds of this prop never play: only ours (a name under pba/pipe/).
	-- (The physics material "gmod_silent" already has none; this catches whatever else the entity may emit.)
	hook.Add("EntityEmitSound", "pba_metal_pipe_silence", function(t)
		local ent = t.Entity
		if IsValid(ent) and ent:GetClass() == "pba_metal_pipe" and not string.StartWith(string.lower(t.SoundName or ""), "pba/pipe/") then
			return false
		end
	end)

	function ENT:SpawnFunction(ply, tr, class)
		if not allowed() then
			if IsValid(ply) then ply:PrintMessage(HUD_PRINTTALK, "The metal pipe is switched off (pba_meme_pipe 0).") end
			return
		end
		if not tr.Hit then return end
		local ent = ents.Create(class)
		ent:SetPos(tr.HitPos + tr.HitNormal * 24)
		ent:SetAngles(Angle(0, ply:EyeAngles().y, 0))
		ent:Spawn()
		ent:Activate()
		return ent
	end

	function ENT:Initialize()
		if not allowed() then self:Remove() return end
		self:SetModel(self.Model)
		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)
		self:SetUseType(SIMPLE_USE)
		local phys = self:GetPhysicsObject()
		if IsValid(phys) then
			phys:SetMaterial("gmod_silent") -- no impact, scrape or roll sounds of its own
			phys:Wake()
		end
		self.pipeGate = {}
		self.pipeLast = nil
		self:NextThink(CurTime() + 1)
	end

	function ENT:PhysicsCollide(data, phys)
		if not allowed() then return end
		local Pi = pba.Pipe
		local rel = data.OurOldVelocity - data.TheirOldVelocity
		local n = data.HitNormal
		local speed = Pi.ImpactSpeed(rel.x, rel.y, rel.z, n.x, n.y, n.z)
		local now = CurTime()
		if not Pi.Gate(self.pipeGate, now, speed) then return end
		local file, idx = Pi.Pick(Pi.Tier(speed), math.random(), self.pipeLast)
		self.pipeLast = idx
		self:EmitSound(file, SOUND_LEVEL, 100, Pi.Volume(speed), CHAN_AUTO)
	end

	-- the option turned off removes the pipes that are already there
	function ENT:Think()
		if not allowed() then self:Remove() return end
		self:NextThink(CurTime() + 1)
		return true
	end
end
