--!strict
-- Contenedor de paneles de gestión (.sheet de la V3): encabezado + columna principal + columna lateral.
-- En tablet y celular la columna lateral pasa debajo de la principal, en un solo desplazamiento.

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local Hud = require(script.Parent.ScreenHud)
local T = Ui.T
local W = Ui.W

local Sheet = {}

-- Pestañas (.tabs/.tab)
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
		local b = Ui.new("TextButton", {
			Name = "Pestana_" .. t[1],
			Text = t[2] .. ((t[3] and t[3] ~= 0 and t[3] ~= "") and ("  <font color=\"#C4BDFF\">" .. tostring(t[3]) .. "</font>") or ""),
			TextSize = 14,
			Weight = W.semi,
			TextColor3 = on and T.tx or T.mut,
			Size = UDim2.fromOffset(0, 44),
			AutomaticSize = Enum.AutomaticSize.X,
			TextXAlignment = Enum.TextXAlignment.Center,
		}, {
			on and Ui.new("Frame", {
				BackgroundColor3 = T.vi,
				BackgroundTransparency = 0,
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.fromScale(0, 1),
				Size = UDim2.new(1, 0, 0, 2),
			}) or nil,
		})
		b.Activated:Connect(function()
			App.ui.tabs[key] = t[1]
			App.forceRender()
		end)
		b.Parent = row
	end
	local wrap = Ui.col({ row, Ui.hr() }, 0)
	return wrap, current
end

-- Fila de búsqueda (TextBox que conserva lo escrito entre reconstrucciones).
function Sheet.search(key: string, placeholder: string): TextBox
	local box = Ui.input(App.ui.filters[key] or "", placeholder, function(text: string)
		if App.ui.filters[key] ~= text then
			App.ui.filters[key] = text
			App.forceRender()
		end
	end, { width = App.isPhone() and 200 or 280, height = 38 })
	return box
end

-- Selector compacto de filtro: cicla entre opciones con un botón (evita listas desplegables).
function Sheet.filter(key: string, label: string, options: { any }, default: string): TextButton
	local cur = App.ui.filters[key] or default
	local curLabel = options[1][2]
	local idx = 1
	for i, o in options do
		if o[1] == cur then
			curLabel, idx = o[2], i
		end
	end
	return Ui.button(label .. ": " .. curLabel, "default", function()
		local nextOpt = options[(idx % #options) + 1]
		App.ui.filters[key] = nextOpt[1]
		App.forceRender()
	end, { small = true, name = "Filtro_" .. key })
end

function Sheet.matches(key: string, ...: any): boolean
	local q = string.lower(App.ui.filters[key] or "")
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
	local narrow = App.isNarrow()
	local phone = App.isPhone()
	local top = Hud.top()
	local sheet = Ui.new("Frame", {
		Name = "Panel_" .. route,
		Position = UDim2.fromOffset(phone and 0 or 14, top + (phone and 0 or 10)),
		Size = UDim2.new(1, phone and 0 or -28, 1, -(top + (phone and 0 or 24))),
		BackgroundColor3 = Color3.fromHex("#090B10"),
		BackgroundTransparency = 0.04,
		Corner = phone and 0 or 16,
		Stroke = Color3.fromHex("#262A35"),
		ClipsDescendants = true,
		Parent = parent,
	})
	Ui.fadeIn(sheet)

	local headChildren: { Instance? } = {
		Ui.ico(screen.icon, screen.color, screen.bg, 32),
		Ui.inline(screen.title, { size = phone and 17 or Ui.S.h1, weight = W.bold }),
	}
	if not phone then
		for _, chip in screen.head(g) do
			table.insert(headChildren, chip)
		end
	end
	table.insert(headChildren, Ui.spacer())
	table.insert(headChildren, Ui.button("", "default", function()
		App.openDialog("help", { screen = route })
	end, { small = true, width = 36, icon = "help", name = "Ayuda" }))
	table.insert(headChildren, Ui.button("", "default", function()
		App.go("juego")
	end, { small = true, width = 36, icon = "x", name = "Cerrar" }))
	local headH = phone and 52 or 62
	Ui.row(headChildren, 12, { Name = "Encabezado", Size = UDim2.new(1, 0, 0, headH), AutomaticSize = Enum.AutomaticSize.None, Pad = { 0, phone and 10 or 18 }, Parent = sheet })
	Ui.new("Frame", { BackgroundColor3 = Color3.fromHex("#1F222B"), BackgroundTransparency = 0, Size = UDim2.new(1, 0, 0, 1), Position = UDim2.fromOffset(0, headH), Parent = sheet })

	local pad = phone and 10 or 18
	local body = Ui.new("Frame", {
		Name = "Cuerpo",
		Position = UDim2.fromOffset(pad, headH + 12),
		Size = UDim2.new(1, -pad * 2, 1, -(headH + 24)),
		Parent = sheet,
	})
	local tabKey = tostring(App.ui.tabs[route] or "")
	if narrow then
		local main = Ui.scroll({}, { name = "Principal", gap = 14 })
		main.Parent = body
		App.keepScroll(main, route .. ":narrow:" .. tabKey)
		if phone then
			local chips = screen.head(g)
			if #chips > 0 then
				Ui.row(chips, 6, { wrap = true }).Parent = main
			end
		end
		local mainCol = Ui.col({}, 14, { Name = "ColPrincipal" })
		mainCol.Parent = main
		local sideCol = Ui.col({}, 14, { Name = "ColLateral" })
		sideCol.Parent = main
		screen.build(mainCol, sideCol)
	else
		local sideW = math.min(400, App.vw * (App.layout == "desktop" and 0.3 or 0.32))
		local main = Ui.scroll({}, { name = "Principal", Size = UDim2.new(1, -(sideW + 16), 1, 0), gap = 14 })
		main.Parent = body
		App.keepScroll(main, route .. ":main:" .. tabKey)
		local side = Ui.scroll({}, { name = "Lateral", Size = UDim2.new(0, sideW, 1, 0), Position = UDim2.new(1, -sideW, 0, 0), gap = 14 })
		side.Parent = body
		App.keepScroll(side, route .. ":side")
		screen.build(main, side)
	end
end

return Sheet
