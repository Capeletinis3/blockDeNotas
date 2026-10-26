--!strict
--[[
	Componentes nativos de Roblox que reproducen las clases de la V3 (style.css):
	.btn (.p .g .d .q .s .i) · kbd · .chip (cg cy cv cb cr cn) · .card / .card2 · .kv · .note (y r b g) ·
	.opt · .inp · .fl · .lbl · .tg · .sw · .bar · .line · .empty · .ico · hr, más los controles que el
	navegador da hechos: lista desplegable (<select>) y deslizador (<input type=range>).

	Medidas: la V3 usa 15 px de base; rem → px redondeado (.xs 11, .sm 12, .lbl 11, .btn 14, .btn.s 13).
	Colores con transparencia (rgba) → BackgroundColor3 + BackgroundTransparency, igual que el CSS.
	Ui.textScale (Configuración › Tamaño del texto) agranda solo los textos, como la escala de rem.
]]

local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local CarModel = require(Shared.CarModel)
local Icons = require(script.Parent.Icons)

local Ui = {}

local function hex(h: string): Color3
	return Color3.fromHex(h)
end
Ui.hex = hex

-- Tokens de :root de la V3
Ui.T = {
	bg = hex("#080A0F"),
	p1 = hex("#111319"),
	p2 = hex("#171A21"),
	p3 = hex("#1D2029"),
	line = hex("#292D38"),
	line2 = hex("#23262F"),
	line3 = hex("#20232C"),
	input = hex("#0C0E13"),
	panel = hex("#0E1016"),
	tx = hex("#F5F7FA"),
	tx2 = hex("#C3C8D2"),
	mut = hex("#A3AAB8"),
	mut2 = hex("#7D8493"),
	vi = hex("#7667FF"),
	vi2 = hex("#B3AAFF"),
	vi3 = hex("#C4BDFF"),
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
	disabledLine = hex("#22252E"),
	btnLine = hex("#333847"),
	hudLine = hex("#262A35"),
	sep = hex("#1F222B"),
}
local T = Ui.T

-- Tamaños (px) de la V3 con base de 15 px.
Ui.S = { base = 15, sm = 12, xs = 11, lbl = 11, chip = 11, btn = 14, btnS = 13, opt = 13, note = 13, fl = 12, inp = 14, line = 14, kvb = 15, h1 = 20, h2 = 19, h3 = 17 }
Ui.textScale = 1

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
	  Alpha = opacidad del fondo (0–1, como rgba) · Flex = "fill" | número (crece en una fila)
]]
local orderCounter = 0
local SPECIAL = { Corner = true, Stroke = true, Pad = true, List = true, Click = true, Weight = true, Hover = true, Parent = true, Alpha = true, Flex = true }
function Ui.new(className: string, props: { [string]: any }?, children: { Instance? }?): any
	local inst = Instance.new(className)
	local p = props or {}
	local isText = inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox")
	if inst:IsA("GuiObject") then
		(inst :: any).BorderSizePixel = 0
		orderCounter += 1;
		(inst :: any).LayoutOrder = orderCounter
	end
	if isText then
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
	for k, v in p do
		if not SPECIAL[k] then
			(inst :: any)[k] = v
		end
	end
	if p.Alpha ~= nil then
		(inst :: any).BackgroundTransparency = 1 - p.Alpha
	end
	if isText then
		(inst :: any).TextSize = math.floor((inst :: any).TextSize * Ui.textScale + 0.5)
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
		elseif k == "Flex" then
			local f = Instance.new("UIFlexItem")
			if v == "fill" then
				f.FlexMode = Enum.UIFlexMode.Fill
			else
				f.FlexMode = Enum.UIFlexMode.Grow
				f.GrowRatio = v
			end
			f.Parent = inst
		elseif k == "Click" then
			(inst :: any).Activated:Connect(v)
		elseif k == "Hover" then
			local g = inst :: any
			local normal, normalT = g.BackgroundColor3, g.BackgroundTransparency
			g.MouseEnter:Connect(function()
				if g:GetAttribute("disabled") ~= true then
					g.BackgroundColor3 = v
					g.BackgroundTransparency = 0
				end
			end)
			g.MouseLeave:Connect(function()
				if g:GetAttribute("disabled") ~= true then
					g.BackgroundColor3 = normal
					g.BackgroundTransparency = normalT
				end
			end)
		end
	end
	if children then
		-- El orden en la lista es el orden visual (como en el HTML), sin importar cuándo se creó cada hijo.
		for _, c in children do
			if c then
				if c:IsA("GuiObject") then
					orderCounter += 1;
					(c :: any).LayoutOrder = orderCounter
				end
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
-- Párrafo: ocupa el ancho disponible y crece en alto.
function Ui.text(text: string, opts: { [string]: any }?): TextLabel
	local o = opts or {}
	return new("TextLabel", {
		Text = text,
		TextSize = o.size or Ui.S.base,
		TextColor3 = o.color or T.tx,
		Weight = o.weight or W.med,
		TextWrapped = o.wrap ~= false,
		TextTransparency = o.transparency or 0,
		Size = o.width and UDim2.new(0, o.width, 0, 0) or UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextXAlignment = o.align == "R" and Enum.TextXAlignment.Right or (o.align == "C" and Enum.TextXAlignment.Center) or Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		LineHeight = o.lineHeight or 1.2,
		Name = o.name or "Texto",
	})
