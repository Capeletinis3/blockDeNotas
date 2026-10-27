--[[
	Dobles de Roblox para ejecutar el servidor y el cliente reales dentro de Lune.
	Implementa lo que usa el proyecto: instancias con jerarquía, propiedades, atributos y eventos;
	tipos de datos (Color3, UDim2, Vector3, CFrame…); servicios (Players, RunService, DataStore,
	TextService, UserInputService…) y remotos que copian los argumentos como la red.
	No dibuja nada: sirve para detectar errores de ejecución y probar flujos, no el diseño visual.
]]

local serde = require("@lune/serde")
local ltask = require("@lune/task")

local M = {}
M.task = ltask
M.log = {}

function M.warn(...)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[i] = tostring((select(i, ...)))
	end
	table.insert(M.log, table.concat(parts, " "))
end

-- typeof que reconoce los tipos simulados -------------------------------------------------
function M.typeof(v: any): string
	local mt = type(v) == "table" and getmetatable(v)
	if mt and mt.__type then
		return mt.__type
	end
	return typeof(v)
end

-- Señales ---------------------------------------------------------------------------------
local Signal = {}
Signal.__index = Signal
Signal.__type = "RBXScriptSignal"
function Signal.new()
	return setmetatable({ handlers = {} }, Signal)
end
function Signal:Connect(fn)
	local c = { fn = fn, connected = true }
	table.insert(self.handlers, c)
	return {
		Connected = true,
		Disconnect = function()
			c.connected = false
		end,
	}
end
function Signal:Once(fn)
	local conn
	conn = self:Connect(function(...)
		conn.Disconnect()
		fn(...)
	end)
	return conn
end
function Signal:Fire(...)
	for _, c in table.clone(self.handlers) do
		if c.connected then
			c.fn(...)
		end
	end
end
function Signal:Wait()
	local done, result = false, nil
	self:Once(function(...)
		done, result = true, table.pack(...)
	end)
	while not done do
		ltask.wait()
	end
	return table.unpack(result, 1, result.n)
end
M.Signal = Signal

-- Tipos de datos ------------------------------------------------------------------------------
local function dt(name: string, fields: any, methods: any?, ops: any?)
	local mt = { __type = name }
	mt.__index = function(t, k)
		if methods and methods[k] then
			return methods[k]
		end
		local f = fields[k]
		if f then
			return f(t)
		end
		return rawget(t, "_" .. k)
	end
	for k, v in ops or {} do
		mt[k] = v
	end
	mt.__tostring = function(t)
		return name
	end
	return mt
end

-- Vector3
local V3mt
local Vector3 = {}
local function v3(x, y, z)
	return setmetatable({ _X = x or 0, _Y = y or 0, _Z = z or 0 }, V3mt)
end
V3mt = dt("Vector3", {
	Magnitude = function(v)
		return math.sqrt(v._X ^ 2 + v._Y ^ 2 + v._Z ^ 2)
	end,
	Unit = function(v)
		local m = math.sqrt(v._X ^ 2 + v._Y ^ 2 + v._Z ^ 2)
		if m == 0 then
			return v3(0, 0, 0)
		end
		return v3(v._X / m, v._Y / m, v._Z / m)
	end,
}, {
	Dot = function(a, b)
		return a._X * b._X + a._Y * b._Y + a._Z * b._Z
	end,
	Cross = function(a, b)
		return v3(a._Y * b._Z - a._Z * b._Y, a._Z * b._X - a._X * b._Z, a._X * b._Y - a._Y * b._X)
	end,
	Lerp = function(a, b, t)
		return v3(a._X + (b._X - a._X) * t, a._Y + (b._Y - a._Y) * t, a._Z + (b._Z - a._Z) * t)
	end,
	Max = function(a, b)
		return v3(math.max(a._X, b._X), math.max(a._Y, b._Y), math.max(a._Z, b._Z))
	end,
	Min = function(a, b)
		return v3(math.min(a._X, b._X), math.min(a._Y, b._Y), math.min(a._Z, b._Z))
	end,
}, {
	__add = function(a, b)
		return v3(a._X + b._X, a._Y + b._Y, a._Z + b._Z)
	end,
	__sub = function(a, b)
		return v3(a._X - b._X, a._Y - b._Y, a._Z - b._Z)
	end,
	__mul = function(a, b)
		if type(a) == "number" then
			return v3(b._X * a, b._Y * a, b._Z * a)
		elseif type(b) == "number" then
			return v3(a._X * b, a._Y * b, a._Z * b)
		end
		return v3(a._X * b._X, a._Y * b._Y, a._Z * b._Z)
	end,
	__div = function(a, b)
		if type(b) == "number" then
			return v3(a._X / b, a._Y / b, a._Z / b)
		end
		return v3(a._X / b._X, a._Y / b._Y, a._Z / b._Z)
	end,
	__unm = function(a)
		return v3(-a._X, -a._Y, -a._Z)
	end,
	__eq = function(a, b)
		return a._X == b._X and a._Y == b._Y and a._Z == b._Z
	end,
})
Vector3.new = v3
Vector3.zero = v3(0, 0, 0)
Vector3.one = v3(1, 1, 1)
Vector3.xAxis = v3(1, 0, 0)
Vector3.yAxis = v3(0, 1, 0)
Vector3.zAxis = v3(0, 0, 1)
M.Vector3 = Vector3

