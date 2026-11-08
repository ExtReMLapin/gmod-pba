-- minimal GLuaTest-compatible runner: expect(x).to.beTrue / equal
local function expect(v)
	return { to = { beTrue = function() if v ~= true then error("expected true, got " .. tostring(v), 2) end end,
		beNil = function() if v ~= nil then error("expected nil, got " .. tostring(v), 2) end end,
		equal = function(o) if v ~= o then error("expected " .. tostring(o) .. ", got " .. tostring(v), 2) end end } }
end
local src = file.Read("mcpagent_tmp/pba_pure_test.lua", "LUA")
local fn = CompileString(src, "pba_pure_test")
setfenv(fn, setmetatable({ expect = expect }, { __index = _G }))
local suite = fn()
local ok, fails = 0, {}
for _, c in ipairs(suite.cases) do
	local s, e = pcall(c.func)
	if s then ok = ok + 1 else fails[#fails + 1] = c.name .. ": " .. tostring(e) end
end
return { ok = ok, total = #suite.cases, fails = fails }