end

-- Texto de una línea con ancho automático (para filas).
function Ui.inline(text: string, opts: { [string]: any }?): TextLabel
	local o = opts or {}
	return new("TextLabel", {
		Text = text,
		TextSize = o.size or Ui.S.base,
		TextColor3 = o.color or T.tx,
		Weight = o.weight or W.med,
		TextWrapped = false,
		TextTransparency = o.transparency or 0,
		Size = UDim2.new(0, o.width or 0, 0, o.height or 0),
		AutomaticSize = (o.width and o.height) and Enum.AutomaticSize.None or (o.width and Enum.AutomaticSize.Y) or (o.height and Enum.AutomaticSize.X) or Enum.AutomaticSize.XY,
		TextXAlignment = o.align == "R" and Enum.TextXAlignment.Right or (o.align == "C" and Enum.TextXAlignment.Center) or Enum.TextXAlignment.Left,
		TextTruncate = o.truncate and Enum.TextTruncate.AtEnd or Enum.TextTruncate.None,
		Name = o.name or "Texto",
	})
end

-- string.upper solo cambia letras ASCII; las vocales con tilde y la ñ se pasan aparte.
local UPPER_ES = { ["á"] = "Á", ["é"] = "É", ["í"] = "Í", ["ó"] = "Ó", ["ú"] = "Ú", ["ü"] = "Ü", ["ñ"] = "Ñ" }
function Ui.upper(text: string): string
	local out = string.upper(text)
	for lo, up in UPPER_ES do
		out = string.gsub(out, lo, up)
	end
	return out
end

-- .lbl: mayúsculas chicas en negrita.
function Ui.lbl(text: string, color: Color3?, size: number?): TextLabel
	return Ui.inline(Ui.upper(text), { size = size or Ui.S.lbl, color = color or T.mut, weight = W.bold, name = "Lbl" })
end

-- .fl: etiqueta de campo.
function Ui.fl(text: string): TextLabel
	return Ui.inline(text, { size = Ui.S.fl, color = T.tx2, weight = W.semi, name = "Fl" })
end

-- .why: motivo de un botón deshabilitado (amarillo).
function Ui.why(text: string): TextLabel
	return Ui.text(text, { size = 12, color = T.ye, weight = W.semi, name = "Why" })
end

-- kbd: tecla. En un botón .p va invertida (fondo oscuro).
function Ui.kbd(text: string, onLight: boolean?): Frame
	local f = new("Frame", {
		Name = "Tecla",
		Size = UDim2.fromOffset(0, 18),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = T.dark,
		BackgroundTransparency = onLight and 0 or 1,
		Corner = 5,
		Stroke = onLight and T.dark or hex("#3D4250"),
		Pad = { 0, 6 },
	}, {
		new("TextLabel", {
			Text = text,
			TextSize = 10,
			Weight = W.semi,
			FontFace = Font.new("rbxasset://fonts/families/RobotoMono.json", Enum.FontWeight.SemiBold),
			TextColor3 = onLight and T.tx or T.mut,
			Size = UDim2.fromScale(0, 1),
			AutomaticSize = Enum.AutomaticSize.X,
			TextXAlignment = Enum.TextXAlignment.Center,
		}),
	})
	f:SetAttribute("kbd", true)
	return f
end
Ui.showKeys = true

-- Contenedores ------------------------------------------------------------------------
function Ui.col(children: { Instance? }, gap: number?, props: { [string]: any }?): Frame
	local p = props or {}
	local base = {
		Size = p.Size or UDim2.new(1, 0, 0, 0),
		AutomaticSize = p.AutomaticSize or Enum.AutomaticSize.Y,
		List = { dir = "V", gap = gap or 10, h = p.h, v = p.v },
	}
	for k, v in p do
		if k ~= "h" and k ~= "v" then
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

