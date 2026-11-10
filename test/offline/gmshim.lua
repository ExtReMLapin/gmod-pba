-- Minimal Garry's Mod shim to load pba's pure modules outside the game (offline check only).
local V = {}
V.__index = V
function Vector(x, y, z)
	if type(x) == "table" then x, y, z = x.x, x.y, x.z end
	return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, V)
end
local function isv(a) return getmetatable(a) == V end
V.__add = function(a, b) return Vector(a.x + b.x, a.y + b.y, a.z + b.z) end
V.__sub = function(a, b) return Vector(a.x - b.x, a.y - b.y, a.z - b.z) end
V.__mul = function(a, b)
	if type(a) == "number" then return Vector(b.x * a, b.y * a, b.z * a) end
	if type(b) == "number" then return Vector(a.x * b, a.y * b, a.z * b) end
	return Vector(a.x * b.x, a.y * b.y, a.z * b.z)
end
V.__div = function(a, b) return Vector(a.x / b, a.y / b, a.z / b) end
V.__unm = function(a) return Vector(-a.x, -a.y, -a.z) end
V.__eq = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
V.__tostring = function(a) return string.format("%g %g %g", a.x, a.y, a.z) end
function V:Dot(b) return self.x * b.x + self.y * b.y + self.z * b.z end
function V:Cross(b) return Vector(self.y * b.z - self.z * b.y, self.z * b.x - self.x * b.z, self.x * b.y - self.y * b.x) end
function V:LengthSqr() return self:Dot(self) end
function V:Length() return math.sqrt(self:Dot(self)) end
function V:Distance(b) return (self - b):Length() end
function V:DistToSqr(b) return (self - b):LengthSqr() end
function V:Normalize() local l = self:Length() if l > 0 then self.x, self.y, self.z = self.x / l, self.y / l, self.z / l end end
function V:GetNormalized() local v = Vector(self) v:Normalize() return v end
function V:Add(b) self.x, self.y, self.z = self.x + b.x, self.y + b.y, self.z + b.z end
function V:Div(n) self.x, self.y, self.z = self.x / n, self.y / n, self.z / n end
function V:WithinAABox(mn, mx)
	return self.x >= mn.x and self.y >= mn.y and self.z >= mn.z and self.x <= mx.x and self.y <= mx.y and self.z <= mx.z
end

function math.Clamp(v, a, b) return math.min(math.max(v, a), b) end
function math.Round(v, d) local m = 10 ^ (d or 0) return math.floor(v * m + 0.5) / m end
function table.Copy(t, seen)
	if type(t) ~= "table" then return t end
	if isv(t) then return Vector(t) end
	local o = {}
	for k, v in pairs(t) do o[k] = table.Copy(v) end
	return setmetatable(o, getmetatable(t))
end
CLIENT, SERVER = true, false
FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY = 128, 8192, 256
bit = bit or require("bit")
MAT_CONCRETE, MAT_TILE, MAT_WOOD, MAT_METAL, MAT_GLASS, MAT_PLASTIC, MAT_COMPUTER = 67, 84, 87, 77, 89, 76, 80
MAT_DIRT, MAT_SAND, MAT_GRASS, MAT_SNOW, MAT_VENT, MAT_GRATE, MAT_FOLIAGE = 68, 78, 85, 74, 86, 71, 79
MAT_FLESH, MAT_BLOODYFLESH, MAT_ALIENFLESH, MAT_ANTLION, MAT_SLOSH, MAT_EGGSHELL = 70, 66, 72, 65, 83, 1
local cvs = {}
function GetConVar(n) return cvs[n] end
local function mk(n, def) local c = { GetFloat = function() return tonumber(def) end } cvs[n] = c return c end
function CreateConVar(n, def) return mk(n, def) end
function CreateClientConVar(n, def) return mk(n, def) end
cvars = { AddChangeCallback = function() end }
timer = { Create = function() end, Simple = function() end }
util = { GetSurfaceData = function() return nil end, TableToJSON = function(t)
	local function ser(v)
		if type(v) == "table" then
			local ks = {}
			for k in pairs(v) do ks[#ks + 1] = k end
			table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
			local s = {}
			for _, k in ipairs(ks) do s[#s + 1] = tostring(k) .. ":" .. ser(v[k]) end
			return "{" .. table.concat(s, ",") .. "}"
		end
		return tostring(v)
	end
	return ser(t)
end }
-- as GMod: a value is valid only if it has an IsValid method saying so (a plain table is not)
function IsValid(e) if not e then return false end local f = e.IsValid if not f then return false end return f(e) and true or false end
function string.StartWith(s, p) return s:sub(1, #p) == p end
pba = { Doors = { byEnt = {}, entState = {} } }
-- for cl_probes.lua (probe graph): traces see nothing unless a test stubs them
MASK_SOLID_BRUSHONLY, MASK_SOLID, CONTENTS_SOLID = 16395, 33570827, 1
CONTENTS_GRATE, CONTENTS_WATER = 8, 32
hook = { Add = function() end, Remove = function() end }
function V:Unpack() return self.x, self.y, self.z end
function SysTime() return os.clock() end
function RealTime() return os.clock() end
function FrameNumber() return 1 end
util.TraceLine = function(t) local o = t.output or {} o.Hit, o.Fraction, o.StartSolid = false, 1, false return o end
util.TraceHull = util.TraceLine
util.PointContents = function() return 0 end
-- for sh_core.lua (sound eligibility): sound files are absent unless a test stubs them
SND_CHANGE_VOL, SND_CHANGE_PITCH, SND_STOP = 1, 2, 4
CHAN_AUTO, CHAN_WEAPON, CHAN_VOICE, CHAN_ITEM, CHAN_BODY, CHAN_STATIC = 0, 1, 2, 3, 4, 6
function CurTime() return os.clock() end
function string.EndsWith(s, e) return e == "" or s:sub(-#e) == e end
concommand = { Add = function() end }
file = { Open = function() return nil end, Exists = function() return false end }
game = { GetMap = function() return "" end }
function SoundDuration() return 0 end
function ErrorNoHaltWithStack(m) print(m) end
function ErrorNoHalt(m) print(m) end
