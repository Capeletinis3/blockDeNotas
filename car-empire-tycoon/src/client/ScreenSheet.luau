--!strict
-- Contenedor de paneles de gestión (.sheet de la V3): encabezado + columna principal + columna lateral.

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local Hud = require(script.Parent.ScreenHud)
local T = Ui.T
local W = Ui.W

local Sheet = {}

-- Pestañas (.tabs/.tab)
function Sheet.tabs(key: string, list: { any }, default: string): (Frame, string)
	local current = App.ui.tabs[key] or default
	local row = Ui.new("Frame", {
		Name = "Pestanas",
		Size = UDim2.new(1, 0, 0, 44),
		List = { dir = "H", gap = 22, v = "C" },
	})
	for _, t in list do
		local on = current == t[1]
		local b = Ui.new("TextButton", {
			Text = t[2] .. ((t[3] and t[3] ~= 0) and ("  <font color=\"#C4BDFF\">" .. tostring(t[3]) .. "</font>") or ""),
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

function Sheet.build(parent: Instance, route: string)
	local screen = App.screens[route]
	local g = App.g
	local narrow = App.vw < 1000
	local sheet = Ui.new("Frame", {
		Name = "Panel_" .. route,
		Position = UDim2.fromOffset(14, Hud.TOP + 10),
		Size = UDim2.new(1, -28, 1, -(Hud.TOP + 24)),
		BackgroundColor3 = Color3.fromHex("#090B10"),
		BackgroundTransparency = 0.04,
		Corner = 16,
		Stroke = Color3.fromHex("#262A35"),
		ClipsDescendants = true,
		Parent = parent,
	})
	Ui.fadeIn(sheet)

	local headChildren: { Instance? } = {
		Ui.ico(screen.symbol, screen.color, screen.bg, 32),
		Ui.inline(screen.title, { size = Ui.S.h1, weight = W.bold }),
	}
	for _, chip in screen.head(g) do
		table.insert(headChildren, chip)
	end
	table.insert(headChildren, Ui.spacer())
	local close = Ui.button("✕", "default", function()
		App.go("juego")
	end, { small = true, width = 36 })
	table.insert(headChildren, close)
	Ui.row(headChildren, 12, { Name = "Encabezado", Size = UDim2.new(1, 0, 0, 62), AutomaticSize = Enum.AutomaticSize.None, Pad = { 0, 18 }, Parent = sheet })
	Ui.new("Frame", { BackgroundColor3 = Color3.fromHex("#1F222B"), BackgroundTransparency = 0, Size = UDim2.new(1, 0, 0, 1), Position = UDim2.fromOffset(0, 62), Parent = sheet })

	local body = Ui.new("Frame", {
		Name = "Cuerpo",
		Position = UDim2.fromOffset(18, 78),
		Size = UDim2.new(1, -36, 1, -92),
		Parent = sheet,
	})
	local sideW = narrow and 0 or math.min(400, App.vw * 0.3)
	local main = Ui.scroll({}, { name = "Principal", Size = UDim2.new(1, -(sideW + (narrow and 0 or 16)), 1, 0), gap = 14 })
	main.Parent = body
	App.keepScroll(main, route .. ":main:" .. tostring(App.ui.tabs[route] or ""))
	local side = nil
	if not narrow then
		side = Ui.scroll({}, { name = "Lateral", Size = UDim2.new(0, sideW, 1, 0), Position = UDim2.new(1, -sideW, 0, 0), gap = 14 })
		side.Parent = body
		App.keepScroll(side, route .. ":side")
	end
	screen.build(main, side or main)
end

return Sheet