-- Elemento que ocupa el espacio libre de una fila (.grow).
function Ui.grow(child: Instance?, props: { [string]: any }?): Frame
	local f = new("Frame", props or { Size = UDim2.new(0, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, { child })
	if child and child:IsA("GuiObject") and not props then
		-- El hijo ocupa todo el ancho del contenedor flexible.
		local c = child :: any
		if c.Size.X.Scale == 0 and c.AutomaticSize ~= Enum.AutomaticSize.XY then
			c.Size = UDim2.new(1, 0, c.Size.Y.Scale, c.Size.Y.Offset)
		elseif c:IsA("TextLabel") and c.AutomaticSize == Enum.AutomaticSize.XY and c.TextTruncate == Enum.TextTruncate.None then
			-- Como .grow en la V3: si falta lugar, el texto pasa a la línea siguiente en vez de desbordarse.
			c.Size = UDim2.new(1, 0, 0, 0)
			c.AutomaticSize = Enum.AutomaticSize.Y
			c.TextWrapped = true
		end
	end
	local flex = Instance.new("UIFlexItem")
	flex.FlexMode = Enum.UIFlexMode.Fill
	flex.Parent = f
	return f
end

function Ui.spacer(): Frame
	return Ui.grow(nil, { Size = UDim2.new(0, 0, 0, 1) })
end

-- .card2 (por defecto) y .card: tarjetas con borde.
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
		List = { dir = p.dir or "V", gap = p.gap or 8, v = p.v, h = p.h, wrap = p.wrap },
		Name = p.name or "Tarjeta",
		ClipsDescendants = p.clip,
	}
	return new("Frame", base, children)
end
function Ui.card1(children: { Instance? }, props: { [string]: any }?): Frame
	local p = table.clone(props or {})
	p.bg = p.bg or T.p1
	p.stroke = p.stroke or T.line
	p.radius = p.radius or 12
	return Ui.card(children, p)
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

-- hr
function Ui.hr(color: Color3?): Frame
	return new("Frame", { Name = "Hr", Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = color or T.line2, BackgroundTransparency = 0 })
end

-- Grilla de columnas iguales (.grid2/.grid3/.grid4) con filas de alto automático.
Ui.gridTwo = false
function Ui.grid(children: { Instance? }, columns: number, _cellHeight: number?, gap: number?): Frame
	local g = gap or 10
	if Ui.gridTwo and (columns == 3 or columns == 4) then
		columns = 2
	end
	local wrap = new("Frame", { Name = "Grilla", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, List = { dir = "V", gap = g } })
	local list: { Instance } = {}
	for _, c in children do
		if c then
			table.insert(list, c)
		end
	end
	local i = 1
	while i <= #list do
		local row = new("Frame", { Name = "Fila", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, List = { dir = "H", gap = g }, Parent = wrap })
		local cells = {}
		for k = 0, columns - 1 do
			local c = list[i + k]
			local cell = new("Frame", { Name = "Celda", Size = UDim2.new(1 / columns, -g * (columns - 1) / columns, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = row })
			if c then
				local gc = c :: any
				if gc:IsA("GuiObject") then
					gc.Size = UDim2.new(1, 0, gc.Size.Y.Scale, gc.Size.Y.Offset)
				end
				c.Parent = cell
				table.insert(cells, gc)
			end
		end
		-- Como en CSS grid, las celdas de una fila igualan su alto.
		row:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			local h = row.AbsoluteSize.Y
			for _, gc in cells do
				if gc.Parent and gc.AbsoluteSize.Y < h - 0.5 and gc.AutomaticSize == Enum.AutomaticSize.Y then
					gc.Size = UDim2.new(1, 0, 0, h)
				end
			end
		end)
		i += columns
	end
	return wrap
end

-- Botones .btn -----------------------------------------------------------------------------
local VARIANTS = {
	default = { bg = T.p2, a = 1, fg = T.tx, line = T.btnLine, la = 1, hover = hex("#1F232C"), hline = hex("#454B5C") },
	p = { bg = T.tx, a = 1, fg = T.dark, line = T.tx, la = 1, hover = hex("#FFFFFF"), hline = hex("#FFFFFF") },
	g = { bg = T.gr, a = 1, fg = hex("#05230F"), line = T.gr, la = 1, hover = hex("#5BF0A0"), hline = hex("#5BF0A0") },
	d = { bg = T.re, a = 0.1, fg = T.re2, line = T.re, la = 0.5, hover = hex("#3A1C21"), hline = T.re },
	q = { bg = T.tx, a = 0, fg = T.mut, line = T.tx, la = 0, hover = hex("#1A1D24"), hline = hex("#1A1D24"), hfg = T.tx },
}
Ui.VARIANTS = VARIANTS

local function paintButton(b: TextButton, hovering: boolean?)
	local v = VARIANTS[b:GetAttribute("kind") or "default"] or VARIANTS.default
	local enabled = b:GetAttribute("disabled") ~= true and b:GetAttribute("busy") ~= true
	local fgOverride = b:GetAttribute("fg")
	local fg = enabled and ((hovering and v.hfg) or (fgOverride and hex(fgOverride)) or v.fg) or T.disabledTx
	if enabled then
		b.BackgroundColor3 = hovering and v.hover or v.bg
		b.BackgroundTransparency = hovering and 0 or 1 - v.a
	else
		b.BackgroundColor3 = T.disabledBg
		b.BackgroundTransparency = 0
	end
	local stroke = b:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = enabled and (hovering and v.hline or v.line) or T.disabledLine
		stroke.Transparency = enabled and (hovering and 0 or 1 - v.la) or 0
	end
	for _, d in b:GetChildren() do
		if d:IsA("TextLabel") then
			d.TextColor3 = fg
		elseif d.Name == "Icono" and Ui.recolorIcon then
			Ui.recolorIcon(d, fg)
		end
	end
end

--[[
	Botón .btn: Ui.button(texto, tipo, alHacerClic, opciones)
	tipo: "default" | "p" | "g" | "d" | "q" · opciones: { small, icon, iconAfter, kbd, disabled, why, width, fill, height,
	name, flex, fg (color de texto, p. ej. «Eliminar» en rojo), align = "L" }
	El estado vive en atributos del propio botón: la apariencia y el clic leen el mismo dato.
]]
function Ui.button(label: string, kind: string?, onClick: (() -> ())?, opts: { [string]: any }?): TextButton
	local o = opts or {}
	local small = o.small == true
	local h = o.height or (small and 36 or 44)
	local iconOnly = label == "" and o.icon ~= nil
	local width = o.width or (iconOnly and h or nil)
	local b = new("TextButton", {
		Name = o.name or "Boton",
		Text = "",
		BackgroundColor3 = T.p2,
		Size = o.fill and UDim2.new(1, 0, 0, h) or UDim2.new(0, width or 0, 0, h),
		AutomaticSize = (o.fill or width) and Enum.AutomaticSize.None or Enum.AutomaticSize.X,
		Corner = o.radius or (small and 8 or 10),
		Stroke = T.btnLine,
		Pad = { 0, iconOnly and 0 or (o.padX or (small and 12 or 16)) },
		AutoButtonColor = false,
		List = { dir = "H", gap = small and 7 or 8, v = "C", h = o.align == "L" and "L" or "C" },
		ClipsDescendants = o.clip,
	})
	-- Respuesta al toque: el botón se achica un poco mientras se mantiene presionado.
	if not o.disabled then
		local press = Instance.new("UIScale")
		press.Name = "Presion"
		press.Parent = b
		local function to(v: number)
			if Ui.reduceMotion then
				return
			end
			TweenService:Create(press, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = v }):Play()
		end
		b.MouseButton1Down:Connect(function()
			to(0.96)
		end)
		b.MouseButton1Up:Connect(function()
			to(1)
		end)
		b.MouseLeave:Connect(function()
			to(1)
		end)
	end
	b:SetAttribute("kind", kind or "default")
	b:SetAttribute("label", label)
	b:SetAttribute("disabled", o.disabled == true)
	b:SetAttribute("why", o.why)
	if o.fg then
		b:SetAttribute("fg", typeof(o.fg) == "Color3" and (o.fg :: Color3):ToHex() or o.fg)
	end
	if o.icon then
		local ic = Icons.make(o.icon, o.iconSize or (small and 15 or 16), T.tx)
		ic.Name = "Icono"
		ic.LayoutOrder = o.iconAfter and 3 or 1
		ic.Parent = b
	end
	if label ~= "" then
		local t = new("TextLabel", {
			Name = "Etiqueta",
			Text = label,
			TextSize = o.size or (small and Ui.S.btnS or Ui.S.btn),
			Weight = o.weight or W.semi,
			Size = UDim2.fromScale(0, 1),
			AutomaticSize = Enum.AutomaticSize.X,
			TextXAlignment = Enum.TextXAlignment.Center,
			LayoutOrder = 2,
		})
		t.Parent = b
	end
	if o.kbd and Ui.showKeys then
		local k = Ui.kbd(o.kbd, kind == "p")
		k.LayoutOrder = 4
		k.Parent = b
	end
	if o.flex then
		local flex = Instance.new("UIFlexItem")
		flex.FlexMode = Enum.UIFlexMode.Grow
		flex.GrowRatio = o.flex
		flex.Parent = b
	end
	paintButton(b)
	b.MouseEnter:Connect(function()
		if b:GetAttribute("disabled") ~= true and b:GetAttribute("busy") ~= true then
			paintButton(b, true)
		end
	end)
	b.MouseLeave:Connect(function()
		paintButton(b)
	end)
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
		if Ui.onClickSound then
			Ui.onClickSound()
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
	local target = b:FindFirstChild("Etiqueta")
	if label ~= "" and target then
		(target :: any).Text = busy and "Procesando…" or label
	end
	paintButton(b)