-- Vector2
local V2mt
local Vector2 = {}
local function v2(x, y)
	return setmetatable({ _X = x or 0, _Y = y or 0 }, V2mt)
end
V2mt = dt("Vector2", {
	Magnitude = function(v)
		return math.sqrt(v._X ^ 2 + v._Y ^ 2)
	end,
}, {}, {
	__add = function(a, b)
		return v2(a._X + b._X, a._Y + b._Y)
	end,
	__sub = function(a, b)
		return v2(a._X - b._X, a._Y - b._Y)
	end,
	__mul = function(a, b)
		if type(b) == "number" then
			return v2(a._X * b, a._Y * b)
		elseif type(a) == "number" then
			return v2(b._X * a, b._Y * a)
		end
		return v2(a._X * b._X, a._Y * b._Y)
	end,
	__div = function(a, b)
		if type(b) == "number" then
			return v2(a._X / b, a._Y / b)
		end
		return v2(a._X / b._X, a._Y / b._Y)
	end,
	__eq = function(a, b)
		return a._X == b._X and a._Y == b._Y
	end,
})
Vector2.new = v2
Vector2.zero = v2(0, 0)
Vector2.one = v2(1, 1)
M.Vector2 = Vector2

-- CFrame (posición + matriz de rotación 3×3)
local CFmt
local CFrame = {}
local function cf(p, r)
	return setmetatable({ p = p, r = r or { 1, 0, 0, 0, 1, 0, 0, 0, 1 } }, CFmt)
end
local function rotMul(a, b)
	local o = {}
	for i = 0, 2 do
		for j = 0, 2 do
			local s = 0
			for k = 0, 2 do
				s += a[i * 3 + k + 1] * b[k * 3 + j + 1]
			end
			o[i * 3 + j + 1] = s
		end
	end
	return o
end
local function rotVec(r, v)
	return v3(r[1] * v._X + r[2] * v._Y + r[3] * v._Z, r[4] * v._X + r[5] * v._Y + r[6] * v._Z, r[7] * v._X + r[8] * v._Y + r[9] * v._Z)
end
local function transpose(r)
	return { r[1], r[4], r[7], r[2], r[5], r[8], r[3], r[6], r[9] }
end
CFmt = dt("CFrame", {
	Position = function(c)
		return c.p
	end,
	X = function(c)
		return c.p._X
	end,
	Y = function(c)
		return c.p._Y
	end,
	Z = function(c)
		return c.p._Z
	end,
	LookVector = function(c)
		return v3(-c.r[3], -c.r[6], -c.r[9])
	end,
	RightVector = function(c)
		return v3(c.r[1], c.r[4], c.r[7])
	end,
	UpVector = function(c)
		return v3(c.r[2], c.r[5], c.r[8])
	end,
	Rotation = function(c)
		return cf(v3(0, 0, 0), c.r)
	end,
}, {
	Inverse = function(c)
		local rt = transpose(c.r)
		return cf(-rotVec(rt, c.p), rt)
	end,
	PointToWorldSpace = function(c, v)
		return c.p + rotVec(c.r, v)
	end,
	PointToObjectSpace = function(c, v)
		return rotVec(transpose(c.r), v - c.p)
	end,
	VectorToWorldSpace = function(c, v)
		return rotVec(c.r, v)
	end,
	ToWorldSpace = function(c, o)
		return c * o
	end,
	ToObjectSpace = function(c, o)
		return c:Inverse() * o
	end,
	Lerp = function(a, b, t)
		return cf(a.p:Lerp(b.p, t), b.r)
	end,
	GetComponents = function(c)
		return c.p._X, c.p._Y, c.p._Z, table.unpack(c.r)
	end,
}, {
	__mul = function(a, b)
		if getmetatable(b) == CFmt then
			return cf(a.p + rotVec(a.r, b.p), rotMul(a.r, b.r))
		end
		return a.p + rotVec(a.r, b)
	end,
	__add = function(a, b)
		return cf(a.p + b, a.r)
	end,
	__sub = function(a, b)
		return cf(a.p - b, a.r)
	end,
})
function CFrame.new(x, y, z, ...)
	if x == nil then
		return cf(v3(0, 0, 0))
	end
	if type(x) == "table" then
		if y then
			return CFrame.lookAt(x, y)
		end
		return cf(x)
	end
	local rest = { ... }
	if #rest == 9 then
		return cf(v3(x, y, z), rest)
	end
	return cf(v3(x, y, z))
end
function CFrame.Angles(rx, ry, rz)
	local cx, sx, cy, sy, cz, sz = math.cos(rx), math.sin(rx), math.cos(ry), math.sin(ry), math.cos(rz), math.sin(rz)
	local X = { 1, 0, 0, 0, cx, -sx, 0, sx, cx }
	local Y = { cy, 0, sy, 0, 1, 0, -sy, 0, cy }
	local Z = { cz, -sz, 0, sz, cz, 0, 0, 0, 1 }
	return cf(v3(0, 0, 0), rotMul(rotMul(X, Y), Z))
