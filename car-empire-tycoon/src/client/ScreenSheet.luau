--!strict
-- Contenedor de paneles de gestión (.sheet de la V3): encabezado + columna principal + columna lateral.
-- En tablet y celular la columna lateral pasa debajo de la principal, en un solo desplazamiento.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Util = require(Shared.Util)
local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local Hud = require(script.Parent.ScreenHud)
local T = Ui.T
local W = Ui.W

local Sheet = {}

-- Pestañas (.tabs/.tab): subrayado violeta en la elegida y contador como chip violeta.
function Sheet.tabs(key: string, list: { any }, default: string): (Frame, string)
	local current = App.ui.tabs[key] or default
	local row = Ui.new("ScrollingFrame", {
		Name = "Pestanas",
		Size = UDim2.new(1, 0, 0, 44),
		List = { dir = "H", gap = 22, v = "C" },
		ScrollingDirection = Enum.ScrollingDirection.X,
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollBarThickness = 0,
	})
	for _, t in list do
		local on = current == t[1]
		local badge = t[3]
		local b = Ui.new("TextButton", {
			Name = "Pestana_" .. t[1],
			Text = "",
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(0, 44),
			AutomaticSize = Enum.AutomaticSize.X,
		}, {
			Ui.new("Frame", { Name = "Rotulo", Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, Pad = { 0, 2 }, List = { dir = "H", gap = 4, v = "C" } }, {
				Ui.inline(t[2], { size = 15, weight = W.semi, color = on and T.tx or T.mut }),
				(badge ~= nil and badge ~= 0 and badge ~= "") and Ui.chip(tostring(badge), "cv") or nil,
			}),
			on and Ui.new("Frame", { Name = "Subrayado", BackgroundColor3 = T.vi, BackgroundTransparency = 0, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 2), ZIndex = 2 }) or nil,
		})
		b.Activated:Connect(function()
			App.ui.tabs[key] = t[1]
			App.forceRender()
		end)
		b.Parent = row
	end
	local wrap = Ui.new("Frame", { Name = "Tabs", Size = UDim2.new(1, 0, 0, 44), BackgroundTransparency = 1 }, {
		Ui.new("Frame", { Name = "Linea", BackgroundColor3 = T.line2, BackgroundTransparency = 0, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 1) }),
		row,
	})
	return wrap, current
end

-- Búsqueda (<input type=search> con lupa): conserva lo escrito entre reconstrucciones.
function Sheet.search(key: string, placeholder: string): Frame
	local box = Ui.input(App.ui.filters[key] or "", placeholder, function(text: string)
		if App.ui.filters[key] ~= text then
			App.ui.filters[key] = text
			App.forceRender()
		end
	end, { height = 44, name = "Buscar_" .. key, flex = true })
	local f = Ui.row({ Ui.icon("search", 16, T.mut), box }, 10, { Name = "Busqueda", Size = UDim2.new(0, App.isPhone() and math.max(180, App.vw - 60) or 360, 0, 0) })
	return f
end

-- Filtro con lista desplegable (selectF de la V3).
function Sheet.filter(key: string, label: string, options: { any }, default: string): Frame
	local cur = App.ui.filters[key] or default
	return Ui.selectF(label, cur, options, function(v: any)
		App.ui.filters[key] = v
		App.forceRender()
	end, { name = "Filtro_" .. key })
end

function Sheet.value(key: string, default: any): any
	return App.ui.filters[key] or default
end

function Sheet.matches(key: string, ...: any): boolean
	local q = string.lower(Util.trim(App.ui.filters[key] or ""))
	if q == "" then
		return true
	end
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		if v and string.find(string.lower(tostring(v)), q, 1, true) then
			return true
		end
	end
	return false
end

