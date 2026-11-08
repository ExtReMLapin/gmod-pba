-- LuaJIT state of PBA's loops after real play (run by jit_report.py with lua_exec). GMod disables the
-- JIT event API (jit.attach: "vmevent API disabled"), so the trace aborts cannot be listened to; their
-- outcome is written in the bytecode instead: a loop the JIT compiled becomes JFORL / JITERL / JLOOP,
-- one that aborted again and again is blacklisted as IFORL / IITERL / ILOOP (never retried), and a
-- plain FORL / ITERL / LOOP was never hot or is still being tried. Every function reachable from the
-- pba table and the hooks (with their upvalues and nested functions) is scanned. For the loops not
-- compiled, the bytecodes this LuaJIT (2.1.0-beta3) cannot record are listed: FNEW (closure created),
-- UCLO (closure over a loop variable), ITERN / ISNEXT (pairs / next). Calls into C (every Vector
-- operation, traces, Entity methods) do not show in the bytecode: they end the trace (stitch).
local fb, fi, fk = jit.util.funcbc, jit.util.funcinfo, jit.util.funck
local OP = {}
do
	local i = 0
	for w in ("ISLT ISGE ISLE ISGT ISEQV ISNEV ISEQS ISNES ISEQN ISNEN ISEQP ISNEP ISTC ISFC IST ISF ISTYPE ISNUM MOV NOT UNM LEN ADDVN SUBVN " ..
		"MULVN DIVVN MODVN ADDNV SUBNV MULNV DIVNV MODNV ADDVV SUBVV MULVV DIVVV MODVV POW CAT KSTR KCDATA KSHORT KNUM KPRI KNIL UGET USETV " ..
		"USETS USETN USETP UCLO FNEW TNEW TDUP GGET GSET TGETV TGETS TGETB TGETR TSETV TSETS TSETB TSETM TSETR CALLM CALL CALLMT CALLT ITERC " ..
		"ITERN VARG ISNEXT RETM RET RET0 RET1 FORI JFORI FORL IFORL JFORL ITERL IITERL JITERL LOOP ILOOP JLOOP JMP FUNCF IFUNCF JFUNCF FUNCV " ..
		"IFUNCV JFUNCV FUNCC FUNCCW"):gmatch("%S+") do OP[i], i = w, i + 1 end
end
local LOOPS = { FORL = "plain", ITERL = "plain", LOOP = "plain", IFORL = "blacklisted", IITERL = "blacklisted", ILOOP = "blacklisted",
	JFORL = "compiled", JITERL = "compiled", JLOOP = "compiled" }
local NYI = { FNEW = true, UCLO = true, ITERN = true, ISNEXT = true }

local seen, protos = {}, {}
local function addProto(f)
	if seen[f] then return end
	seen[f] = true
	local info = fi(f)
	if not info or not info.source or not info.source:find("/pba/", 1, true) then return end
	protos[#protos + 1] = f
	for k = 1, info.gcconsts or 0 do
		local c = fk(f, -k)
		if type(c) == "proto" then addProto(c) end
	end
end
local function addFunc(f)
	if seen[f] then return end
	addProto(f)
	for u = 1, 60 do
		local name, v = debug.getupvalue(f, u)
		if not name then break end
		if type(v) == "function" then addFunc(v) end
	end
end
local tseen = {}
local function walk(t, depth)
	if tseen[t] or depth > 4 then return end
	tseen[t] = true
	for _, v in pairs(t) do
		if type(v) == "function" then addFunc(v) elseif type(v) == "table" then walk(v, depth + 1) end
	end
end
walk(pba, 0)
for _, h in pairs(hook.GetTable()) do for _, f in pairs(h) do if type(f) == "function" then addFunc(f) end end end

local rows, count = {}, { plain = 0, blacklisted = 0, compiled = 0 }
for _, f in ipairs(protos) do
	local pc = 0
	while true do
		local ins = fb(f, pc)
		if not ins then break end
		local op = OP[bit.band(ins, 0xff)]
		local st = LOOPS[op]
		if st then
			count[st] = count[st] + 1
			local i = fi(f, pc)
			local body = {}
			if st ~= "compiled" then -- the back jump gives the start of the loop body
				for q = pc + 1 + bit.rshift(ins, 16) - 0x8000, pc - 1 do
					local o = OP[bit.band(fb(f, q) or 0, 0xff)]
					if NYI[o] then body[#body + 1] = o end
				end
			end
			rows[#rows + 1] = { st = st, op = op, at = ((i.source or "?"):match("pba/[%w_/]+%.lua") or "?") .. ":" .. (i.currentline or 0),
				nyi = table.concat(body, " ") }
		end
		pc = pc + 1
	end
end
table.sort(rows, function(a, b) if a.st ~= b.st then return a.st < b.st end return a.at < b.at end)
return { functions = #protos, count = count, rows = rows }
