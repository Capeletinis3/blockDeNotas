--!strict
--[[
	HUD superior (hud1 + hud2 de la V3) y, en la vista del garaje, las tarjetas laterales
	(objetivo del recorrido, resumen de 7 días, alerta), «En venta» y el botón de próxima acción (.cta).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local T = Ui.T
local W = Ui.W

local Screen = {}

Screen.HUD1 = 56
Screen.HUD2 = 52
Screen.TOP = Screen.HUD1 + Screen.HUD2

-- id, etiqueta, símbolo, color, fondo (NAV de la V3; Mercado, Investigación, Personal y Compañía llegan después)
Screen.NAV = {
	{ "editor", "Diseño", "✎", Color3.fromHex("#B3AAFF"), Color3.fromHex("#211D45") },
	{ "autos", "Mis autos", "🚗", Color3.fromHex("#8DB8FF"), Color3.fromHex("#14233D") },
	{ "fabrica", "Fábrica", "🏭", Color3.fromHex("#FFB36B"), Color3.fromHex("#33241A") },
	{ "ventas", "Ventas", "🏷", Color3.fromHex("#42E58D"), Color3.fromHex("#13301F") },
}

local function counts(g: any): { [string]: any }
	local ready, offers = 0, 0
	for _, u in g.units do
		if u.status == "almacen" then
			ready += 1
		end
	end
	for _, c in g.customers do
		if c.state == "oferta" then
			offers += 1
		end
	end
	return {
		autos = ready > 0 and { ready, Color3.fromHex("#1F4FA0") } or nil,
		fabrica = #g.production.orders > 0 and { #g.production.orders, Color3.fromHex("#7A4A1C") } or nil,
		ventas = offers > 0 and { offers, Color3.fromHex("#1D6A3F") } or nil,
	}
end

function Screen.tutorialStep(g: any): (any, number)
	for i, step in Catalog.TUTORIAL do
		if (g.counters[step.counter] or 0) < 1 then
			return step, i
		end
	end
	return nil, #Catalog.TUTORIAL
end

local function nextAction(g: any): any
	local ed = App.ui.editor
	if #g.designs == 0 then
		return { label = ed and "Continuar diseño" or "Diseñar mi primer auto", sub = ed and "Tenés un proyecto sin guardar" or "Abrí el escritorio de diseño", go = "editor" }
	end
	if ed and ed.dirty then
		return { label = "Continuar diseño", sub = ed.draft.name .. " tiene cambios sin guardar", go = "editor" }
	end
	for _, c in g.customers do
		if c.state == "oferta" then
			return { label = "Abrir concesionario", sub = c.name .. " hizo una oferta", go = "ventas" }
		end
	end
	local ready = 0
	for _, u in g.units do
		if u.status == "almacen" then
			ready += 1
		end
	end
	if ready > 0 then
		return { label = "Enviar autos al salón", sub = ready .. (ready == 1 and " unidad esperando" or " unidades esperando"), go = "autos" }
	end
	if #g.production.orders > 0 then
		return { label = "Ver producción", sub = #g.production.orders .. (#g.production.orders == 1 and " orden en curso" or " órdenes en curso"), go = "fabrica" }
	end
	return { label = "Fabricar un auto", sub = "Elegí uno de tus " .. #g.designs .. " diseños", dialog = "order" }
end

local function topAlert(g: any): any
	for _, o in g.production.orders do
		if o.status == "detenida" then
			return { title = "Producción detenida", text = o.reason, go = "fabrica", icon = "⚠", col = T.re2, bg = Color3.fromHex("#33171A"), border = Color3.fromHex("#7A3A40") }
		end
	end
	local ready = 0
	for _, u in g.units do
		if u.status == "almacen" then
			ready += 1
		end
	end
	if ready > 0 then
		return { title = ready .. (ready > 1 and " vehículos listos" or " vehículo listo"), text = "Esperan en el almacén. Envialos al salón.", go = "autos", icon = "✓", col = T.gr, bg = Color3.fromHex("#14301F"), border = Color3.fromHex("#226043") }
	end
	local offers = 0
	for _, c in g.customers do
		if c.state == "oferta" then
			offers += 1
		end
	end
	if offers > 0 then
		return { title = offers .. (offers > 1 and " clientes con oferta" or " cliente con oferta"), text = "Respondé antes de que se vayan.", go = "ventas", icon = "🏷", col = T.bl2, bg = Color3.fromHex("#142844"), border = Color3.fromHex("#22406E") }
	end
	return nil
end

function Screen.week(g: any): any
	local from = g.time.day - 6
	local units, revenue, cogs = 0, 0, 0
	for _, s in g.sales do
		if s.day >= from then
			units += 1
			revenue += s.price
			cogs += s.cost
		end
	end
	return { units = units, revenue = revenue, cogs = cogs, margin = revenue - cogs }
end

local function res(icon: string, iconColor: Color3, iconBg: Color3, kicker: string, value: string): (Frame, TextLabel, TextLabel)
	local valueLabel = Ui.inline(value, { size = 15, weight = W.bold })
	local kickerLabel = Ui.inline(kicker, { size = 10, color = T.mut, weight = W.bold })
	local f = Ui.new("Frame", {
		Name = "Recurso",
		BackgroundColor3 = T.p1,
		BackgroundTransparency = 0,
		Size = UDim2.fromOffset(0, 42),
		AutomaticSize = Enum.AutomaticSize.X,
		Corner = 10,
		Stroke = Color3.fromHex("#262A35"),
		Pad = { 0, 11 },
		List = { dir = "H", gap = 8, v = "C" },
	}, {
		Ui.ico(icon, iconColor, iconBg, 28),
		Ui.new("Frame", { Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY, List = { dir = "V", gap = 0 } }, { kickerLabel, valueLabel }),
	})
	return f, valueLabel, kickerLabel
end

local function buildHud(parent: Instance, route: string)
	local g = App.g
	local p = App.payload
	-- hud1
	local brand = Ui.new("TextButton", {
		Name = "Marca",
		Text = "",
		BackgroundColor3 = T.p1,
		BackgroundTransparency = 0,
		Size = UDim2.fromOffset(0, 42),
		AutomaticSize = Enum.AutomaticSize.X,
		Corner = 10,
		Stroke = Color3.fromHex("#262A35"),
		Pad = { 0, 12, 0, 5 },
		List = { dir = "H", gap = 10, v = "C" },
	}, {
		Ui.logo(g.company, 30),
		Ui.new("Frame", { Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY, List = { dir = "V", gap = 1 } }, {
			Ui.inline(g.company.name, { size = 14, weight = W.bold }),
			Ui.inline(g.derived.sedeName .. " · Nv. " .. g.level, { size = Ui.S.xs, color = T.mut }),
		}),
	})
	brand.Activated:Connect(function()
		App.go("juego")
	end)

	local dateRes, dateValue, dateKicker = res("📅", T.bl2, Color3.fromHex("#14233D"), "FECHA", Util.gameDate(g.time.day))
	local moneyRes, moneyValue = res("$", T.gr, Color3.fromHex("#13301F"), "DINERO", Util.money(g.money))
	local repRes = res("★", T.ye, Color3.fromHex("#322A14"), "REPUTACIÓN", Util.num(g.reputation, 1) .. " / 5")
	local xpRes = res("▲", T.vi2, Color3.fromHex("#211D45"), "NIVEL " .. g.level, g.xp .. " / " .. g.derived.xpNext .. " XP")
	App.live(function(gg: any)
		dateValue.Text = Util.gameDate(gg.time.day)
		dateKicker.Text = "FECHA · " .. Util.clock(gg.time.minute)
		moneyValue.Text = Util.money(gg.money)
	end)

	local speedGroup = Ui.new("Frame", {
		Name = "Velocidad",
		BackgroundColor3 = T.p1,
		BackgroundTransparency = 0,
		Size = UDim2.fromOffset(0, 42),
		AutomaticSize = Enum.AutomaticSize.X,
		Corner = 10,
		Stroke = Color3.fromHex("#262A35"),
		Pad = 3,
		List = { dir = "H", gap = 2, v = "C" },
	})
	for _, sp in { { 0, "❚❚" }, { 1, "1×" }, { 2, "2×" }, { 4, "4×" } } do
		local on = g.time.speed == sp[1]
		local b = Ui.new("TextButton", {
			Text = sp[2],
			TextSize = 14,
			Weight = W.heavy,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextColor3 = on and (sp[1] == 0 and Color3.fromHex("#1D1503") or T.dark) or T.tx2,
			BackgroundColor3 = on and (sp[1] == 0 and T.ye or T.tx) or T.p1,
			BackgroundTransparency = on and 0 or 1,
			Size = UDim2.fromOffset(42, 36),
			Corner = 7,
		})
		b.Activated:Connect(function()
			App.request("setSpeed", { speed = sp[1] })
		end)
		b.Parent = speedGroup
	end

	local hud1Children: { Instance? } = { brand, App.vw > 1150 and dateRes or nil, moneyRes, App.vw > 1000 and repRes or nil, App.vw > 1300 and xpRes or nil, Ui.spacer() }
	if g.time.speed == 0 and App.vw > 1150 then
		table.insert(hud1Children, Ui.chip("❚❚ Simulación en pausa", "cy"))
	end
	if p.saveMode == "memory" then
		table.insert(hud1Children, Ui.chip("Guardado temporal (Studio)", "cy"))
	end
	table.insert(hud1Children, speedGroup)
	Ui.new("Frame", {
		Name = "Hud1",
		BackgroundColor3 = T.bg,
		BackgroundTransparency = 0.08,
		Size = UDim2.new(1, 0, 0, Screen.HUD1),
		Pad = { 0, 14, 0, 150 }, -- 150 px libres para los botones de Roblox (igual que la V3)
		List = { dir = "H", gap = 8, v = "C" },
		Parent = parent,
	}, hud1Children)
	Ui.new("Frame", {
		Name = "BordeHud1",
		BackgroundColor3 = Color3.fromHex("#1C1F28"),
		BackgroundTransparency = 0,
		Size = UDim2.new(1, 0, 0, 1),
		Position = UDim2.fromOffset(0, Screen.HUD1 - 1),
		Parent = parent,
	})

	-- hud2 (navegación)
	local navCounts = counts(g)
	local function navItem(id: string, label: string, symbol: string, col: Color3, bg: Color3, key: string): TextButton
		local current = route == id
		local cnt = navCounts[id]
		local b = Ui.new("TextButton", {
			Name = "Nav_" .. id,
			Text = "",
			BackgroundColor3 = current and T.tx or T.bg,
			BackgroundTransparency = current and 0 or 1,
			Size = UDim2.fromOffset(0, 42),
			AutomaticSize = Enum.AutomaticSize.X,
			Corner = 10,
			Pad = { 0, 10, 0, 6 },
			List = { dir = "H", gap = 8, v = "C" },
		}, {
			Ui.ico(symbol, col, bg, 28),
			Ui.inline(label, { size = 14, weight = W.semi, color = current and T.dark or Color3.fromHex("#E4E7EC") }),
			cnt and Ui.new("TextLabel", {
				Text = tostring(cnt[1]),
				TextSize = 11,
				Weight = W.heavy,
				TextColor3 = T.tx,
				BackgroundColor3 = cnt[2],
				BackgroundTransparency = 0,
				Size = UDim2.fromOffset(0, 20),
				AutomaticSize = Enum.AutomaticSize.X,
				Corner = 10,
				Pad = { 0, 7 },
				TextXAlignment = Enum.TextXAlignment.Center,
			}) or nil,
			App.vw > 1200 and Ui.new("TextLabel", {
				Text = key,
				TextSize = 11,
				Weight = W.semi,
				TextColor3 = T.mut,
				Size = UDim2.fromOffset(0, 20),
				AutomaticSize = Enum.AutomaticSize.X,
				Corner = 5,
				Stroke = Color3.fromHex("#3D4250"),
				Pad = { 0, 6 },
				TextXAlignment = Enum.TextXAlignment.Center,
			}) or nil,
		})
		b.Activated:Connect(function()
			if route == id and id ~= "juego" then
				App.go("juego")
			else
				App.go(id)
			end
		end)
		return b
	end
	local navChildren: { Instance? } = { navItem("juego", "Sede", "⌂", T.tx, Color3.fromHex("#22252D"), "0") }
	for i, n in Screen.NAV do
		table.insert(navChildren, navItem(n[1], n[2], n[3], n[4], n[5], tostring(i)))
	end
	Ui.new("Frame", {
		Name = "Hud2",
		BackgroundColor3 = Color3.fromHex("#0C0E14"),
		BackgroundTransparency = 0.14,
		Size = UDim2.new(1, 0, 0, Screen.HUD2),
		Position = UDim2.fromOffset(0, Screen.HUD1),
		Pad = { 0, 14, 0, 150 },
		List = { dir = "H", gap = 4, v = "C" },
		Parent = parent,
	}, navChildren)
end

local function cardHead(symbol: string, col: Color3, bg: Color3, kicker: string, title: string): Frame
	return Ui.row({
		Ui.ico(symbol, col, bg, 32),
		Ui.grow(Ui.col({ Ui.lbl(kicker), Ui.text(title, { size = 15, weight = W.bold }) }, 1)),
	}, 10)
end

local function hc(children: { Instance? }, border: Color3?): Frame
	return Ui.card(children, { bg = Color3.fromHex("#0C0E13"), transparency = 0.06, radius = 14, stroke = border or Color3.fromHex("#2A2E39"), pad = 14, gap = 9 })
end

local function buildSides(parent: Instance)
	local g = App.g
	local step, index = Screen.tutorialStep(g)
	local wk = Screen.week(g)
	local alert = topAlert(g)
	local top = Screen.TOP + 14

	-- Columna izquierda
	local tutorialRows = {}
	for i, s in Catalog.TUTORIAL do
		local done = (g.counters[s.counter] or 0) >= 1
		local cur = step and s.id == step.id
		table.insert(tutorialRows, Ui.row({
			Ui.new("TextLabel", {
				Text = done and "✓" or tostring(i),
				TextSize = 12,
				Weight = W.heavy,
				TextXAlignment = Enum.TextXAlignment.Center,
				TextColor3 = done and Color3.fromHex("#05230F") or (cur and T.tx or T.mut),
				BackgroundColor3 = done and T.gr or (cur and T.vi or T.p3),
				BackgroundTransparency = 0,
				Size = UDim2.fromOffset(24, 24),
				Corner = 12,
			}),
			Ui.grow(Ui.text(s.title, { size = Ui.S.sm, color = done and T.mut or T.tx, weight = cur and W.bold or W.med })),
		}, 8))
	end
	local objective = hc({
		cardHead("⚑", T.vi2, Color3.fromHex("#211D45"), step and ("Recorrido · paso " .. index .. " de " .. #Catalog.TUTORIAL) or "Recorrido completo", step and step.title or "¡Completaste la primera etapa!"),
		Ui.col(tutorialRows, 6),
		step and Ui.row({ Ui.button("Ir", "p", function()
			local go = ({ designsSaved = "editor", ordersCreated = "fabrica", unitsProduced = "fabrica", sentToShowroom = "autos", unitsSold = "ventas" })[step.counter]
			if go then
				App.go(go)
			end
		end, { small = true }) }) or nil,
	}, step and Color3.fromHex("#4B43A0") or nil)

	local weekCard = hc({
		cardHead("▤", T.gr, Color3.fromHex("#13301F"), "Últimos 7 días de juego", wk.units .. (wk.units == 1 and " auto vendido" or " autos vendidos")),
		Ui.line("Ingresos por venta", Util.money(wk.revenue), { leftColor = T.mut }),
		Ui.line("Costo de lo vendido", Util.money(-wk.cogs), { leftColor = T.mut, color = T.or_ }),
		Ui.hr(),
		Ui.line("Margen bruto", Util.money(wk.margin), { color = wk.margin >= 0 and T.gr or T.re2, leftWeight = W.bold }),
	})

	local leftChildren: { Instance? } = { objective, weekCard }
	if alert then
		local a = Ui.new("TextButton", {
			Name = "Alerta",
			Text = "",
			BackgroundColor3 = Color3.fromHex("#0C0E13"),
			BackgroundTransparency = 0.06,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Corner = 14,
			Stroke = alert.border,
			Pad = { 12, 14 },
			List = { dir = "H", gap = 10, v = "C" },
		}, {
			Ui.ico(alert.icon, alert.col, alert.bg, 32),
			Ui.grow(Ui.col({ Ui.text(alert.title, { size = Ui.S.sm, weight = W.bold }), Ui.text(alert.text, { size = Ui.S.xs, color = T.mut }) }, 2)),
			Ui.inline("›", { size = 18, color = T.mut }),
		})
		a.Activated:Connect(function()
			App.go(alert.go)
		end)
		table.insert(leftChildren, a)
	end
	Ui.col(leftChildren, 10, {
		Name = "PanelIzquierdo",
		Position = UDim2.fromOffset(14, top),
		Size = UDim2.fromOffset(330, 0),
		Parent = parent,
	})

	-- Columna derecha: en venta
	local forSale = {}
	for _, u in g.units do
		if u.status == "salon" then
			table.insert(forSale, u)
		end
	end
	local saleChildren: { Instance? } = {
		hc({ Ui.row({ Ui.ico("🏷", T.gr, Color3.fromHex("#13301F"), 32), Ui.grow(Ui.text("En venta · " .. #forSale .. (#forSale == 1 and " unidad" or " unidades"), { size = 15, weight = W.bold })) }, 10) }),
	}
	if #forSale == 0 then
		table.insert(saleChildren, hc({ Ui.text("El salón está vacío. Fabricá una unidad y enviala desde Mis autos.", { size = Ui.S.sm, color = T.mut }) }))
	end
	for _, u in forSale do
		local waiting, offer = 0, nil
		for _, c in g.customers do
			if c.unitId == u.id and c.state ~= "se fue" then
				waiting += 1
				if c.state == "oferta" then
					offer = c
				end
			end
		end
		table.insert(saleChildren, hc({
			Ui.row({ Ui.paintChip(u.spec, 44, 28), Ui.grow(Ui.col({ Ui.text(u.name, { size = 14, weight = W.bold }), Ui.text(u.serial .. " · calidad " .. u.quality, { size = Ui.S.xs, color = T.mut }) }, 1)) }, 10),
			Ui.line("Precio de lista", Util.money(u.price), { leftColor = T.mut }),
			Ui.line("Interesados", tostring(waiting), { leftColor = T.mut }),
			offer and Ui.row({ Ui.chip(offer.name .. " ofrece " .. Util.money(offer.offer), "cb"), Ui.spacer(), Ui.button("Responder", "p", function()
				App.go("ventas")
			end, { small = true }) }, 8) or nil,
		}))
	end
	Ui.col(saleChildren, 10, {
		Name = "PanelDerecho",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, top),
		Size = UDim2.fromOffset(340, 0),
		Parent = parent,
	})

	-- Botón de próxima acción (.cta)
	local cta = nextAction(g)
	local ctaBtn = Ui.new("TextButton", {
		Name = "ProximaAccion",
		Text = "",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -56),
		Size = UDim2.fromOffset(0, 62),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = T.tx,
		BackgroundTransparency = 0,
		Corner = 16,
		Stroke = { T.tx, 6, 0.88 },
		Pad = { 0, 10, 0, 24 },
		List = { dir = "H", gap = 14, v = "C" },
	}, {
		Ui.new("Frame", { Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY, List = { dir = "V", gap = 2 } }, {
			Ui.inline(cta.label, { size = 17, weight = W.heavy, color = T.dark }),
			Ui.inline(cta.sub, { size = Ui.S.sm, weight = W.semi, color = Color3.fromHex("#4A4F5C") }),
		}),
		Ui.new("TextLabel", {
			Text = "↵",
			TextSize = 14,
			Weight = W.bold,
			TextColor3 = T.tx,
			BackgroundColor3 = T.dark,
			BackgroundTransparency = 0,
			Size = UDim2.fromOffset(44, 44),
			Corner = 12,
			TextXAlignment = Enum.TextXAlignment.Center,
		}),
	})
	ctaBtn.Activated:Connect(function()
		if cta.dialog then
			App.openDialog("order", {})
		else
			App.go(cta.go)
		end
	end)
	ctaBtn.Parent = parent
end

function Screen.build(parent: Instance, route: string)
	buildHud(parent, route)
	if route == "juego" then
		buildSides(parent)
	end
end

return Screen