end

-- Se asignan desde App: aviso con el motivo de un botón deshabilitado y sonido de clic.
Ui.onDisabled = nil :: ((string) -> ())?
Ui.onClickSound = nil :: (() -> ())?

-- .opt (opción seleccionable)
function Ui.opt(label: string, selected: boolean, onClick: () -> (), opts: { [string]: any }?): TextButton
	local o = opts or {}
	local disabled = o.disabled == true
	local b = new("TextButton", {
		Name = o.name or "Opcion",
		Text = label,
		TextSize = o.size or Ui.S.opt,
		Weight = W.semi,
		TextColor3 = selected and T.tx or T.tx2,
		TextTransparency = disabled and 0.55 or 0,
		BackgroundColor3 = selected and T.vi or T.input,
		BackgroundTransparency = selected and 0.8 or 0,
		TextXAlignment = o.align == "L" and Enum.TextXAlignment.Left or Enum.TextXAlignment.Center,
		TextWrapped = (o.fill or o.width) and true or false,
		Size = o.fill and UDim2.new(1, 0, 0, o.height or 40) or UDim2.new(0, o.width or 0, 0, o.height or 40),
		AutomaticSize = (o.fill or o.width) and (o.autoY and Enum.AutomaticSize.Y or Enum.AutomaticSize.None) or Enum.AutomaticSize.X,
		Corner = 9,
		Stroke = selected and { T.vi, 2 } or T.line,
		Pad = o.pad or { 6, 10 },
	})
	if not selected and not disabled then
		b.MouseEnter:Connect(function()
			local s = b:FindFirstChildOfClass("UIStroke")
			if s then
				s.Color = hex("#454B5C")
			end
			b.TextColor3 = T.tx
		end)
		b.MouseLeave:Connect(function()
			local s = b:FindFirstChildOfClass("UIStroke")
			if s then
				s.Color = T.line
			end
			b.TextColor3 = T.tx2
		end)
	end
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

