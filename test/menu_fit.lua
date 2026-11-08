-- Client lua_job: builds the three audioprop panels at the Q-menu width (args.width, default 300)
-- and lists the check-box labels that overflow (Derma check boxes do not wrap).
local builders = audioprop.MenuBuild
local res = {}
for name, fn in pairs(builders) do
	local cp = vgui.Create("ControlPanel")
	cp:SetWide(job.args.width or 300)
	local ok, err = pcall(fn, cp)
	cp:InvalidateLayout(true)
	cp:SizeToChildren(false, true)
	job:frames(2)
	local over = {}
	local function walk(p)
		for _, c in ipairs(p:GetChildren()) do
			if c.ClassName == "DCheckBoxLabel" and IsValid(c.Label) then
				local tw = c.Label:GetContentSize()
				local x = c.Label:GetPos()
				if x + tw > c:GetWide() then over[#over + 1] = c.Label:GetText() .. " (" .. (x + tw) .. " > " .. c:GetWide() .. ")" end
			end
			walk(c)
		end
	end
	walk(cp)
	res[name] = { ok = ok, err = err and tostring(err), overflow = over }
	cp:Remove()
end
return res
