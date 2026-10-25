--!strict
--[[
	Componentes de interfaz nativos de Roblox con el estilo de la V3
	(tokens de color de :root, radios, botones .btn/.p/.g/.d/.q, chips, tarjetas, notas, barras).
]]

local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local CarModel = require(Shared.CarModel)
local Icons = require(script.Parent.Icons)

local Ui = {}

local function hex(h: string): Color3
	return Color3.fromHex(h)
end

-- Tokens de la V3 (:root)
Ui.T = {
	bg = hex("#080A0F"),
	p1 = hex("#111319"),
	p2 = hex("#171A21"),
	p3 = hex("#1D2029"),
	line = hex("#292D38"),
	line2 = hex("#23262F"),
	input = hex("#0C0E13"),
	panel = hex("#0E1016"),
	tx = hex("#F5F7FA"),
	tx2 = hex("#C3C8D2"),
	mut = hex("#A3AAB8"),
	mut2 = hex("#7D8493"),
	vi = hex("#7667FF"),
	vi2 = hex("#B3AAFF"),
	bl = hex("#3B82F6"),
	bl2 = hex("#8DB8FF"),
	gr = hex("#42E58D"),
	ye = hex("#F7C95C"),
	re = hex("#FF5F68"),
	re2 = hex("#FF8A91"),
	or_ = hex("#FFB36B"),
	pink = hex("#FF9DC1"),
	cyan = hex("#6FE3F0"),
	dark = hex("#0B0D12"),
	disabledBg = hex("#13151B"),
	disabledTx = hex("#666C7A"),
	btnLine = hex("#333847"),
}
local T = Ui.T

-- Tamaños de texto equivalentes a la escala de 15 px de la V3.
Ui.S = { base = 15, sm = 13, xs = 12, lbl = 11, h3 = 16, h2 = 20, h1 = 22, hero = 40 }

local FAMILY = "rbxasset://fonts/families/BuilderSans.json"
function Ui.font(weight: Enum.FontWeight?): Font
	return Font.new(FAMILY, weight or Enum.FontWeight.Regular)
end
local W = {
	reg = Enum.FontWeight.Regular,
	med = Enum.FontWeight.Medium,
	semi = Enum.FontWeight.SemiBold,
	bold = Enum.FontWeight.Bold,
	heavy = Enum.FontWeight.ExtraBold,
}
Ui.W = W

