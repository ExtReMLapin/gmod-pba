-- minimal GLuaTest-compatible runner: expect(x).to.beTrue / equal
local function expect(v)
	return { to = { beTrue = function() if v ~= true then error("expected true, got " .. tostring(v), 2) end end,
		beNil = function() if v ~= nil then error("expected nil, got " .. tostring(v), 2) end end,
		equal = function(o) if v ~= o then error("expected " .. tostring(o) .. ", got " .. tostring(v), 2) end end } }
end
-- PBA_PURE_SRC: the suite sent inline by run_battery.py (no file written: parallel game instances share lua/)
local src = PBA_PURE_SRC or file.Read("mcpagent_tmp/pba_pure_test.lua", "LUA")
local fn = CompileString(src, "pba_pure_test")
setfenv(fn, setmetatable({ expect = expect, PBA_JOB = job }, { __index = _G }))
local suite = fn()
local ok, fails = 0, {}
for _, c in ipairs(suite.cases) do
	local s, e = pcall(c.func)
	if s then ok = ok + 1 else fails[#fails + 1] = c.name .. ": " .. tostring(e) end
	-- run as a lua_job: the frame back between cases, so the MCP execution budget (5 s) is per case, not for
	-- the whole suite (135 cases came close to it in one lua_exec)
	if job and job.step then job:step() end
end
return { ok = ok, total = #suite.cases, fails = fails }
