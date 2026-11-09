-- Count mode: Vector as a counted proxy (constructor, every method and metamethod, x/y/z reads and
-- writes), counted only at depth 0 (calls from pba's code, not from the shim or the scene's stubs).
-- Same arithmetic as gmshim.lua (doubles): the dumps of both modes are comparable.
CNT = { vnew = 0, vcall = 0, vfield = 0 }
DEPTH = 0
if EVAL_MODE ~= "count" then return end
local V = {}
local MT = {}
local function raw(x, y, z) return setmetatable({ x or 0, y or 0, z or 0 }, MT) end
MT.__index = function(t, k)
	if k == "x" or k == "y" or k == "z" then
		if DEPTH == 0 then CNT.vfield = CNT.vfield + 1 end
		return rawget(t, k == "x" and 1 or k == "y" and 2 or 3)
	end
	local m = V[k]
	if not m then return nil end
	return m
end
MT.__newindex = function(t, k, v)
	if k == "x" or k == "y" or k == "z" then
		if DEPTH == 0 then CNT.vfield = CNT.vfield + 1 end
		rawset(t, k == "x" and 1 or k == "y" and 2 or 3, v)
	else
		rawset(t, k, v)
	end
end
local function wrap(f, isNew)
	return function(...)
		if DEPTH == 0 then
			if isNew then CNT.vnew = CNT.vnew + 1 else CNT.vcall = CNT.vcall + 1 end
		end
		DEPTH = DEPTH + 1
		local a, b, c = f(...)
		DEPTH = DEPTH - 1
		return a, b, c
	end
end
local function X(v) return rawget(v, 1) end
local function Y(v) return rawget(v, 2) end
local function Z(v) return rawget(v, 3) end
Vector = wrap(function(x, y, z)
	if type(x) == "table" then x, y, z = X(x), Y(x), Z(x) end
	return raw(x, y, z)
end, true)
-- arithmetic metamethods make a new Vector: counted as one call AND one new Vector
local function arith(f) local g = wrap(f) return function(a, b) if DEPTH == 0 then CNT.vnew = CNT.vnew + 1 end return g(a, b) end end
MT.__add = arith(function(a, b) return raw(X(a) + X(b), Y(a) + Y(b), Z(a) + Z(b)) end)
MT.__sub = arith(function(a, b) return raw(X(a) - X(b), Y(a) - Y(b), Z(a) - Z(b)) end)
MT.__mul = arith(function(a, b)
	if type(a) == "number" then return raw(X(b) * a, Y(b) * a, Z(b) * a) end
	if type(b) == "number" then return raw(X(a) * b, Y(a) * b, Z(a) * b) end
	return raw(X(a) * X(b), Y(a) * Y(b), Z(a) * Z(b))
end)
MT.__div = arith(function(a, b) return raw(X(a) / b, Y(a) / b, Z(a) / b) end)
MT.__unm = arith(function(a) return raw(-X(a), -Y(a), -Z(a)) end)
MT.__eq = wrap(function(a, b) return X(a) == X(b) and Y(a) == Y(b) and Z(a) == Z(b) end)
MT.__tostring = function(a) return string.format("%g %g %g", X(a), Y(a), Z(a)) end
local function dot(a, b) return X(a) * X(b) + Y(a) * Y(b) + Z(a) * Z(b) end
local function len(a) return math.sqrt(dot(a, a)) end
local function sub(a, b) return raw(X(a) - X(b), Y(a) - Y(b), Z(a) - Z(b)) end
V.Dot = wrap(dot)
V.Cross = arith(function(a, b) return raw(Y(a) * Z(b) - Z(a) * Y(b), Z(a) * X(b) - X(a) * Z(b), X(a) * Y(b) - Y(a) * X(b)) end)
V.LengthSqr = wrap(function(a) return dot(a, a) end)
V.Length = wrap(len)
V.Distance = wrap(function(a, b) return len(sub(a, b)) end)
V.DistToSqr = wrap(function(a, b) local d = sub(a, b) return dot(d, d) end)
local function normalize(a) local l = len(a) if l > 0 then rawset(a, 1, X(a) / l) rawset(a, 2, Y(a) / l) rawset(a, 3, Z(a) / l) end end
V.Normalize = wrap(normalize)
V.GetNormalized = arith(function(a) local v = raw(X(a), Y(a), Z(a)) normalize(v) return v end)
V.Add = wrap(function(a, b) rawset(a, 1, X(a) + X(b)) rawset(a, 2, Y(a) + Y(b)) rawset(a, 3, Z(a) + Z(b)) end)
V.Div = wrap(function(a, n) rawset(a, 1, X(a) / n) rawset(a, 2, Y(a) / n) rawset(a, 3, Z(a) / n) end)
V.WithinAABox = wrap(function(s, mn, mx)
	return X(s) >= X(mn) and Y(s) >= Y(mn) and Z(s) >= Z(mn) and X(s) <= X(mx) and Y(s) <= Y(mx) and Z(s) <= Z(mx)
end)
V.Unpack = wrap(function(a) return X(a), Y(a), Z(a) end)
-- table.Copy of a Vector
local copy = table.Copy
function table.Copy(t, seen)
	if type(t) == "table" and getmetatable(t) == MT then return raw(X(t), Y(t), Z(t)) end
	return copy(t, seen)
end