-- Fábrica genérica -------------------------------------------------------------------
--[[
	Ui.new(clase, props, hijos)
	Claves especiales en props:
	  Corner = radio en px · Stroke = Color3 | { Color, Thickness, Transparency }
	  Pad = n | { t, r, b, l } · List = { dir = "V"|"H", gap, h = "L"|"C"|"R", v = "T"|"C"|"B", wrap }
	  Click = función (botones) · Weight = Enum.FontWeight · Hover = Color3 (fondo al pasar el mouse)
]]
local orderCounter = 0
function Ui.new(className: string, props: { [string]: any }?, children: { Instance? }?): any
	local inst = Instance.new(className)
	local p = props or {}
	if inst:IsA("GuiObject") then
		(inst :: any).BorderSizePixel = 0
		orderCounter += 1;
		(inst :: any).LayoutOrder = orderCounter
	end
	if inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox") then
		local t = inst :: any
		t.FontFace = Ui.font(p.Weight or W.med)
		t.TextColor3 = T.tx
		t.TextSize = Ui.S.base
		t.BackgroundTransparency = 1
		t.TextXAlignment = Enum.TextXAlignment.Left
		t.RichText = true
		if inst:IsA("TextButton") then
			t.AutoButtonColor = false
		end
	end
	if inst:IsA("Frame") or inst:IsA("ScrollingFrame") then
		(inst :: any).BackgroundTransparency = 1
	end
	if inst:IsA("ScrollingFrame") then
		local s = inst :: any
		s.ScrollBarThickness = 4
		s.ScrollBarImageColor3 = hex("#3A3F4D")
		s.AutomaticCanvasSize = Enum.AutomaticSize.Y
		s.CanvasSize = UDim2.new()
		s.ScrollingDirection = Enum.ScrollingDirection.Y
		s.BorderSizePixel = 0
	end
	local SPECIAL = { Corner = true, Stroke = true, Pad = true, List = true, Click = true, Weight = true, Hover = true, Parent = true }
	for k, v in p do
		if not SPECIAL[k] then
			(inst :: any)[k] = v
		end
	end
	for k, v in p do
		if k == "Corner" then
			local c = Instance.new("UICorner")
			c.CornerRadius = UDim.new(0, v)
			c.Parent = inst
		elseif k == "Stroke" then
			local s = Instance.new("UIStroke")
			s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
			if typeof(v) == "Color3" then
				s.Color = v
				s.Thickness = 1
			else
				s.Color = v[1]
				s.Thickness = v[2] or 1
				s.Transparency = v[3] or 0
			end
			s.Parent = inst
		elseif k == "Pad" then
			local pad = Instance.new("UIPadding")
			local t, r, b, l
			if type(v) == "number" then
				t, r, b, l = v, v, v, v
			else
				t, r, b, l = v[1], v[2] or v[1], v[3] or v[1], v[4] or v[2] or v[1]
			end
			pad.PaddingTop = UDim.new(0, t)
			pad.PaddingRight = UDim.new(0, r)
			pad.PaddingBottom = UDim.new(0, b)
			pad.PaddingLeft = UDim.new(0, l)
			pad.Parent = inst
		elseif k == "List" then
			local l = Instance.new("UIListLayout")
			l.SortOrder = Enum.SortOrder.LayoutOrder
			l.FillDirection = (v.dir == "H") and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical
			l.Padding = UDim.new(0, v.gap or 0)
			l.HorizontalAlignment = (v.h == "C" and Enum.HorizontalAlignment.Center) or (v.h == "R" and Enum.HorizontalAlignment.Right) or Enum.HorizontalAlignment.Left
			l.VerticalAlignment = (v.v == "C" and Enum.VerticalAlignment.Center) or (v.v == "B" and Enum.VerticalAlignment.Bottom) or Enum.VerticalAlignment.Top
			l.Wraps = v.wrap == true
			l.Parent = inst
		elseif k == "Click" then
			(inst :: any).Activated:Connect(v)
		elseif k == "Hover" then
			local g = inst :: any
			local normal = g.BackgroundColor3
			g.MouseEnter:Connect(function()
				if g:GetAttribute("disabled") ~= true then
					g.BackgroundColor3 = v
				end
			end)
			g.MouseLeave:Connect(function()
				if g:GetAttribute("disabled") ~= true then
					g.BackgroundColor3 = normal
				end
			end)
		end
	end
	if children then
		for _, c in children do
			if c then
				c.Parent = inst
			end
		end
	end
	if p.Parent then
		inst.Parent = p.Parent
	end
	return inst
end
local new = Ui.new

-- Texto ------------------------------------------------------------------------------
-- Etiqueta que ocupa el ancho disponible y crece en alto (texto con salto de línea).
function Ui.text(text: string, opts: { [string]: any }?): TextLabel
	local o = opts or {}
	return new("TextLabel", {
		Text = text,
		TextSize = o.size or Ui.S.base,
		TextColor3 = o.color or T.tx,
		Weight = o.weight or W.med,
		TextWrapped = o.wrap ~= false,
		Size = o.width and UDim2.new(0, o.width, 0, 0) or UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextXAlignment = o.align == "R" and Enum.TextXAlignment.Right or (o.align == "C" and Enum.TextXAlignment.Center) or Enum.TextXAlignment.Left,
		LineHeight = o.lineHeight or 1.1,
		Name = o.name or "Texto",
	})
end

-- Etiqueta de ancho automático (una línea), para filas.
function Ui.inline(text: string, opts: { [string]: any }?): TextLabel
	local o = opts or {}
	return new("TextLabel", {
		Text = text,
		TextSize = o.size or Ui.S.base,
		TextColor3 = o.color or T.tx,
		Weight = o.weight or W.med,
		TextWrapped = false,
		Size = UDim2.new(0, 0, 0, o.height or 0),
		AutomaticSize = o.height and Enum.AutomaticSize.X or Enum.AutomaticSize.XY,
		TextXAlignment = o.align == "R" and Enum.TextXAlignment.Right or Enum.TextXAlignment.Left,
		Name = o.name or "Texto",
	})
end

-- .lbl de la V3: mayúsculas pequeñas.
function Ui.lbl(text: string, color: Color3?): TextLabel
	return Ui.inline(string.upper(text), { size = Ui.S.lbl, color = color or T.mut, weight = W.bold })
