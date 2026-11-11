-- GLuaTest suite for the native module update check (lua/pba/cl_update.lua). No network: HTTP, cookie,
-- util.JSONToTable, notification, MsgC and the module's state (pba.Native fields, pba_native) are stubbed for
-- each case and restored after it, even on error. Offline, test/offline/run_pure.py loads cl_native.lua and
-- cl_update.lua on the GMod shim before this suite; in game, pba_init loads them.
local A = pba
local U = A.Update

local G = _G
local NOW = 2000000000
local RELEASE = '{"tag_name":"v1.2.0","html_url":"https://github.com/ExtReMLapin/gmod-pba/releases/tag/v1.2.0"}'

-- runs fn(env) with stubs; env.requests (HTTP calls), env.printed (MsgC texts), env.notices (screen notices),
-- env.cookies (the cookie store). opt.module: nil (none), {ver = "1.1.0"} (loaded), {outdated = true, ver = x}
-- (refused); opt.answer = {code, body} answers each request at once, opt.fail = reason makes it fail;
-- opt.cookies: initial store
local function withEnv(opt, fn)
	local N = A.Native or {}
	A.Native = N
	local saved = { HTTP = G.HTTP, cookie = G.cookie, notification = G.notification, MsgC = G.MsgC, Color = G.Color,
		pba_native = G.pba_native, J = util.JSONToTable, mv = N.moduleVersion, od = N.outdated, cfg = A.cfg.update_check,
		dbg = A.cfg.debug, req = U.requested, nt = U.notified, tx = U.text, url = U.url, inc = U.incompatible }
	local env = { requests = {}, printed = {}, notices = {}, cookies = opt.cookies or {} }
	G.HTTP = function(r)
		env.requests[#env.requests + 1] = r
		if opt.fail then r.failed(opt.fail) elseif opt.answer then r.success(opt.answer[1], opt.answer[2], {}) end
		return true
	end
	G.cookie = {
		GetString = function(k, d) local v = env.cookies[k] if v == nil then return d end return v end,
		Set = function(k, v) env.cookies[k] = tostring(v) end,
	}
	G.notification = { AddLegacy = function(t) env.notices[#env.notices + 1] = t end }
	G.MsgC = function(_, t) env.printed[#env.printed + 1] = t end
	G.Color = function(r, g, b) return { r = r, g = g, b = b } end
	G.pba_native = nil
	-- a JSON decoder for the shapes used here (offline there is no util.JSONToTable)
	util.JSONToTable = function(s)
		if s:sub(1, 1) ~= "{" then return nil end
		local t = {}
		for k, v in s:gmatch('"([%w_]+)"%s*:%s*"([^"]*)"') do t[k] = v end
		return t
	end
	local m = opt.module
	N.moduleVersion, N.outdated = m and m.ver or nil, m and m.outdated or nil
	A.cfg.update_check, A.cfg.debug = opt.off and 0 or 1, 0
	U.requested, U.notified, U.text, U.url, U.incompatible = nil, nil, nil, nil, nil
	local ok, err = pcall(fn, env)
	G.HTTP, G.cookie, G.notification, G.MsgC, G.Color, G.pba_native = saved.HTTP, saved.cookie, saved.notification,
		saved.MsgC, saved.Color, saved.pba_native
	util.JSONToTable, N.moduleVersion, N.outdated = saved.J, saved.mv, saved.od
	A.cfg.update_check, A.cfg.debug = saved.cfg, saved.dbg
	U.requested, U.notified, U.text, U.url, U.incompatible = saved.req, saved.nt, saved.tx, saved.url, saved.inc
	if not ok then error(err, 0) end
end

local function silent(env)
	expect(#env.printed).to.equal(0)
	expect(#env.notices).to.equal(0)
	expect(U.text).to.beNil()
end

return {
	groupName = "pba pure functions (module update check)",
	cases = {
		{ name = "versions: v prefix, numbers one by one, a suffix is older than the plain version", func = function()
			expect(U.Compare("v1.1.0", "1.1.0")).to.equal(0)
			expect(U.Compare("v1.2.0", "1.1.0")).to.equal(1)
			expect(U.Compare("1.1.0", "v1.2.0")).to.equal(-1)
			expect(U.Compare("1.10.0", "1.9.9")).to.equal(1)
			expect(U.Compare("2.0.0", "1.99.99")).to.equal(1)
			expect(U.Compare("1.1.1", "1.1.0")).to.equal(1)
			expect(U.Compare("v1.1.0", "1.1.0-dev")).to.equal(1)
			expect(U.Compare("1.1.0-rc1", "1.1.0")).to.equal(-1)
			expect(U.Compare("1.1.0-dev", "1.1.0-rc1")).to.equal(0)
			expect(U.Compare("1.2.0-dev", "1.1.0")).to.equal(1)
			expect(U.Compare("1.2", "1.2.0")).to.equal(0)
			expect(U.Compare("latest", "1.1.0")).to.beNil()
			expect(U.Compare("1.1.0.4", "1.1.0")).to.beNil()
			expect(U.Compare(nil, "1.1.0")).to.beNil()
		end },
		{ name = "no module installed: no request, nothing said", func = function()
			withEnv({ answer = { 200, RELEASE } }, function(env)
				expect(U.Check(NOW)).to.equal("no module")
				expect(#env.requests).to.equal(0)
				silent(env)
			end)
		end },
		{ name = "switched off (pba_update_check 0): no request", func = function()
			withEnv({ off = true, module = { ver = "1.1.0" }, answer = { 200, RELEASE } }, function(env)
				expect(U.Check(NOW)).to.equal("off")
				expect(#env.requests).to.equal(0)
			end)
		end },
		{ name = "module up to date: one request to api.github.com, nothing said", func = function()
			withEnv({ module = { ver = "1.2.0" }, answer = { 200, RELEASE } }, function(env)
				expect(U.Check(NOW)).to.equal("sent")
				expect(#env.requests).to.equal(1)
				local r = env.requests[1]
				expect(r.url).to.equal("https://api.github.com/repos/ExtReMLapin/gmod-pba/releases/latest")
				expect(r.headers["User-Agent"]).to.equal("pba-update-check")
				expect(r.timeout <= 15).to.beTrue()
				silent(env)
				expect(env.cookies.pba_update_tag).to.equal("v1.2.0")
			end)
		end },
		{ name = "older module: console line, menu text with the link, one screen notice", func = function()
			withEnv({ module = { ver = "1.1.0" }, answer = { 200, RELEASE } }, function(env)
				U.Check(NOW)
				expect(#env.printed).to.equal(1)
				expect(#env.notices).to.equal(1)
				expect(U.text:find("1.1.0 installed, v1.2.0 available", 1, true) ~= nil).to.beTrue()
				expect(U.text:find("https://github.com/ExtReMLapin/gmod-pba/releases/tag/v1.2.0", 1, true) ~= nil).to.beTrue()
				expect(U.text:find("phonon.dll", 1, true) ~= nil).to.beTrue()
				-- a second check in the session (cached): console again, no second notice, no request
				U.Check(NOW + 60)
				expect(#env.requests).to.equal(1)
				expect(#env.notices).to.equal(1)
			end)
		end },
		{ name = "a -dev module of the release's number is older than the release", func = function()
			withEnv({ module = { ver = "1.2.0-dev" }, answer = { 200, RELEASE } }, function(env)
				U.Check(NOW)
				expect(#env.notices).to.equal(1)
			end)
		end },
		{ name = "module refused (no ModuleVersion, or out of the API range): said louder", func = function()
			withEnv({ module = { outdated = true }, answer = { 200, RELEASE } }, function(env)
				U.Check(NOW)
				expect(#env.requests).to.equal(1)
				expect(U.incompatible).to.beTrue()
				expect(U.text:find("NOT COMPATIBLE", 1, true) ~= nil).to.beTrue()
				expect(#env.notices).to.equal(1)
			end)
		end },
		{ name = "errors are silent: network, rate limit (403), broken JSON, not a version", func = function()
			for _, o in ipairs({ { fail = "timeout" }, { answer = { 403, '{"message":"API rate limit exceeded"}' } },
				{ answer = { 200, "<html>" } }, { answer = { 200, '{"tag_name":"nightly"}' } } }) do
				o.module = { ver = "1.0.0" }
				withEnv(o, function(env)
					expect(U.Check(NOW)).to.equal("sent")
					silent(env)
					expect(env.cookies.pba_update_tag).to.beNil()
				end)
			end
		end },
		{ name = "cache: no request within 24 h of an answer (1 h after a failure), then one again", func = function()
			local fresh = { pba_update_tag = "v1.2.0", pba_update_url = "https://github.com/ExtReMLapin/gmod-pba/releases/tag/v1.2.0",
				pba_update_time = tostring(NOW - 23 * 3600) }
			withEnv({ module = { ver = "1.1.0" }, answer = { 200, RELEASE }, cookies = fresh }, function(env)
				expect(U.Check(NOW)).to.equal("cached")
				expect(#env.requests).to.equal(0)
				expect(#env.notices).to.equal(1) -- the cached release is still told
			end)
			fresh.pba_update_time = tostring(NOW - 25 * 3600)
			withEnv({ module = { ver = "1.1.0" }, answer = { 200, RELEASE }, cookies = fresh }, function(env)
				expect(U.Check(NOW)).to.equal("sent")
				expect(#env.requests).to.equal(1)
			end)
			withEnv({ module = { ver = "1.1.0" }, fail = "x", cookies = { pba_update_time = tostring(NOW - 1800) } }, function(env)
				expect(U.Check(NOW)).to.equal("cached")
				expect(#env.requests).to.equal(0)
			end)
			withEnv({ module = { ver = "1.1.0" }, fail = "x", cookies = { pba_update_time = tostring(NOW - 7200) } }, function(env)
				expect(U.Check(NOW)).to.equal("sent")
			end)
		end },
		{ name = "one request per session even when the cache cannot be written", func = function()
			withEnv({ module = { ver = "1.1.0" }, fail = "x" }, function(env)
				U.Check(NOW)
				env.cookies.pba_update_time = nil
				expect(U.Check(NOW)).to.equal("requested")
				expect(#env.requests).to.equal(1)
			end)
		end },
		{ name = "screen notice once per release and per day across sessions", func = function()
			local store = {}
			withEnv({ module = { ver = "1.1.0" }, answer = { 200, RELEASE }, cookies = store }, function(env)
				U.Check(NOW)
				expect(#env.notices).to.equal(1)
			end)
			withEnv({ module = { ver = "1.1.0" }, answer = { 200, RELEASE }, cookies = store }, function(env)
				U.Check(NOW + 10)
				expect(#env.notices).to.equal(0)
				expect(#env.printed).to.equal(1)
			end)
		end },
		{ name = "foreign link in the answer: replaced by the project's releases page", func = function()
			withEnv({ module = { ver = "1.1.0" }, answer = { 200, '{"tag_name":"v1.2.0","html_url":"https://evil.example/x"}' } }, function(env)
				U.Check(NOW)
				expect(U.url).to.equal("https://github.com/ExtReMLapin/gmod-pba/releases/latest")
			end)
		end },
	},
}