end
CFrame.fromEulerAnglesXYZ = CFrame.Angles
function CFrame.fromOrientation(rx, ry, rz)
	return CFrame.Angles(0, ry, 0) * CFrame.Angles(rx, 0, 0) * CFrame.Angles(0, 0, rz)
end
function CFrame.lookAt(pos, target, up)
	local f = (target - pos).Unit
	if f.Magnitude == 0 then
		return cf(pos)
	end
	local u = up or v3(0, 1, 0)
	local r = f:Cross(u).Unit
	if r.Magnitude == 0 then
		r = v3(1, 0, 0)
	end
	local uu = r:Cross(f)
	return cf(pos, { r._X, uu._X, -f._X, r._Y, uu._Y, -f._Y, r._Z, uu._Z, -f._Z })
end
CFrame.identity = cf(v3(0, 0, 0))
M.CFrame = CFrame

-- Color3
local C3mt = dt("Color3", {}, {
	Lerp = function(a, b, t)
		return setmetatable({ _R = a._R + (b._R - a._R) * t, _G = a._G + (b._G - a._G) * t, _B = a._B + (b._B - a._B) * t }, getmetatable(a))
	end,
	ToHex = function(c)
		return string.format("%02X%02X%02X", math.floor(c._R * 255 + 0.5), math.floor(c._G * 255 + 0.5), math.floor(c._B * 255 + 0.5))
	end,
	ToHSV = function(c)
		local r, g, b = c._R, c._G, c._B
		local mx, mn = math.max(r, g, b), math.min(r, g, b)
		local d = mx - mn
		local h = 0
		if d > 0 then
			if mx == r then
				h = ((g - b) / d) % 6
			elseif mx == g then
				h = (b - r) / d + 2
			else
				h = (r - g) / d + 4
			end
			h /= 6
		end
		return h, mx == 0 and 0 or d / mx, mx
	end,
}, {
	__eq = function(a, b)
		return a._R == b._R and a._G == b._G and a._B == b._B
	end,
})
local Color3 = {}
function Color3.new(r, g, b)
	return setmetatable({ _R = r or 0, _G = g or 0, _B = b or 0 }, C3mt)
end
function Color3.fromRGB(r, g, b)
	return Color3.new((r or 0) / 255, (g or 0) / 255, (b or 0) / 255)