end

-- Contenedores ------------------------------------------------------------------------
function Ui.col(children: { Instance? }, gap: number?, props: { [string]: any }?): Frame
	local p = props or {}
	local base = {
		Size = p.Size or UDim2.new(1, 0, 0, 0),
		AutomaticSize = p.AutomaticSize or Enum.AutomaticSize.Y,
		List = { dir = "V", gap = gap or 10, h = p.h },
	}
	for k, v in p do
		if k ~= "h" then
			base[k] = v
		end
	end
	return new("Frame", base, children)
end

function Ui.row(children: { Instance? }, gap: number?, props: { [string]: any }?): Frame
	local p = props or {}
	local base = {
		Size = p.Size or UDim2.new(1, 0, 0, 0),
		AutomaticSize = p.AutomaticSize or Enum.AutomaticSize.Y,
		List = { dir = "H", gap = gap or 10, v = p.v or "C", h = p.h, wrap = p.wrap },
	}
	for k, v in p do
		if k ~= "v" and k ~= "h" and k ~= "wrap" then
			base[k] = v
		end
	end
	return new("Frame", base, children)
end

-- Elemento que se estira para ocupar el espacio libre en una fila horizontal.
function Ui.grow(child: Instance?, props: { [string]: any }?): Frame
	local f = new("Frame", props or { Size = UDim2.new(0, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, { child })
	local flex = Instance.new("UIFlexItem")
	flex.FlexMode = Enum.UIFlexMode.Fill
	flex.Parent = f
	return f
end

function Ui.spacer(): Frame
	return Ui.grow(nil, { Size = UDim2.new(0, 0, 0, 1) })
end

function Ui.card(children: { Instance? }, props: { [string]: any }?): Frame
	local p = props or {}
	local base = {
		BackgroundColor3 = p.bg or T.p2,
		BackgroundTransparency = p.transparency or 0,
		Size = p.Size or UDim2.new(1, 0, 0, 0),
		AutomaticSize = p.AutomaticSize or Enum.AutomaticSize.Y,
		Corner = p.radius or 10,
		Stroke = p.stroke or T.line2,
		Pad = p.pad or 14,
		List = { dir = p.dir or "V", gap = p.gap or 8, v = p.v },
		Name = p.name or "Tarjeta",
	}
	return new("Frame", base, children)
end

function Ui.scroll(children: { Instance? }, props: { [string]: any }?): ScrollingFrame
	local p = props or {}
	local s = new("ScrollingFrame", {
		Size = p.Size or UDim2.fromScale(1, 1),
		Position = p.Position,
		Name = p.name or "Desplazable",
		List = { dir = "V", gap = p.gap or 14 },
		Pad = p.pad or { 2, 8, 12, 2 },
	}, children)
	return s
end

-- Separador .hr
function Ui.hr(): Frame
	return new("Frame", { Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = T.line2, BackgroundTransparency = 0 })
end

-- Botones .btn --------------------------------------------------------------------------
local VARIANTS = {
	default = { bg = T.p2, fg = T.tx, line = T.btnLine, hover = hex("#1F232C") },
	p = { bg = T.tx, fg = T.dark, line = T.tx, hover = hex("#FFFFFF") },
	g = { bg = T.gr, fg = hex("#05230F"), line = T.gr, hover = hex("#5BF0A0") },
	d = { bg = hex("#2A1519"), fg = T.re2, line = hex("#7A3A40"), hover = hex("#3A1C21") },
	q = { bg = T.bg, fg = T.mut, line = T.bg, hover = hex("#15171D"), transparent = true },
	v = { bg = T.vi, fg = T.tx, line = T.vi, hover = hex("#8A7DFF") },
}

--[[
	Botón .btn. El estado (habilitado, motivo, procesando) vive en atributos del propio botón:
	la apariencia y el clic leen el mismo dato, así un cambio con Ui.setEnabled se aplica a ambos.
	opts: { small, disabled, why (motivo visible al tocarlo deshabilitado), width, fill, height, name, flex, icon }
]]
local function paintButton(b: TextButton)
	local v = VARIANTS[b:GetAttribute("kind") or "default"] or VARIANTS.default
	local enabled = b:GetAttribute("disabled") ~= true and b:GetAttribute("busy") ~= true
	b.TextColor3 = enabled and v.fg or T.disabledTx
	b.BackgroundColor3 = enabled and v.bg or T.disabledBg
	b.BackgroundTransparency = (v.transparent and enabled) and 1 or 0
	local stroke = b:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = enabled and v.line or hex("#22252E")
		stroke.Transparency = (v.transparent and enabled) and 1 or 0
	end
	local icon = b:FindFirstChild("Icono")
	if icon and Ui.recolorIcon then
		Ui.recolorIcon(icon, b.TextColor3)
	end
end

function Ui.button(label: string, kind: string?, onClick: (() -> ())?, opts: { [string]: any }?): TextButton
	local o = opts or {}
	local v = VARIANTS[kind or "default"] or VARIANTS.default
	local h = o.height or (o.small and 36 or 44)
	local b = new("TextButton", {
		Name = o.name or "Boton",
		Text = label,
		TextSize = o.small and Ui.S.sm or 14,
		Weight = W.bold,
		TextColor3 = v.fg,
		BackgroundColor3 = v.bg,
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = o.fill and UDim2.new(1, 0, 0, h) or UDim2.new(0, o.width or 0, 0, h),
		AutomaticSize = (o.fill or o.width) and Enum.AutomaticSize.None or Enum.AutomaticSize.X,
		Corner = o.small and 8 or 10,
		Stroke = v.line,
		Pad = { 0, (o.width and o.width <= 44) and 0 or (o.small and 12 or 16) },
		AutoButtonColor = false,
	})
	b:SetAttribute("kind", kind or "default")
	b:SetAttribute("label", label)
	b:SetAttribute("disabled", o.disabled == true)
	b:SetAttribute("why", o.why)
	if o.icon and Ui.icon then
		local ic = Ui.icon(o.icon, o.small and 15 or 17, v.fg)
		ic.Name = "Icono"
		ic.LayoutOrder = -1
		ic.Parent = b
		local list = Instance.new("UIListLayout")
		list.FillDirection = Enum.FillDirection.Horizontal
		list.HorizontalAlignment = Enum.HorizontalAlignment.Center
		list.VerticalAlignment = Enum.VerticalAlignment.Center
		list.SortOrder = Enum.SortOrder.LayoutOrder
		list.Padding = UDim.new(0, label == "" and 0 or 7)
		list.Parent = b
		-- El texto pasa a una etiqueta para quedar al lado del ícono.
		if label ~= "" then
			b.Text = ""
			local t = new("TextLabel", { Name = "Etiqueta", Text = label, TextSize = b.TextSize, Weight = W.bold, TextColor3 = v.fg, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 1 })
			t.Parent = b
			b:GetPropertyChangedSignal("TextColor3"):Connect(function()
				t.TextColor3 = b.TextColor3
			end)
		end
	end
	paintButton(b)
	local function hover(on: boolean)
		if b:GetAttribute("disabled") ~= true and b:GetAttribute("busy") ~= true then
			b.BackgroundColor3 = on and v.hover or v.bg
		end
	end
	b.MouseEnter:Connect(function()
		hover(true)
	end)
	b.MouseLeave:Connect(function()
		hover(false)
	end)
	if o.flex then
		local flex = Instance.new("UIFlexItem")
		flex.FlexMode = Enum.UIFlexMode.Grow
		flex.GrowRatio = o.flex
		flex.Parent = b
	end
	b.Activated:Connect(function()
		if b:GetAttribute("busy") == true then
			return
		end
		if b:GetAttribute("disabled") == true then
			local why = b:GetAttribute("why")
			if why and Ui.onDisabled then
				Ui.onDisabled(why)
			end
			return
		end
		if onClick then
			onClick()
		end
	end)
	return b
end

-- Cambia el estado de un botón ya construido (apariencia y comportamiento a la vez).
function Ui.setEnabled(b: TextButton, enabled: boolean, why: string?)
	b:SetAttribute("disabled", not enabled)
	b:SetAttribute("why", why)
	paintButton(b)
end

function Ui.isEnabled(b: TextButton): boolean
	return b:GetAttribute("disabled") ~= true and b:GetAttribute("busy") ~= true
end

-- «Procesando…»: el botón queda inactivo mientras el servidor responde, sin perder su texto.
function Ui.setBusy(b: TextButton, busy: boolean)
	if not b.Parent then
		return
	end
	b:SetAttribute("busy", busy)
	local label = b:GetAttribute("label") or ""
	local target = b:FindFirstChild("Etiqueta") or b
	if label ~= "" then
		(target :: any).Text = busy and "Procesando…" or label
	end
	paintButton(b)
end

-- Se asigna desde App: muestra el motivo de un botón deshabilitado (equivalente a .why / title).
Ui.onDisabled = nil :: ((string) -> ())?

-- .opt (opción seleccionable)
function Ui.opt(label: string, selected: boolean, onClick: () -> (), opts: { [string]: any }?): TextButton
	local o = opts or {}
	local disabled = o.disabled == true
	local b = new("TextButton", {
		Name = "Opcion",
		Text = label,
		TextSize = o.size or Ui.S.sm,
		Weight = W.semi,
		TextColor3 = selected and T.tx or T.tx2,
		TextTransparency = disabled and 0.5 or 0,
		BackgroundColor3 = selected and hex("#1E1B3D") or T.input,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextWrapped = true,
		Size = o.fill and UDim2.new(1, 0, 0, o.height or 40) or UDim2.new(0, o.width or 0, 0, o.height or 40),
		AutomaticSize = (o.fill or o.width) and Enum.AutomaticSize.None or Enum.AutomaticSize.X,
		Corner = 9,
		Stroke = selected and { T.vi, 2 } or T.line,
		Pad = { 4, 10 },
		Hover = (not selected and not disabled) and hex("#151820") or nil,
	})
	b.Activated:Connect(function()
		if disabled then
			if o.why and Ui.onDisabled then
				Ui.onDisabled(o.why)
			end
			return
		end
		onClick()
	end)
	return b
end

-- Grilla de opciones (.grid2/.grid3/.grid4)
function Ui.grid(children: { Instance? }, columns: number, cellHeight: number?, gap: number?): Frame
	local g = gap or 8
	local f = new("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Name = "Grilla" })
	local layout = Instance.new("UIGridLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.CellPadding = UDim2.fromOffset(g, g)
	layout.CellSize = UDim2.new(1 / columns, -g * (columns - 1) / columns, 0, cellHeight or 40)
	layout.Parent = f
	for _, c in children do
		if c then
			c.Parent = f
		end
	end
	return f
end

-- Muestra de color .sw
function Ui.swatch(color: string, selected: boolean, onClick: () -> (), size: number?): TextButton
	local s = size or 36
	local b = new("TextButton", {
		Name = "Muestra",
		Text = "",
		BackgroundColor3 = Color3.fromHex(color),
		Size = UDim2.fromOffset(s, s),
		Corner = s // 2,
		Stroke = selected and { T.tx, 3 } or { T.line, 1 },
	})
	b.Activated:Connect(onClick)
	return b
end

-- Interruptor .tg
function Ui.toggle(on: boolean, onClick: () -> ()): TextButton
	local b = new("TextButton", {
		Name = "Interruptor",
		Text = "",
		Size = UDim2.fromOffset(48, 28),
		BackgroundColor3 = on and T.gr or hex("#2F3340"),
		Corner = 14,
	}, {
		new("Frame", {
			Size = UDim2.fromOffset(20, 20),
			Position = UDim2.fromOffset(on and 24 or 4, 4),
			BackgroundColor3 = hex("#FFFFFF"),
			BackgroundTransparency = 0,
			Corner = 10,
		}),
	})
	b.Activated:Connect(onClick)
	return b
end

-- Chips .chip (cg, cy, cv, cb, cr, cn)
local CHIPS = {
	cg = { hex("#14301F"), T.gr },
	cy = { hex("#322A14"), T.ye },
	cv = { hex("#262252"), hex("#C4BDFF") },
	cb = { hex("#142844"), T.bl2 },
	cr = { hex("#33171A"), T.re2 },
	cn = { T.p3, hex("#C3C8D2") },
	co = { hex("#33241A"), T.or_ },
}
function Ui.chip(text: string, kind: string?): TextLabel
	local c = CHIPS[kind or "cn"] or CHIPS.cn
	return new("TextLabel", {
		Name = "Chip",
		Text = text,
		TextSize = Ui.S.xs,
		Weight = W.bold,
		TextColor3 = c[2],
		BackgroundColor3 = c[1],
		BackgroundTransparency = 0,
		Size = UDim2.fromOffset(0, 24),
		AutomaticSize = Enum.AutomaticSize.X,
		Corner = 7,
		Pad = { 0, 9 },
		TextXAlignment = Enum.TextXAlignment.Center,
	})
end

-- Barra .bar. Devuelve (contenedor, relleno) para poder actualizar el relleno en vivo.
function Ui.bar(pct: number, color: Color3?, height: number?): (Frame, Frame)
	local fill = new("Frame", {
		Name = "Relleno",
		BackgroundColor3 = color or T.vi,
		BackgroundTransparency = 0,
		Size = UDim2.new(math.clamp(pct, 0, 100) / 100, 0, 1, 0),
		Corner = 4,
	})
	local bar = new("Frame", {
		Name = "Barra",
		BackgroundColor3 = hex("#232733"),
		BackgroundTransparency = 0,
		Size = UDim2.new(1, 0, 0, height or 7),
		Corner = 4,
		ClipsDescendants = true,
	}, { fill })
	return bar, fill
end

function Ui.setBar(fill: Frame, pct: number)
	fill.Size = UDim2.new(math.clamp(pct, 0, 100) / 100, 0, 1, 0)
end

-- Notas .note (y, r, b, g)
local NOTES = {
	y = { hex("#16140C"), hex("#5E4E26"), hex("#F5DC9A"), "warn" },
	r = { hex("#170D10"), hex("#663036"), hex("#FFB3B7"), "warn" },
	b = { hex("#0C121C"), hex("#22406E"), hex("#C2D8FF"), "help" },
	g = { hex("#0C1712"), hex("#226043"), hex("#B4F3CF"), "check" },
}
function Ui.note(kind: string, text: string, extra: Instance?): Frame
	local n = NOTES[kind] or NOTES.b
	return new("Frame", {
		Name = "Nota",
		BackgroundColor3 = n[1],
		BackgroundTransparency = 0,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Corner = 10,
		Stroke = n[2],
		Pad = { 10, 12 },
		List = { dir = "H", gap = 10, v = "C" },
	}, {
		Icons.make(n[4], 16, n[3]),
		Ui.grow(Ui.text(text, { size = Ui.S.sm, color = n[3], lineHeight = 1.25 }), { Size = UDim2.new(0, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }),
		extra,
	})
end

-- .kv: etiqueta + valor destacado
function Ui.kv(label: string, value: string, opts: { [string]: any }?): (Frame, TextLabel)
	local o = opts or {}
	local v = Ui.text(value, { size = o.valueSize or 16, weight = W.bold, color = o.color or T.tx })
	local f = new("Frame", {
		Name = "KV",
		BackgroundColor3 = T.p2,
		BackgroundTransparency = 0,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Corner = 10,
		Stroke = T.line2,
		Pad = { 10, 12 },
		List = { dir = "V", gap = 3 },
	}, {
		Ui.text(label, { size = Ui.S.xs, color = T.mut, weight = W.semi }),
		v,
		o.sub and Ui.text(o.sub, { size = Ui.S.xs, color = T.mut }) or nil,
	})
	return f, v
end

-- .line: fila con texto a la izquierda y valor a la derecha
function Ui.line(left: string, right: string, opts: { [string]: any }?): Frame
	local o = opts or {}
	return new("Frame", {
		Name = "Linea",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Pad = { 7, 0 },
		List = { dir = "H", gap = 12, v = "C" },
	}, {
		Ui.grow(Ui.text(left, { size = o.size or Ui.S.sm, color = o.leftColor or T.tx, weight = o.leftWeight }), { Size = UDim2.new(0, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }),
		Ui.inline(right, { size = o.size or Ui.S.sm, color = o.color or T.tx, weight = o.weight or W.bold }),
	})
end

-- Campo de texto .inp
function Ui.input(value: string, placeholder: string, onCommit: (string) -> (), opts: { [string]: any }?): TextBox
	local o = opts or {}
	local box = new("TextBox", {
		Name = o.name or "Campo",
		Text = value,
		PlaceholderText = placeholder,
		PlaceholderColor3 = T.mut2,
		ClearTextOnFocus = false,
		TextSize = o.size or 15,
		Weight = W.med,
		BackgroundColor3 = T.input,
		BackgroundTransparency = 0,
		Size = UDim2.new(o.width and 0 or 1, o.width or 0, 0, o.height or 44),
		Corner = 10,
		Stroke = o.invalid and T.re or T.line,
		Pad = { 0, 12 },
		TextXAlignment = Enum.TextXAlignment.Left,
		RichText = false,
	})
	local stroke = box:FindFirstChildOfClass("UIStroke") :: UIStroke
	box.Focused:Connect(function()
		stroke.Color = T.vi
	end)
	box.FocusLost:Connect(function(_enter: boolean)
		stroke.Color = o.invalid and T.re or T.line
		onCommit(box.Text)
	end)
	if o.onChange then
		box:GetPropertyChangedSignal("Text"):Connect(function()
			o.onChange(box.Text)
		end)
	end
	return box
end

-- Ícono de línea (Icons) o, si no existe, un símbolo de texto.
function Ui.icon(name: string, size: number?, color: Color3?): Frame
	return Icons.make(name, size or 18, color or T.tx)
end
Ui.recolorIcon = Icons.recolor

-- Ícono dentro de un cuadrado de color (las «.ico» de la V3).
function Ui.ico(name: string, color: Color3, bg: Color3, size: number?): Frame
	local s = size or 32
	local box = new("Frame", {
		Name = "Ico",
		BackgroundColor3 = bg,
		BackgroundTransparency = 0,
		Size = UDim2.fromOffset(s, s),
		Corner = math.floor(s * 0.28),
	})
	local ic = Icons.make(name, math.floor(s * 0.56), color)
	ic.AnchorPoint = Vector2.new(0.5, 0.5)
	ic.Position = UDim2.fromScale(0.5, 0.5)
	ic.Parent = box
	return box
end

local LIGHT_BRANDS = { ["#E8ECF2"] = true, ["#F7C95C"] = true, ["#42E58D"] = true }

-- Logotipo de la empresa: ícono elegido sobre el color de marca (logoSvg de la V3).
function Ui.logo(company: any, size: number?): Frame
	local s = size or 32
	local box = new("Frame", {
		Name = "Logo",
		BackgroundColor3 = Color3.fromHex(company.color),
		BackgroundTransparency = 0,
		Size = UDim2.fromOffset(s, s),
		Corner = math.floor(s * 0.28),
	})
	local name = "logo_" .. tostring(company.logo or "pico")
	local ic = Icons.make(Icons.has(name) and name or "logo_pico", math.floor(s * 0.6), LIGHT_BRANDS[company.color] and T.dark or hex("#FFFFFF"), 2.2)
	ic.AnchorPoint = Vector2.new(0.5, 0.5)
	ic.Position = UDim2.fromScale(0.5, 0.5)
	ic.Parent = box
	return box
end

-- Miniatura reconocible de un vehículo: su modelo provisional en un ViewportFrame.
function Ui.carThumb(spec: any, w: number?, h: number?): ViewportFrame
	local vf = new("ViewportFrame", {
		Name = "Miniatura",
		Size = UDim2.fromOffset(w or 72, h or 44),
		BackgroundColor3 = hex("#1A1F2B"),
		BackgroundTransparency = 0,
		Corner = 8,
		Ambient = hex("#9CA3B5"),
		LightColor = hex("#FFF1DC"),
		LightDirection = Vector3.new(-0.5, -1, -0.6),
	})
	local ok, model = pcall(CarModel.build, spec)
	if ok and model then
		model.Parent = vf
		local cam = Instance.new("Camera")
		cam.FieldOfView = 30
		local ext = CarModel.extent(spec)
		local target = Vector3.new(0, 1.4, 0)
		cam.CFrame = CFrame.lookAt(Vector3.new(ext * 2.4, ext * 0.9, -ext * 2.6), target)
		cam.Parent = vf
		vf.CurrentCamera = cam
	end
	return vf
end

-- Compatibilidad con listas antiguas: ahora es una miniatura 3D.
function Ui.paintChip(spec: any, w: number?, h: number?): ViewportFrame
	return Ui.carThumb(spec, w and math.max(w, 56) or 64, h and math.max(h, 34) or 38)
end

Ui.reduceMotion = false
function Ui.fadeIn(obj: GuiObject)
	if Ui.reduceMotion then
		return
	end
	local scale = Instance.new("UIScale")
	scale.Scale = 0.98
	scale.Parent = obj
	TweenService:Create(scale, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

return Ui