-- Muestra de color .sw (borde interior oscuro de 3 px; elegida: aro claro de 3 px)
function Ui.swatch(color: string, selected: boolean, onClick: () -> (), size: number?): TextButton
	local s = size or 36
	local b = new("TextButton", {
		Name = "Muestra",
		Text = "",
		BackgroundColor3 = T.input,
		BackgroundTransparency = 0,
		Size = UDim2.fromOffset(s, s),
		Corner = s // 2,
		Stroke = selected and { T.tx, 3 } or { T.line, 1 },
	}, {
		new("Frame", { Name = "Color", BackgroundColor3 = Color3.fromHex(color), BackgroundTransparency = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(s - 6, s - 6), Corner = (s - 6) // 2 }),
	})
	b.Activated:Connect(onClick)
	return b
end

-- Interruptor .tg
function Ui.toggle(on: boolean, onClick: () -> (), disabled: boolean?, why: string?): TextButton
	local b = new("TextButton", {
		Name = "Interruptor",
		Text = "",
		Size = UDim2.fromOffset(48, 28),
		BackgroundColor3 = on and T.gr or hex("#2F3340"),
		BackgroundTransparency = disabled and 0.55 or 0,
		Corner = 14,
	}, {
		new("Frame", {
			Name = "Perilla",
			Size = UDim2.fromOffset(20, 20),
			Position = UDim2.fromOffset(on and 24 or 4, 4),
			BackgroundColor3 = hex("#FFFFFF"),
			BackgroundTransparency = disabled and 0.55 or 0,
			Corner = 10,
		}),
	})
	b.Activated:Connect(function()
		if disabled then
			if why and Ui.onDisabled then
				Ui.onDisabled(why)
			end
			return
		end
		onClick()
	end)
	return b
end

-- Chips .chip (cg, cy, cv, cb, cr, cn): fondo rgba como en el CSS.
local CHIPS = {
	cg = { T.gr, 0.13, T.gr },
	cy = { T.ye, 0.14, T.ye },
	cv = { T.vi, 0.22, T.vi3 },
	cb = { T.bl, 0.18, T.bl2 },
	cr = { T.re, 0.14, T.re2 },
	cn = { T.p3, 1, hex("#C3C8D2") },
	co = { T.or_, 0.14, T.or_ },
}
Ui.CHIPS = CHIPS
function Ui.chip(text: string, kind: string?, opts: { [string]: any }?): Frame
	local o = opts or {}
	local c = CHIPS[kind or "cn"] or CHIPS.cn
	local f = new("Frame", {
		Name = o.name or "Chip",
		BackgroundColor3 = c[1],
		Alpha = c[2],
		Size = UDim2.fromOffset(0, o.height or 24),
		AutomaticSize = Enum.AutomaticSize.X,
		Corner = 7,
		Pad = { 0, 9 },
		List = { dir = "H", gap = 5, v = "C" },
	})
	if o.icon then
		Icons.make(o.icon, 11, c[3]).Parent = f
	end
	new("TextLabel", {
		Text = text,
		TextSize = Ui.S.chip,
		Weight = W.bold,
		TextColor3 = o.color or c[3],
		Size = UDim2.fromScale(0, 1),
		AutomaticSize = Enum.AutomaticSize.X,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = f,
	})
	return f
end

-- Barra .bar. Devuelve (contenedor, relleno) para poder actualizar el relleno en vivo.
function Ui.bar(pct: number, color: Color3?, height: number?): (Frame, Frame)
	local fill = new("Frame", {
		Name = "Relleno",
		BackgroundColor3 = color or T.vi,
		BackgroundTransparency = 0,
		Size = UDim2.new(math.clamp(pct, 0, 100) / 100, 0, 1, 0),
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

-- Las barras avanzan con una transición corta (sin animación con «Reducir movimiento»).
function Ui.setBar(fill: Frame, pct: number)
	local target = UDim2.new(math.clamp(pct, 0, 100) / 100, 0, 1, 0)
	if Ui.reduceMotion or not fill.Parent or fill.Size == target then
		fill.Size = target
		return
	end
	TweenService:Create(fill, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = target }):Play()
end

-- Notas .note (y, r, b, g)
local NOTES = {
	y = { T.ye, 0.08, T.ye, 0.35, hex("#F5DC9A"), "warn" },
	r = { T.re, 0.08, T.re, 0.4, hex("#FFB3B7"), "warn" },
	b = { T.bl, 0.08, T.bl, 0.35, hex("#C2D8FF"), "help" },
	g = { T.gr, 0.07, T.gr, 0.35, hex("#B4F3CF"), "check" },
}
function Ui.note(kind: string, text: string, extra: Instance?, icon: string?): Frame
	local n = NOTES[kind] or NOTES.b
	return new("Frame", {
		Name = "Nota",
		BackgroundColor3 = n[1],
		Alpha = n[2],
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Corner = 10,
		Stroke = { n[3], 1, 1 - n[4] },
		Pad = { 10, 12 },
		List = { dir = "H", gap = 10, v = "T" },
	}, {
		Icons.make(icon or n[6], 16, n[5]),
		Ui.grow(Ui.text(text, { size = Ui.S.note, color = n[5], lineHeight = 1.3 }), { Size = UDim2.new(0, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }),
		extra,
	})
end

-- .kv: etiqueta + valor destacado (+ texto chico opcional)
function Ui.kv(label: string, value: string, opts: { [string]: any }?): (Frame, TextLabel)
	local o = opts or {}
	local v = Ui.text(value, { size = o.valueSize or Ui.S.kvb, weight = W.bold, color = o.color or T.tx, name = "Valor" })
	local f = new("Frame", {
		Name = o.name or "KV",
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

-- .line: texto a la izquierda y valor a la derecha, con separador inferior.
function Ui.line(left: string, right: string, opts: { [string]: any }?): Frame
	local o = opts or {}
	local f = new("Frame", {
		Name = "Linea",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Pad = { o.padY or 8, 0 },
		List = { dir = "H", gap = 12, v = "C" },
	}, {
		Ui.grow(Ui.text(left, { size = o.size or Ui.S.line, color = o.leftColor or T.tx, weight = o.leftWeight }), { Size = UDim2.new(0, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }),
		Ui.inline(right, { size = o.size or Ui.S.line, color = o.color or T.tx, weight = o.weight or W.bold }),
	})
	if o.border ~= false then
		return Ui.underline(f)
	end
	return f
end

-- border-bottom: un hijo con posición fija dentro de un UIListLayout se acomodaría como un
-- elemento más, así que la fila va dentro de un marco sin lista que dibuja el borde abajo.
function Ui.underline(item: GuiObject, color: Color3?): Frame
	local outer = new("Frame", { Name = item.Name, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y })
	item.Size = UDim2.new(1, 0, item.Size.Y.Scale, item.Size.Y.Offset)
	item.Parent = outer
	new("Frame", { Name = "Borde", BackgroundColor3 = color or T.line3, BackgroundTransparency = 0, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1, 0, 0, 1), ZIndex = 2, Parent = outer })
	return outer
end
-- Fila «.row.between» simple: texto apagado a la izquierda, valor en negrita a la derecha.
function Ui.between(left: string, right: string, opts: { [string]: any }?): Frame
	local o = opts or {}
	return new("Frame", {
		Name = "Entre",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		List = { dir = "H", gap = 10, v = "C" },
	}, {
		Ui.grow(Ui.text(left, { size = o.size or Ui.S.sm, color = o.leftColor or T.mut, weight = o.leftWeight }), { Size = UDim2.new(0, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }),
		Ui.inline(right, { size = o.valueSize or o.size or Ui.S.sm, color = o.color or T.tx, weight = o.weight or W.bold }),
	})
end

-- .empty: estado vacío con borde (en la V3, punteado) y contenido centrado.
function Ui.empty(icon: string?, text: string, extra: Instance?, opts: { [string]: any }?): Frame
	local o = opts or {}
	return new("Frame", {
		Name = "Vacio",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Corner = 12,
		Stroke = hex("#3A3F4D"),
		Pad = o.pad or 22,
		List = { dir = "V", gap = 8, h = "C" },
	}, {
		icon and Icons.make(icon, 22, T.mut) or nil,
		Ui.text(text, { size = o.size or Ui.S.base, color = T.mut, align = "C" }),
		extra,
	})
end

-- Campo de texto .inp
function Ui.input(value: string, placeholder: string, onCommit: (string) -> (), opts: { [string]: any }?): TextBox
	local o = opts or {}
	local box = new("TextBox", {
		Name = o.name or "Campo",
		Text = value,
		PlaceholderText = placeholder,
		PlaceholderColor3 = hex("#6C7382"),
		ClearTextOnFocus = false,
		TextSize = o.size or Ui.S.inp,
		Weight = W.med,
		BackgroundColor3 = T.input,
		BackgroundTransparency = 0,
		Size = UDim2.new(o.width and 0 or 1, o.width or 0, 0, o.height or 44),
		Corner = 10,
		Stroke = o.invalid and T.re or T.line,
		Pad = { 0, 12 },
		TextXAlignment = Enum.TextXAlignment.Left,
		RichText = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	if o.flex then
		local flex = Instance.new("UIFlexItem")
		flex.FlexMode = Enum.UIFlexMode.Fill
		flex.Parent = box
	end
	local stroke = box:FindFirstChildOfClass("UIStroke") :: UIStroke
	box.Focused:Connect(function()
		stroke.Color = T.vi
		stroke.Thickness = 2
	end)
	box.FocusLost:Connect(function(enter: boolean)
		stroke.Color = o.invalid and T.re or T.line
		stroke.Thickness = 1
		if o.numeric then
			local n = tonumber((string.gsub(box.Text, "[^%d%-%.]", "")))
			if n == nil then
				box.Text = value
				return
			end
		end
		onCommit(box.Text, enter)
	end)
	if o.onChange then
		box:GetPropertyChangedSignal("Text"):Connect(function()
			o.onChange(box.Text)
		end)
	end
	return box
end

-- Lista desplegable (<select class="inp">): botón con el valor elegido; al tocarlo abre las opciones.
-- options = { { valor, texto, deshabilitada? } }
function Ui.select(value: any, options: { any }, onChange: (any) -> (), opts: { [string]: any }?): TextButton
	local o = opts or {}
	local label = ""
	for _, op in options do
		if op[1] == value then
			label = op[2]
		end
	end
	local disabled = o.disabled == true
	local textSize = o.size or (o.small and Ui.S.sm or Ui.S.inp)
	if not (o.fill or o.width) then
		-- Como un <select> nativo: el ancho lo define la opción más larga.
		local widest = 0
		for _, op in options do
			local ok, sz = pcall(function()
				return TextService:GetTextSize(tostring(op[2]), textSize * (Ui.textScale or 1), Enum.Font.BuilderSans, Vector2.new(2000, 200))
			end)
			if ok and sz then
				widest = math.max(widest, math.ceil(sz.X))
			end
		end
		if widest > 0 then
			o = table.clone(o)
			o.width = widest + (o.small and 16 or 22) + 8 + 14 + 4
		end
	end
	local b = new("TextButton", {
		Name = o.name or "Lista",
		Text = "",
		BackgroundColor3 = T.input,
		BackgroundTransparency = 0,
		Size = o.fill and UDim2.new(1, 0, 0, o.height or 44) or UDim2.new(0, o.width or 0, 0, o.height or 44),
		AutomaticSize = (o.fill or o.width) and Enum.AutomaticSize.None or Enum.AutomaticSize.X,
		Corner = o.small and 8 or 10,
		Stroke = T.line,
		Pad = { 0, o.small and 8 or 10, 0, o.small and 8 or 12 },
		List = { dir = "H", gap = 8, v = "C" },
	}, {
		Ui.grow((function()
			local lab = Ui.inline(label, { size = textSize, color = disabled and T.disabledTx or T.tx, truncate = true })
			lab.Size = UDim2.new(1, 0, 1, 0)
			lab.AutomaticSize = Enum.AutomaticSize.None
			return lab
		end)(), { Size = UDim2.new(0, 0, 1, 0) }),
		Icons.make("down", 14, disabled and T.disabledTx or T.tx2),
	})
	if not (o.fill or o.width) then
		-- Sin ancho fijo, el texto define el ancho.
		local g = b:FindFirstChild("Frame") :: Frame?
		if g then
			local fl = g:FindFirstChildOfClass("UIFlexItem")
			if fl then
				fl:Destroy()
			end
			g.AutomaticSize = Enum.AutomaticSize.X
			g.Size = UDim2.new(0, 0, 1, 0)
			local lab = g:FindFirstChildOfClass("TextLabel")
			if lab then
				lab.Size = UDim2.new(0, 0, 1, 0)
				lab.AutomaticSize = Enum.AutomaticSize.X
			end
		end
	end
	b.Activated:Connect(function()
		if disabled then
			if o.why and Ui.onDisabled then
				Ui.onDisabled(o.why)
			end
			return
		end
		if Ui.openDropdown then
			Ui.openDropdown(b, options, value, onChange)
		end
	end)
	return b
end
Ui.openDropdown = nil :: ((Instance, { any }, any, (any) -> ()) -> ())?

-- Etiqueta + lista en una fila (<label class="row xs"><span class="mut">…</span><select>)
function Ui.selectF(label: string, value: any, options: { any }, onChange: (any) -> (), opts: { [string]: any }?): Frame
	local o = table.clone(opts or {})
	o.small = true
	o.height = o.height or 36
	o.size = o.size or Ui.S.inp
	return Ui.row({ Ui.inline(label, { size = Ui.S.xs, color = T.mut }), Ui.select(value, options, onChange, o) }, 10, { Size = UDim2.new(0, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.XY })
end

-- Deslizador (<input type=range>): pista de 6 px y perilla. onChange(valor, final)
function Ui.slider(value: number, min: number, max: number, step: number, onChange: (number, boolean) -> (), opts: { [string]: any }?): Frame
	local o = opts or {}
	local accent = o.color or T.vi
	local f = new("Frame", { Name = o.name or "Deslizador", Size = o.width and UDim2.fromOffset(o.width, 28) or UDim2.new(1, 0, 0, 28), BackgroundTransparency = 1, Active = true })
	if o.flex then
		local flex = Instance.new("UIFlexItem")
		flex.FlexMode = Enum.UIFlexMode.Fill
		flex.Parent = f
	end
	local track = new("Frame", { Name = "Pista", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 8, 0.5, 0), Size = UDim2.new(1, -16, 0, 8), BackgroundColor3 = hex("#EFEFEF"), BackgroundTransparency = 0, Corner = 4, Stroke = hex("#B2B2B2"), Parent = f })
	local pct = (math.clamp(value, min, max) - min) / math.max(1e-9, max - min)
	local fill = new("Frame", { Name = "Relleno", Size = UDim2.new(pct, 0, 1, 0), BackgroundColor3 = accent, BackgroundTransparency = 0, Corner = 3, Parent = track })
	local knob = new("Frame", { Name = "Perilla", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(pct, 0, 0.5, 0), Size = UDim2.fromOffset(16, 16), BackgroundColor3 = accent, BackgroundTransparency = 0, Corner = 8, Parent = track })
	local current = value
	local function set(x: number, final: boolean)
		local w = track.AbsoluteSize.X
		if w <= 0 then
			return
		end
		local t = math.clamp((x - track.AbsolutePosition.X) / w, 0, 1)
		local v = min + t * (max - min)
		v = math.floor((v - min) / step + 0.5) * step + min
		v = math.clamp(v, min, max)
		local p = (v - min) / math.max(1e-9, max - min)
		fill.Size = UDim2.new(p, 0, 1, 0)
		knob.Position = UDim2.new(p, 0, 0.5, 0)
		if v ~= current or final then
			current = v
			onChange(v, final)
		end
	end
	local dragging = false
	f.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			Ui.dragging = true
			set(input.Position.X, false)
		end
	end)
	local moveConn = UserInputService.InputChanged:Connect(function(input: InputObject)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			set(input.Position.X, false)
		end
	end)
	local endConn = UserInputService.InputEnded:Connect(function(input: InputObject)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
			dragging = false
			Ui.dragging = false
			set(input.Position.X, true)
		end
	end)
	f.Destroying:Connect(function()
		moveConn:Disconnect()
		endConn:Disconnect()
		if dragging then
			Ui.dragging = false
		end
	end)
	return f
end
Ui.dragging = false

-- Ícono de línea (trazos de la V3).
function Ui.icon(name: string, size: number?, color: Color3?, strokeWidth: number?): Frame
	return Icons.make(name, size or 18, color or T.tx, strokeWidth)
end
Ui.recolorIcon = Icons.recolor

-- .ico: ícono dentro de un cuadrado de color (radio 9 en 32 px).
function Ui.ico(name: string, color: Color3, bg: Color3, size: number?, opts: { [string]: any }?): Frame
	local o = opts or {}
	local s = size or 32
	local box = new("Frame", {
		Name = "Ico",
		BackgroundColor3 = bg,
		BackgroundTransparency = o.alpha and (1 - o.alpha) or 0,
		Size = o.w and UDim2.fromOffset(o.w, o.h or s) or UDim2.fromOffset(s, s),
		Corner = o.radius or math.floor(s * 0.28),
		Stroke = o.stroke,
	})
	local ic = Icons.make(name, o.iconSize or math.floor(s * 0.5), color)
	ic.AnchorPoint = Vector2.new(0.5, 0.5)
	ic.Position = UDim2.fromScale(0.5, 0.5)
	ic.Parent = box
	return box
end

local LIGHT_BRANDS = { ["#E8ECF2"] = true, ["#F7C95C"] = true, ["#42E58D"] = true }

-- Logotipo de la empresa (logoSvg): ícono elegido sobre el color de marca.
function Ui.logo(company: any, size: number?): Frame
	local s = size or 32
	local box = new("Frame", {
		Name = "Logo",
		BackgroundColor3 = Color3.fromHex(company.color),
		BackgroundTransparency = 0,
		Size = UDim2.fromOffset(s, s),
		Corner = 9,
	})
	local name = "logo_" .. tostring(company.logo or "pico")
	local ic = Icons.make(Icons.has(name) and name or "logo_pico", math.floor(s * 0.56), LIGHT_BRANDS[company.color] and T.dark or hex("#FFFFFF"), 2.2)
	ic.AnchorPoint = Vector2.new(0.5, 0.5)
	ic.Position = UDim2.fromScale(0.5, 0.5)
	ic.Parent = box
	return box
end

-- Muestra de pintura de una unidad (la V3 usa un rectángulo con el color o un degradado principal → secundario).
function Ui.paintChip(spec: any, w: number?, h: number?, secondary: boolean?): Frame
	local f = new("Frame", {
		Name = "Pintura",
		BackgroundColor3 = Color3.fromHex(spec.paint.primary),
		BackgroundTransparency = 0,
		Size = UDim2.fromOffset(w or 44, h or 28),
		Corner = (h or 28) <= 18 and 4 or 6,
	})
	if secondary then
		-- linear-gradient(135deg, principal 60 %, secundario): el degradado tiñe un fondo blanco.
		f.BackgroundColor3 = Color3.new(1, 1, 1)
		local g = Instance.new("UIGradient")
		local p, s2 = Color3.fromHex(spec.paint.primary), Color3.fromHex(spec.paint.secondary)
		g.Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, p), ColorSequenceKeypoint.new(0.6, p), ColorSequenceKeypoint.new(1, s2) })
		g.Rotation = 35
		g.Parent = f
	end
	return f
end

-- Miniatura 3D del modelo provisional (detalles y diálogos grandes).
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

Ui.reduceMotion = false
function Ui.fadeIn(obj: GuiObject)
	if Ui.reduceMotion then
		return
	end
	local scale = Instance.new("UIScale")
	scale.Scale = 0.98
	scale.Parent = obj
	TweenService:Create(scale, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

return Ui