function Sheet.build(parent: Instance, route: string)
	local screen = App.screens[route]
	local g = App.g
	local narrow = App.isPhone()
	local phone = App.isPhone()
	local top = Hud.top()
	local sheet = Ui.new("Frame", {
		Name = "Panel_" .. route,
		Position = UDim2.fromOffset(phone and 0 or 14, top + (phone and 0 or 10)),
		Size = UDim2.new(1, phone and 0 or -28, 1, -(top + (phone and 0 or 24))),
		BackgroundColor3 = Color3.fromHex("#090B10"),
		BackgroundTransparency = 0.04,
		Corner = phone and 0 or 16,
		Stroke = phone and nil or T.hudLine,
		ClipsDescendants = true,
		Parent = parent,
	})
	if not Ui.reduceMotion then
		Ui.fadeIn(sheet)
	end

	local headChildren: { Instance? } = {
		Ui.ico(screen.icon or "box", T.tx, Color3.new(1, 1, 1), 32, { alpha = 0.06, iconSize = 18 }),
		Ui.grow(Ui.inline(screen.title, { size = phone and 17 or Ui.S.h1, weight = W.bold, name = "Titulo" })),
	}
	-- En celulares angostos los chips del encabezado no entran junto al título: se omiten (los mismos
	-- datos están dentro de la pantalla).
	if screen.head and not App.narrowPhone then
		for _, chip in screen.head(g) do
			table.insert(headChildren, chip)
		end
	end
	table.insert(headChildren, Ui.button("", "default", function()
		App.openDialog("help", { screen = route })
	end, { small = true, icon = "help", iconSize = 16, name = "Ayuda" }))
	table.insert(headChildren, Ui.button(phone and "" or "Cerrar", "default", function()
		App.go("juego")
	end, { small = true, icon = "x", iconSize = 16, kbd = (not phone) and "Esc" or nil, name = "Cerrar" }))
	local head = Ui.row(headChildren, phone and 8 or 12, { Name = "Encabezado", Pad = phone and { 10, 12 } or { 14, 18 }, wrap = true })
	head.Parent = sheet
	Ui.new("Frame", { Name = "BordeEncabezado", BackgroundColor3 = T.sep, BackgroundTransparency = 0, Size = UDim2.new(1, 0, 0, 1), Parent = sheet })
	local holder = Ui.new("Frame", { Name = "Contenido", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Parent = sheet })
	local headH = phone and 56 or 65
	-- El encabezado puede envolver chips en pantallas chicas: el cuerpo se acomoda a su alto real.
	local function place()
		local h = math.max(headH, head.AbsoluteSize.Y)
		local border = sheet:FindFirstChild("BordeEncabezado") :: Frame
		border.Position = UDim2.fromOffset(0, h)
		holder.Position = UDim2.fromOffset(0, h + 1)
		holder.Size = UDim2.new(1, 0, 1, -(h + 1))
	end
	place()
	head:GetPropertyChangedSignal("AbsoluteSize"):Connect(place)

	local tabKey = tostring(App.ui.tabs[route] or "")
	if narrow or screen.noSide then
		local main = Ui.scroll({}, { name = "Principal", gap = 14, pad = phone and 12 or { 16, 18 } })
		main.Parent = holder
		App.keepScroll(main, route .. ":main:" .. tabKey)
		local mainCol = Ui.col({}, 14, { Name = "ColPrincipal" })
		mainCol.Parent = main
		local sideCol = Ui.col({}, 14, { Name = "ColLateral" })
		sideCol.Parent = main
		screen.build(mainCol, sideCol)
	else
		local sideW = App.layout == "tablet" and 340 or 400
		local main = Ui.scroll({}, { name = "Principal", Position = UDim2.fromOffset(18, 16), Size = UDim2.new(1, -(sideW + 16 + 36), 1, -32), gap = 14, pad = { 0, 4, 2, 0 } })
		main.Parent = holder
		App.keepScroll(main, route .. ":main:" .. tabKey)
		local side = Ui.scroll({}, { name = "Lateral", Size = UDim2.new(0, sideW, 1, -32), Position = UDim2.new(1, -(sideW + 18), 0, 16), gap = 14, pad = { 0, 4, 2, 0 } })
		side.Parent = holder
		App.keepScroll(side, route .. ":side")
		screen.build(main, side)
	end
end

return Sheet