end
function Color3.fromHex(h)
	assert(type(h) == "string", "Color3.fromHex: se esperaba texto")
	local s = h:gsub("^#", "")
	assert(#s == 6 and s:match("^%x+$"), "Color3.fromHex: código inválido «" .. h .. "»")
	return Color3.fromRGB(tonumber(s:sub(1, 2), 16), tonumber(s:sub(3, 4), 16), tonumber(s:sub(5, 6), 16))
end
function Color3.fromHSV(h, s, v)
	local i = math.floor(h * 6)
	local f = h * 6 - i
	local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
	local m = i % 6
	local r, g, b
	if m == 0 then
		r, g, b = v, t, p
	elseif m == 1 then
		r, g, b = q, v, p
	elseif m == 2 then
		r, g, b = p, v, t
	elseif m == 3 then
		r, g, b = p, q, v
	elseif m == 4 then
		r, g, b = t, p, v
	else
		r, g, b = v, p, q
	end
	return Color3.new(r, g, b)
end
M.Color3 = Color3

-- UDim / UDim2
local UDmt = dt("UDim", {}, {}, {
	__add = function(a, b)
		return setmetatable({ _Scale = a._Scale + b._Scale, _Offset = a._Offset + b._Offset }, getmetatable(a))
	end,
	__eq = function(a, b)
		return a._Scale == b._Scale and a._Offset == b._Offset
	end,
})
local UDim = {}
function UDim.new(s, o)
	assert(s == nil or type(s) == "number", "UDim.new: escala inválida")
	assert(o == nil or type(o) == "number", "UDim.new: desplazamiento inválido")
	return setmetatable({ _Scale = s or 0, _Offset = o or 0 }, UDmt)
end
M.UDim = UDim
local UD2mt = dt("UDim2", {
	Width = function(u)
		return u._X
	end,
	Height = function(u)
		return u._Y
	end,
}, {}, {
	__add = function(a, b)
		return setmetatable({ _X = a._X + b._X, _Y = a._Y + b._Y }, getmetatable(a))
	end,
	__sub = function(a, b)
		return setmetatable({ _X = UDim.new(a._X._Scale - b._X._Scale, a._X._Offset - b._X._Offset), _Y = UDim.new(a._Y._Scale - b._Y._Scale, a._Y._Offset - b._Y._Offset) }, getmetatable(a))
	end,
	__eq = function(a, b)
		return a._X == b._X and a._Y == b._Y
	end,
})
local UDim2 = {}
function UDim2.new(xs, xo, ys, yo)
	if type(xs) == "table" then
		return setmetatable({ _X = xs, _Y = xo }, UD2mt)
	end
	for _, v in { xs, xo, ys, yo } do
		assert(v == nil or (type(v) == "number" and v == v), "UDim2.new: valor inválido " .. tostring(v))
	end
	return setmetatable({ _X = UDim.new(xs, xo), _Y = UDim.new(ys, yo) }, UD2mt)
end
function UDim2.fromOffset(x, y)
	return UDim2.new(0, x or 0, 0, y or 0)
end
function UDim2.fromScale(x, y)
	return UDim2.new(x or 0, 0, y or 0, 0)
end
M.UDim2 = UDim2

-- Otros tipos simples
local function simple(name: string)
	local mt = { __type = name }
	mt.__index = mt
	return function(...)
		return setmetatable({ args = { ... } }, mt)
	end
end
M.NumberSequence = { new = simple("NumberSequence") }
M.NumberSequenceKeypoint = { new = simple("NumberSequenceKeypoint") }
M.ColorSequence = { new = simple("ColorSequence") }
M.ColorSequenceKeypoint = { new = simple("ColorSequenceKeypoint") }
M.NumberRange = { new = simple("NumberRange") }
M.TweenInfo = { new = simple("TweenInfo") }
M.Rect = { new = simple("Rect") }
M.PhysicalProperties = { new = simple("PhysicalProperties") }
local Fontmt = { __type = "Font" }
Fontmt.__index = Fontmt
M.Font = {
	new = function(family, weight, style)
		assert(type(family) == "string", "Font.new: familia inválida")
		return setmetatable({ Family = family, Weight = weight, Style = style }, Fontmt)
	end,
	fromEnum = function(e)
		return setmetatable({ Family = "rbxasset://fonts/families/" .. tostring(e.Name) .. ".json" }, Fontmt)
	end,
}
local Randmt = { __type = "Random" }
Randmt.__index = Randmt
function Randmt:NextNumber(a, b)
	local x = math.random()
	if a then
		return a + (b - a) * x
	end
	return x
end
function Randmt:NextInteger(a, b)
	return math.random(a, b)
end
M.Random = {
	new = function(seed)
		if seed then
			math.randomseed(seed)
		end
		return setmetatable({}, Randmt)
	end,
}

-- Enum: cualquier Enum.Tipo.Valor devuelve un ítem con nombre.
local enumCache = {}
local EnumItemMt = { __type = "EnumItem" }
EnumItemMt.__index = EnumItemMt
EnumItemMt.__tostring = function(e)
	return "Enum." .. e.EnumType .. "." .. e.Name
end
M.Enum = setmetatable({}, {
	__index = function(_, typeName)
		enumCache[typeName] = enumCache[typeName] or setmetatable({}, {
			__index = function(t, item)
				local e = setmetatable({ Name = item, EnumType = typeName, Value = 0 }, EnumItemMt)
				rawset(t, item, e)
				return e
			end,
		})
		return enumCache[typeName]
	end,
})

-- Instancias ----------------------------------------------------------------------------------
local HIER = {
	Frame = { "GuiObject" },
	TextLabel = { "GuiObject" },
	TextButton = { "GuiButton", "GuiObject" },
	ImageButton = { "GuiButton", "GuiObject" },
	ImageLabel = { "GuiObject" },
	TextBox = { "GuiObject" },
	ScrollingFrame = { "GuiObject" },
	ViewportFrame = { "GuiObject" },
	CanvasGroup = { "GuiObject" },
	ScreenGui = { "LayerCollector", "GuiBase2d" },
	BillboardGui = { "LayerCollector", "GuiBase2d" },
	SurfaceGui = { "LayerCollector", "GuiBase2d" },
	Part = { "BasePart", "PVInstance" },
	SpawnLocation = { "Part", "BasePart", "PVInstance" },
	WedgePart = { "BasePart", "PVInstance" },
	MeshPart = { "BasePart", "PVInstance" },
	Script = { "BaseScript", "LuaSourceContainer" },
	LocalScript = { "Script", "BaseScript", "LuaSourceContainer" },
	ModuleScript = { "LuaSourceContainer" },
	Model = { "PVInstance" },
	WorldModel = { "Model", "PVInstance" },
	Player = {},
}
for _, c in { "UICorner", "UIStroke", "UIPadding", "UIListLayout", "UIGridLayout", "UIScale", "UIGradient", "UISizeConstraint", "UIFlexItem", "UIAspectRatioConstraint", "UITextSizeConstraint", "UIPageLayout" } do
	HIER[c] = { "UIComponent", "UIBase" }
end

local EVENTS = {
	Activated = true, MouseButton1Click = true, MouseButton1Down = true, MouseButton1Up = true, MouseEnter = true, MouseLeave = true,
	InputBegan = true, InputChanged = true, InputEnded = true, FocusLost = true, Focused = true, Triggered = true,
	PromptTriggered = true, OnClientEvent = true, OnServerEvent = true, ChildAdded = true, ChildRemoved = true, Changed = true,
	Destroying = true, CharacterAdded = true, CharacterRemoving = true, PlayerAdded = true, PlayerRemoving = true, Heartbeat = true,
	RenderStepped = true, Stepped = true, TextBoxFocusReleased = true, Completed = true, MouseWheelForward = true,
	MouseWheelBackward = true, DescendantAdded = true, AncestryChanged = true, Event = true, TouchTap = true,
}

local Instance = {}
local InstMt = { __type = "Instance" }
local methods = {}

local function isA(inst, className)
	if className == "Instance" or inst.ClassName == className then
		return true
	end
	for _, p in HIER[inst.ClassName] or {} do
		if p == className then
			return true
		end
	end
	return false
end

local function defaults(className: string)
	local p = { Name = className, Archivable = true }
	if HIER[className] and table.find(HIER[className], "GuiObject") then
		p.Visible = true
		p.Size = UDim2.new()
		p.Position = UDim2.new()
		p.AnchorPoint = v2(0, 0)
		p.AbsoluteSize = v2(100, 30)
		p.AbsolutePosition = v2(0, 0)
		p.BackgroundTransparency = 0
		p.BackgroundColor3 = Color3.new(1, 1, 1)
		p.ZIndex = 1
		p.LayoutOrder = 0
		p.Active = false
		if className == "TextLabel" or className == "TextButton" or className == "TextBox" then
			p.Text = ""
			p.TextSize = 14
		end
		if className == "ScrollingFrame" then
			p.CanvasPosition = v2(0, 0)
			p.AbsoluteCanvasSize = v2(100, 100)
			p.AbsoluteWindowSize = v2(100, 100)
		end
	end
	if className == "ScreenGui" then
		p.Enabled = true
		p.AbsoluteSize = v2(1600, 900)
	end
	if HIER[className] and table.find(HIER[className], "BasePart") then
		p.Size = v3(4, 1, 2)
		p.CFrame = CFrame.new()
		p.PivotOffset = CFrame.new()
		p.Anchored = false
		p.Transparency = 0
		p.Color = Color3.new(0.6, 0.6, 0.6)
	end
	if className == "Camera" then
		p.CFrame = CFrame.new()
		p.FieldOfView = 70
		p.ViewportSize = v2(1600, 900)
	end
	return p
end

function Instance.new(className: string, parent: any?)
	assert(type(className) == "string", "Instance.new: clase inválida")
	local inst = setmetatable({ __props = defaults(className), __children = {}, __signals = {}, __attrs = {}, __changed = {}, ClassName = className }, InstMt)
	if parent then
		inst.Parent = parent
	end
	return inst
end
M.Instance = Instance

InstMt.__index = function(inst, k)
	local m = methods[k]
	if m then
		return m
	end
	local props = rawget(inst, "__props")
	local v = props[k]
	if v ~= nil then
		return v
	end
	if EVENTS[k] then
		local sigs = rawget(inst, "__signals")
		sigs[k] = sigs[k] or Signal.new()
		return sigs[k]
	end
	-- Hijos por nombre (como inst.Hijo en Roblox).
	for _, c in rawget(inst, "__children") do
		if c.Name == k then
			return c
		end
	end
	return nil
end

InstMt.__newindex = function(inst, k, v)
	local props = rawget(inst, "__props")
	if rawget(inst, "__destroyed") and k == "Parent" and v ~= nil then
		error("No se puede cambiar Parent de una instancia destruida (" .. tostring(props.Name) .. ")")
	end
	if k == "Parent" then
		local old = props.Parent
		if old == v then
			return
		end
		if v ~= nil then
			assert(getmetatable(v) == InstMt, "Parent debe ser una instancia")
			local p = v
			while p do
				assert(p ~= inst, "Parent circular")
				p = rawget(p, "__props").Parent
			end
		end
		if old then
			local list = rawget(old, "__children")
			local i = table.find(list, inst)
			if i then
				table.remove(list, i)
			end
			old.ChildRemoved:Fire(inst)
		end
		props.Parent = v
		if v then
			table.insert(rawget(v, "__children"), inst)
			v.ChildAdded:Fire(inst)
		end
		return
	end
	if k == "Size" and props.Size ~= nil and M.typeof(v) ~= M.typeof(props.Size) then
		error(inst.ClassName .. ".Size: tipo inválido (" .. M.typeof(v) .. ")")
	end
	if (k == "Text" or k == "PlaceholderText" or k == "Name") and type(v) ~= "string" then
		error(inst.ClassName .. "." .. k .. ": se esperaba texto, llegó " .. M.typeof(v))
	end
	local colorOk = M.typeof(v) == "Color3" or (k == "Color" and inst.ClassName == "UIGradient" and M.typeof(v) == "ColorSequence")
	if (k == "BackgroundColor3" or k == "TextColor3" or k == "Color") and not colorOk then
		error(inst.ClassName .. "." .. k .. ": se esperaba Color3, llegó " .. M.typeof(v))
	end
	if (k == "Position" or k == "Size") and inst:IsA("GuiObject") and M.typeof(v) ~= "UDim2" then
		error(inst.ClassName .. "." .. k .. ": se esperaba UDim2, llegó " .. M.typeof(v))
	end
	local before = props[k]
	props[k] = v
	if before ~= v then
		local sig = rawget(inst, "__changed")[k]
		if sig then
			sig:Fire()
		end
		local ch = rawget(inst, "__signals").Changed
		if ch then
			ch:Fire(k)
		end
	end
end

InstMt.__tostring = function(inst)
	return rawget(inst, "__props").Name
end

function methods:IsA(className)
	return isA(self, className)
end
function methods:GetChildren()
	return table.clone(rawget(self, "__children"))
end
function methods:GetDescendants()
	local out = {}
	local function walk(i)
		for _, c in rawget(i, "__children") do
			table.insert(out, c)
			walk(c)
		end
	end
	walk(self)
	return out
end
function methods:FindFirstChild(name, recursive)
	for _, c in rawget(self, "__children") do
		if c.Name == name then
			return c
		end
	end
	if recursive then
		for _, c in rawget(self, "__children") do
			local f = c:FindFirstChild(name, true)
			if f then
				return f
			end
		end
	end
	return nil
end
function methods:FindFirstChildOfClass(cls)
	for _, c in rawget(self, "__children") do
		if c.ClassName == cls then
			return c
		end
	end
	return nil
end
function methods:FindFirstChildWhichIsA(cls, recursive)
	for _, c in rawget(self, "__children") do
		if c:IsA(cls) then
			return c
		end
	end
	if recursive then
		for _, c in rawget(self, "__children") do
			local f = c:FindFirstChildWhichIsA(cls, true)
			if f then
				return f
			end
		end
	end
	return nil
end
function methods:FindFirstAncestorOfClass(cls)
	local p = self.Parent
	while p do
		if p.ClassName == cls then
			return p
		end
		p = p.Parent
	end
	return nil
end
function methods:FindFirstAncestorWhichIsA(cls)
	local p = self.Parent
	while p do
		if p:IsA(cls) then
			return p
		end
		p = p.Parent
	end
	return nil
end
function methods:WaitForChild(name, timeout)
	local tries = 0
	while true do
		local c = self:FindFirstChild(name)
		if c then
			return c
		end
		tries += 1
		if tries > (timeout and timeout * 60 or 30) then
			return nil
		end
		ltask.wait()
	end
end
function methods:IsDescendantOf(other)
	local p = self.Parent
	while p do
		if p == other then
			return true
		end
		p = p.Parent
	end
	return false
end
function methods:Destroy()
	if rawget(self, "__destroyed") then
		return
	end
	local sig = rawget(self, "__signals").Destroying
	if sig then
		sig:Fire()
	end
	for _, c in table.clone(rawget(self, "__children")) do
		c:Destroy()
	end
	self.Parent = nil
	rawset(self, "__destroyed", true)
	M.destroyed += 1
end
function methods:ClearAllChildren()
	for _, c in table.clone(rawget(self, "__children")) do
		c:Destroy()
	end
end
-- Como en Roblox: las propiedades que apuntan a instancias dentro de lo clonado (PrimaryPart, Adornee…)
-- apuntan a las copias, no a los originales.
local function cloneInto(self, map)
	local c = Instance.new(self.ClassName)
	map[self] = c
	for k, v in rawget(self, "__props") do
		if k ~= "Parent" then
			rawget(c, "__props")[k] = v
		end
	end
	for k, v in rawget(self, "__attrs") do
		rawget(c, "__attrs")[k] = v
	end
	for _, ch in rawget(self, "__children") do
		cloneInto(ch, map).Parent = c
	end
	return c
end
function methods:Clone()
	local map = {}
	local c = cloneInto(self, map)
	for _, copy in map do
		local props = rawget(copy, "__props")
		for k, v in props do
			if k ~= "Parent" and map[v] then
				props[k] = map[v]
			end
		end
	end
	return c
end
function methods:GetAttribute(k)
	return rawget(self, "__attrs")[k]
end
function methods:SetAttribute(k, v)
	rawget(self, "__attrs")[k] = v
end
function methods:GetAttributes()
	return table.clone(rawget(self, "__attrs"))
end
function methods:GetPropertyChangedSignal(prop)
	local c = rawget(self, "__changed")
	c[prop] = c[prop] or Signal.new()
	return c[prop]
end
function methods:GetFullName()
	local parts = {}
	local p = self
	while p do
		table.insert(parts, 1, p.Name)
		p = p.Parent
	end
	return table.concat(parts, ".")
end
-- Como en Roblox: mover el pivote mueve todas las piezas del modelo, conservando sus posiciones relativas.
-- El pivote de un modelo con PrimaryPart es el de esa pieza (CFrame * PivotOffset) y WorldPivot se
-- ignora; sin PrimaryPart, es WorldPivot.
function methods:PivotTo(c)
	assert(M.typeof(c) == "CFrame", "PivotTo: se esperaba CFrame")
	if isA(self, "BasePart") then
		rawget(self, "__props").CFrame = c * rawget(self, "__props").PivotOffset:Inverse()
		return
	end
	local delta = c * self:GetPivot():Inverse()
	for _, d in self:GetDescendants() do
		if isA(d, "BasePart") then
			rawget(d, "__props").CFrame = delta * rawget(d, "__props").CFrame
		end
	end
	if not rawget(self, "__props").PrimaryPart then
		rawget(self, "__props").WorldPivot = c
	end
end
function methods:GetPivot()
	local props = rawget(self, "__props")
	if isA(self, "BasePart") then
		return props.CFrame * props.PivotOffset
	end
	local pp = props.PrimaryPart
	if pp then
		return rawget(pp, "__props").CFrame * rawget(pp, "__props").PivotOffset
	end
	return props.WorldPivot or CFrame.new()
end
function methods:GetBoundingBox()
	return self:GetPivot(), v3(8, 4, 14)
end
function methods:GetExtentsSize()
	return v3(8, 4, 14)
end
function methods:CaptureFocus()
	M.focused = self
	self.Focused:Fire()
end
function methods:ReleaseFocus(enter)
	if M.focused == self then
		M.focused = nil
	end
	self.FocusLost:Fire(enter == true)
	M.services.UserInputService.TextBoxFocusReleased:Fire(self)
end
function methods:IsFocused()
	return M.focused == self
end
-- Remotos: los argumentos se copian como si viajaran por la red.
local function wire(v: any, depth: number?): any
	local d = depth or 0
	assert(d < 60, "estructura demasiado profunda para la red")
	local t = type(v)
	if t == "function" or t == "thread" then
		error("No se pueden enviar funciones por un remoto")
	end
	if t ~= "table" then
		return v
	end
	if getmetatable(v) == InstMt then
		return v
	end
	local out = {}
	for k, x in v do
		out[k] = wire(x, d + 1)
	end
	return out
end
M.wire = wire
function methods:InvokeServer(...)
	assert(self.ClassName == "RemoteFunction", "InvokeServer solo en RemoteFunction")
	local cb = rawget(self, "__props").OnServerInvoke
	assert(cb, "El servidor no definió OnServerInvoke")
	local args = wire(table.pack(...))
	M.stats.invokes += 1
	return wire(cb(M.localPlayer, table.unpack(args, 1, args.n)))
end
function methods:FireClient(player, ...)
	assert(self.ClassName == "RemoteEvent", "FireClient solo en RemoteEvent")
	if player == M.localPlayer then
		local args = wire(table.pack(...))
		M.stats.fires += 1
		self.OnClientEvent:Fire(table.unpack(args, 1, args.n))
	end
end
function methods:FireAllClients(...)
	self:FireClient(M.localPlayer, ...)
end
function methods:FireServer(...)
	local args = wire(table.pack(...))
	self.OnServerEvent:Fire(M.localPlayer, table.unpack(args, 1, args.n))
end
function methods:GetService(name)
	return M.services[name] or error("Servicio no simulado: " .. tostring(name))
end
function methods:GetPlayers()
	return table.clone(M.players)
end
function methods:GetPlayerByUserId(id)
	for _, p in M.players do
		if p.UserId == id then
			return p
		end
	end
	return nil
end
function methods:Play() end
function methods:Stop() end
function methods:Cancel() end

-- Servicios ------------------------------------------------------------------------------------
local function service(name: string)
	local s = Instance.new("Folder")
	rawget(s, "__props").Name = name
	return s
end

function M.reset(opts: any?)
	local o = opts or {}
	M.destroyed = 0
	M.focused = nil
	M.players = {}
	M.stats = { invokes = 0, fires = 0 }
	M.log = {}
	local S = {}
	M.services = S
	for _, name in { "ReplicatedStorage", "ServerStorage", "ServerScriptService", "StarterPlayer", "Lighting", "StarterGui", "SoundService", "ProximityPromptService", "ContentProvider" } do
		S[name] = service(name)
	end
	S.StarterGui.SetCore = function() end
	S.SoundService.PlayLocalSound = function() end
	S.Workspace = service("Workspace")
	local cam = Instance.new("Camera")
	cam.ViewportSize = o.viewport or v2(1600, 900)
	S.Workspace.CurrentCamera = cam
	cam.Parent = S.Workspace
	S.Players = service("Players")
	S.RunService = service("RunService")
	S.RunService.IsStudio = function()
		return true
	end
	S.RunService.IsServer = function()
		return true
	end
	S.RunService.IsClient = function()
		return true
	end
	S.TextService = service("TextService")
	S.TextService.FilterStringAsync = function(_, text, _uid)
		return {
			GetNonChatStringForBroadcastAsync = function()
				if string.find(string.lower(text), "prohibido") then
					return string.rep("#", #text)
				end
				return text
			end,
		}
	end
	S.TextService.GetTextSize = function(_, text, size)
		return v2(#text * (size or 14) * 0.55, size or 14)
	end
	S.HttpService = service("HttpService")
	S.HttpService.JSONEncode = function(_, v)
		return serde.encode("json", v)
	end
	S.HttpService.JSONDecode = function(_, s)
		return serde.decode("json", s)
	end
	local guid = 0
	S.HttpService.GenerateGUID = function()
		guid += 1
		return string.format("00000000-0000-4000-8000-%012d", guid)
	end
	S.UserInputService = service("UserInputService")
	S.UserInputService.GetFocusedTextBox = function()
		return M.focused
	end
	S.UserInputService.TouchEnabled = o.touch == true
	S.UserInputService.KeyboardEnabled = o.touch ~= true
	S.UserInputService.MouseEnabled = o.touch ~= true
	S.UserInputService.GetMouseLocation = function()
		return v2(0, 0)
	end
	S.GuiService = service("GuiService")
	S.GuiService.GetGuiInset = function()
		return v2(0, 58), v2(0, 0)
	end
	S.TweenService = service("TweenService")
	S.TweenService.Create = function(_, inst, _info, props)
		return {
			Play = function()
				for k, v in props do
					inst[k] = v
				end
			end,
			Cancel = function() end,
			Completed = Signal.new(),
		}
	end
	S.DataStoreService = service("DataStoreService")
	M.datastore = { data = {}, studioDenied = o.studioDenied == true }
	S.DataStoreService.GetDataStore = function(_, _name)
		return {
			GetAsync = function(_, key)
				if M.datastore.studioDenied then
					error("StudioAccessToApisNotAllowed")
				end
				return M.datastore.data[key]
			end,
			UpdateAsync = function(_, key, fn)
				if M.datastore.studioDenied then
					error("StudioAccessToApisNotAllowed")
				end
				local cur = M.datastore.data[key]
				local res = fn(cur ~= nil and serde.decode("json", serde.encode("json", cur)) or nil)
				if res ~= nil then
					M.datastore.data[key] = serde.decode("json", serde.encode("json", res))
				end
				return res
			end,
		}
	end
	local g = service("Game")
	g.JobId = ""
	g.PlaceId = 0
	M.closeHandlers = {}
	g.BindToClose = function(_, fn)
		table.insert(M.closeHandlers, fn)
	end
	g.GetService = methods.GetService
	M.game = g
	M.workspace = S.Workspace
	M.localPlayer = nil
end

function M.newPlayer(userId: number, name: string)
	local p = Instance.new("Player")
	p.Name = name
	p.DisplayName = name
	p.UserId = userId
	local gui = Instance.new("Folder")
	gui.Name = "PlayerGui"
	gui.Parent = p
	local scripts = Instance.new("Folder")
	scripts.Name = "PlayerScripts"
	scripts.Parent = p
	local char = Instance.new("Model")
	char.Name = name
	p.Character = char
	return p
end

function M.addPlayer(p: any, isLocal: boolean?)
	table.insert(M.players, p)
	p.Parent = M.services.Players
	if isLocal then
		M.localPlayer = p
		rawget(M.services.Players, "__props").LocalPlayer = p
	end
	M.services.Players.PlayerAdded:Fire(p)
end

function M.removePlayer(p: any)
	M.services.Players.PlayerRemoving:Fire(p)
	local i = table.find(M.players, p)
	if i then
		table.remove(M.players, i)
	end
	p.Parent = nil
end

-- Avanza el reloj del servidor (Heartbeat) y del cliente (RenderStepped).
function M.step(seconds: number)
	for _ = 1, math.floor(seconds) do
		M.services.RunService.Heartbeat:Fire(1)
		M.services.RunService.RenderStepped:Fire(1 / 60)
	end
	ltask.wait()
end

-- Utilidades para manejar la interfaz como un jugador --------------------------------------------
local function visible(inst): boolean
	local p = inst
	while p do
		local props = rawget(p, "__props")
		if props.Visible == false or props.Enabled == false then
			return false
		end
		p = props.Parent
	end
	return true
end
M.visible = visible

function M.texts(root): { string }
	local out = {}
	for _, d in root:GetDescendants() do
		if (d.ClassName == "TextLabel" or d.ClassName == "TextButton" or d.ClassName == "TextBox") and visible(d) then
			table.insert(out, d.Text)
		end
	end
	return out
end

local function plain(s: string): string
	return (s:gsub("<[^>]+>", ""))
end
M.plain = plain

-- Busca un elemento visible cuyo texto contenga el patrón (texto plano, sin marcado).
function M.find(root, needle: string, className: string?): any
	for _, d in root:GetDescendants() do
		if (className == nil or d.ClassName == className) and visible(d) and not rawget(d, "__destroyed") then
			local t = rawget(d, "__props").Text
			if type(t) == "string" and string.find(plain(t), needle, 1, true) then
				return d
			end
		end
	end
	return nil
end

-- Botón que contiene un texto (el propio botón o un TextLabel dentro de él).
function M.button(root, needle: string): any
	for _, d in root:GetDescendants() do
		if (d.ClassName == "TextButton" or d.ClassName == "ImageButton") and visible(d) and not rawget(d, "__destroyed") then
			local t = rawget(d, "__props").Text
			if type(t) == "string" and string.find(plain(t), needle, 1, true) then
				return d
			end
			for _, c in d:GetDescendants() do
				local ct = rawget(c, "__props").Text
				if type(ct) == "string" and string.find(plain(ct), needle, 1, true) then
					return d
				end
			end
		end
	end
	return nil
end

function M.click(btn)
	assert(btn, "botón inexistente")
	assert(not rawget(btn, "__destroyed"), "botón destruido")
	btn.MouseButton1Click:Fire()
	btn.Activated:Fire({ UserInputType = M.Enum.UserInputType.MouseButton1 }, 1)
	ltask.wait()
end

-- Escribe en un TextBox como un jugador: foco → texto → soltar el foco.
function M.type(box, text: string, enter: boolean?)
	assert(box and box.ClassName == "TextBox", "se esperaba un TextBox")
	box:CaptureFocus()
	box.Text = text
	box:ReleaseFocus(enter)
	ltask.wait()
end

M.reset()
return M
