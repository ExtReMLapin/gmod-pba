-- "Metal pipe stack (4)": a spawn-menu entry that drops four pba_metal_pipe stacked a little above the spot, with
-- a slight random offset and yaw so they topple and clang one after the other. The stack itself is never an entity.
AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Metal pipe stack (4)"
ENT.Author = "pba"
ENT.Category = "PBA"
ENT.Spawnable = true
ENT.AdminOnly = false
ENT.IconOverride = "entities/pba_metal_pipe_stack.png"

if SERVER then
	-- pipe i of the stack: height step, jitter, yaw (a plain function: the stack is also spawned from tests)
	function ENT.SpawnStack(ply, pos, yaw)
		local made = {}
		if not (pba and pba.Pipe and pba.Pipe.Allowed()) then return made end
		local count = 4
		for i = 1, count do
			local p = ents.Create("pba_metal_pipe")
			if not IsValid(p) then break end
			p:SetPos(pos + Vector(math.Rand(-5, 5), math.Rand(-5, 5), 150 + (i - 1) * 20 + math.Rand(0, 6)))
			p:SetAngles(Angle(90 + math.Rand(-4, 4), yaw + math.Rand(-28, 28), math.Rand(-4, 4)))
			if IsValid(ply) then p:SetCreator(ply) end
			p:Spawn()
			p:Activate()
			made[#made + 1] = p
		end
		return made
	end

	function ENT:SpawnFunction(ply, tr, class)
		if not (pba and pba.Pipe and pba.Pipe.Allowed()) then
			if IsValid(ply) then ply:PrintMessage(HUD_PRINTTALK, "The metal pipe is switched off (pba_meme_pipe 0).") end
			return
		end
		if not tr.Hit then return end
		local made = self.SpawnStack(ply, tr.HitPos + tr.HitNormal * 8, IsValid(ply) and ply:EyeAngles().y or 0)
		if #made == 0 then return end
		if IsValid(ply) then
			undo.Create("Metal pipe stack")
			for _, p in ipairs(made) do
				undo.AddEntity(p)
				ply:AddCleanup("sents", p)
			end
			undo.SetPlayer(ply)
			undo.Finish()
		end
		return -- the stack entity itself is not created
	end
end
