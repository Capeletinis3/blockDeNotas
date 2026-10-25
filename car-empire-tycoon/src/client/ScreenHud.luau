--!strict
--[[
	HUD superior (hud1 + hud2 de la V3) y, en la vista del garaje, las tarjetas laterales (objetivo con
	recompensa, resumen de 7 días, alerta), «En venta», botón de próxima acción (.cta), accesos rápidos
	y noticias. En celular: una sola barra con menú desplegable y paneles que se abren con botones.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local Rules = require(Shared.Rules)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local T = Ui.T
local W = Ui.W

local Screen = {}

function Screen.top(): number
	if App.isPhone() then
		return 52
	end
	return 108
end
Screen.TOP = 108

-- id, etiqueta, ícono, color, fondo (NAV de la V3)
Screen.NAV = {
	{ "editor", "Diseño", "pen", Color3.fromHex("#B3AAFF"), Color3.fromHex("#211D45") },
	{ "autos", "Mis autos", "car", Color3.fromHex("#8DB8FF"), Color3.fromHex("#14233D") },
	{ "fabrica", "Fábrica", "factory", Color3.fromHex("#FFB36B"), Color3.fromHex("#33241A") },
	{ "ventas", "Ventas", "tag", Color3.fromHex("#42E58D"), Color3.fromHex("#13301F") },
	{ "mercado", "Mercado", "globe", Color3.fromHex("#F7C95C"), Color3.fromHex("#322A14") },
	{ "investigacion", "Investigación", "flask", Color3.fromHex("#6FE3F0"), Color3.fromHex("#12303A") },
	{ "personal", "Personal", "users", Color3.fromHex("#FF9DC1"), Color3.fromHex("#33182A") },
	{ "compania", "Compañía", "building", Color3.fromHex("#C9CED8"), Color3.fromHex("#22252D") },
}
Screen.MORE = {
	{ "misiones", "Misiones", "flag" },
	{ "estadisticas", "Estadísticas y finanzas", "chart" },
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
	local pending = 0
	for _, o in g.market.offers do
		if o.status == "pendiente" then
			pending += 1
		end
	end
	local stopped = 0
	for _, o in g.production.orders do
		if o.status == "detenida" then
			stopped += 1
		end
	end
	return {
		autos = ready > 0 and { ready, Color3.fromHex("#1F4FA0") } or nil,
		fabrica = #g.production.orders > 0 and { #g.production.orders, stopped > 0 and Color3.fromHex("#8A2A31") or Color3.fromHex("#7A4A1C") } or nil,
		ventas = offers > 0 and { offers, Color3.fromHex("#1D6A3F") } or nil,
		mercado = pending > 0 and { pending, Color3.fromHex("#6A5A1D") } or nil,
		investigacion = (not g.research.active and g.rp >= 20) and { "!", Color3.fromHex("#2A6A75") } or nil,
		misiones = Rules.readyMissions(g) > 0 and { Rules.readyMissions(g), Color3.fromHex("#1D6A3F") } or nil,
	}
end
Screen.counts = counts

local function nextAction(g: any): any
	local ed = App.ui.editor
	local tut = Rules.currentTutorial(g)
	if tut and Rules.missionState(g, tut) == "lista" then
		return { label = "Reclamar recompensa", sub = tut.title .. " · " .. Rules.rewardText(tut.reward), claim = tut.id }
	end
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
	return { label = "Fabricar un auto", sub = "Elegí uno de tus diseños", dialog = "order" }
end
Screen.nextAction = nextAction

local function topAlert(g: any): any
	for _, o in g.production.orders do
		if o.status == "detenida" then
			return { title = "Producción detenida", text = o.reason, go = "fabrica", icon = "warn", col = T.re2, bg = Color3.fromHex("#33171A"), border = Color3.fromHex("#7A3A40") }
		end
	end
	local ready = 0
	for _, u in g.units do
		if u.status == "almacen" then
			ready += 1
		end
	end
	if ready > 0 then
		return { title = ready .. (ready > 1 and " vehículos listos" or " vehículo listo"), text = "Esperan en el almacén. Envialos al salón.", go = "autos", icon = "check", col = T.gr, bg = Color3.fromHex("#14301F"), border = Color3.fromHex("#226043") }
	end
	local offers = 0
	for _, c in g.customers do
		if c.state == "oferta" then
			offers += 1
		end
	end
	if offers > 0 then
		return { title = offers .. (offers > 1 and " clientes con oferta" or " cliente con oferta"), text = "Respondé antes de que se vayan.", go = "ventas", icon = "tag", col = T.bl2, bg = Color3.fromHex("#142844"), border = Color3.fromHex("#22406E") }
	end
	if not g.research.active and g.rp >= 20 then
		return { title = "Laboratorio libre", text = "Tenés " .. math.floor(g.rp) .. " PI para investigar.", go = "investigacion", icon = "flask", col = T.vi2, bg = Color3.fromHex("#211D45"), border = Color3.fromHex("#4B43A0") }
	end
	for _, e in g.employees do
		if e.energy < 20 and e.status == "activo" then
			return { title = e.name .. " está agotado/a", text = "Rinde la mitad. Dale un descanso.", go = "personal", icon = "users", col = T.ye, bg = Color3.fromHex("#322A14"), border = Color3.fromHex("#5E4E26") }
		end
	end
	return nil
end
Screen.topAlert = topAlert

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

local function hbtn(icon: string, onClick: () -> (), badge: number?): TextButton
	local b = Ui.new("TextButton", {
		Name = "BotonHud_" .. icon,
		Text = "",
		BackgroundColor3 = T.p1,
		BackgroundTransparency = 0,
		Size = UDim2.fromOffset(42, 42),
		Corner = 10,
		Stroke = Color3.fromHex("#262A35"),
	}, { Ui.icon(icon, 18, T.tx) })
	local ic = b:FindFirstChild("Icono") :: Frame
	ic.AnchorPoint = Vector2.new(0.5, 0.5)
	ic.Position = UDim2.fromScale(0.5, 0.5)
	if badge and badge > 0 then
		Ui.new("TextLabel", {
			Text = tostring(badge), TextSize = 11, Weight = W.heavy, TextColor3 = Color3.fromHex("#1A0507"),
			BackgroundColor3 = T.re, BackgroundTransparency = 0, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 5, 0, -5),
			Size = UDim2.fromOffset(19, 19), Corner = 10, TextXAlignment = Enum.TextXAlignment.Center, Parent = b,
		})
	end
	b.Activated:Connect(onClick)
	return b
end

local function speedGroup(g: any): Frame
	local group = Ui.new("Frame", {
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
	local options = App.isPhone() and { { 0, "❚❚" }, { 1, "1×" }, { 4, "4×" } } or { { 0, "❚❚" }, { 1, "1×" }, { 2, "2×" }, { 4, "4×" } }
	for _, sp in options do
		local on = g.time.speed == sp[1]
		local b = Ui.new("TextButton", {
			Name = "Velocidad_" .. sp[1],
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
		b.Parent = group
	end
	return group
end

local function unread(g: any): number
	local n = 0
	for _, x in g.notifications do
		if not x.read then
			n += 1
		end
	end
	return n
end

-- Menú «Más» / menú del celular.
function Screen.openMenu(full: boolean)
	App.openDialog("navMenu", { full = full })
end

local function buildHud(parent: Instance, route: string)
	local g = App.g
	local p = App.payload
	local phone = App.isPhone()
	local brand = Ui.new("TextButton", {
		Name = "Marca",
		Text = "",
		BackgroundColor3 = T.p1,
		BackgroundTransparency = 0,
		Size = UDim2.fromOffset(0, 42),
		AutomaticSize = Enum.AutomaticSize.X,
		Corner = 10,
		Stroke = Color3.fromHex("#262A35"),
		Pad = { 0, phone and 5 or 12, 0, 5 },
		List = { dir = "H", gap = 10, v = "C" },
	}, {
		Ui.logo(g.company, 30),
		(not phone) and Ui.new("Frame", { Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY, List = { dir = "V", gap = 1 } }, {
			Ui.inline(g.company.name, { size = 14, weight = W.bold }),
			Ui.inline(g.derived.sedeName .. " · Nv. " .. g.level, { size = Ui.S.xs, color = T.mut }),
		}) or nil,
	})
	brand.Activated:Connect(function()
		App.go("compania")
	end)

	local dateRes, dateValue, dateKicker = res("cal", T.bl2, Color3.fromHex("#14233D"), "FECHA", Util.gameDate(g.time.day))
	local moneyRes, moneyValue = res("money", T.gr, Color3.fromHex("#13301F"), "DINERO", Util.money(g.money))
	local rpRes, rpValue = res("flask", T.vi2, Color3.fromHex("#211D45"), "INVESTIGACIÓN", math.floor(g.rp) .. " PI")
	local repRes = res("star", T.ye, Color3.fromHex("#322A14"), "REPUTACIÓN", Util.num(g.reputation, 1) .. " / 5")
	local staffRes = res("users", T.pink, Color3.fromHex("#33182A"), "PERSONAL", #g.employees .. "/" .. g.derived.caps.staff)
	App.live(function(gg: any)
		dateValue.Text = Util.gameDate(gg.time.day)
		dateKicker.Text = "FECHA · " .. Util.clock(gg.time.minute)
		moneyValue.Text = Util.money(gg.money)
		rpValue.Text = math.floor(gg.rp) .. " PI"
	end)

	local unreadN = unread(g)
	local children: { Instance? } = { brand }
	if phone then
		table.insert(children, moneyRes)
		table.insert(children, Ui.spacer())
		table.insert(children, speedGroup(g))
		table.insert(children, hbtn("bell", function()
			App.openDialog("notifications", {})
		end, unreadN))
		table.insert(children, Ui.button("Menú", "p", function()
			Screen.openMenu(true)
		end, { small = true, icon = "menu", name = "BotonMenu" }))
	else
		local wide = App.layout == "desktop"
		table.insert(children, App.layout ~= "tablet" and dateRes or nil)
		table.insert(children, moneyRes)
		table.insert(children, rpRes)
		table.insert(children, wide and staffRes or nil)
		table.insert(children, wide and repRes or nil)
		table.insert(children, Ui.spacer())
		if g.time.speed == 0 and wide then
			table.insert(children, Ui.chip("❚❚ Simulación en pausa", "cy"))
		end
		if p.saveMode == "memory" and wide then
			table.insert(children, Ui.chip("Guardado temporal (Studio)", "cy"))
		end
		table.insert(children, speedGroup(g))
		table.insert(children, hbtn("bell", function()
			App.openDialog("notifications", {})
		end, unreadN))
		table.insert(children, hbtn("help", function()
			App.openDialog("help", { screen = route })
		end))
		table.insert(children, hbtn("gear", function()
			App.openDialog("settings", {})
		end))
	end
	Ui.new("Frame", {
		Name = "Hud1",
		BackgroundColor3 = T.bg,
		BackgroundTransparency = 0.08,
		Size = UDim2.new(1, 0, 0, phone and 52 or 56),
		-- Espacio libre a la izquierda para los botones de Roblox (igual que la V3).
		Pad = { 0, phone and 8 or 14, 0, phone and 96 or 150 },
		List = { dir = "H", gap = phone and 5 or 8, v = "C" },
		Parent = parent,
	}, children)
	if phone then
		return
	end

	-- hud2 (navegación)
	local navCounts = counts(g)
	local function navItem(id: string, label: string, icon: string, col: Color3, bg: Color3, key: string): TextButton
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
			Ui.ico(icon, col, bg, 28),
			Ui.inline(label, { size = App.layout == "desktop" and 14 or 13, weight = W.semi, color = current and T.dark or Color3.fromHex("#E4E7EC") }),
			cnt and Ui.new("TextLabel", {
				Text = tostring(cnt[1]), TextSize = 11, Weight = W.heavy, TextColor3 = T.tx, BackgroundColor3 = cnt[2], BackgroundTransparency = 0,
				Size = UDim2.fromOffset(0, 20), AutomaticSize = Enum.AutomaticSize.X, Corner = 10, Pad = { 0, 7 }, TextXAlignment = Enum.TextXAlignment.Center,
			}) or nil,
			(App.layout == "desktop" and App.settings.keyHints and key ~= "") and Ui.new("TextLabel", {
				Text = key, TextSize = 11, Weight = W.semi, TextColor3 = T.mut, Size = UDim2.fromOffset(0, 20), AutomaticSize = Enum.AutomaticSize.X,
				Corner = 5, Stroke = Color3.fromHex("#3D4250"), Pad = { 0, 6 }, TextXAlignment = Enum.TextXAlignment.Center,
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
	local navChildren: { Instance? } = { navItem("juego", "Sede", "home", T.tx, Color3.fromHex("#22252D"), "0") }
	for i, n in Screen.NAV do
		table.insert(navChildren, navItem(n[1], n[2], n[3], n[4], n[5], i <= 8 and tostring(i) or ""))
	end
	local more = Ui.button("Más", "q", function()
		Screen.openMenu(false)
	end, { small = true, icon = "down", name = "Mas" })
	table.insert(navChildren, more)
	local nav = Ui.new("ScrollingFrame", {
		Name = "Hud2",
		BackgroundColor3 = Color3.fromHex("#0C0E14"),
		BackgroundTransparency = 0.14,
		Size = UDim2.new(1, 0, 0, 52),
		Position = UDim2.fromOffset(0, 56),
		Pad = { 0, 14, 0, 150 },
		List = { dir = "H", gap = 4, v = "C" },
		ScrollingDirection = Enum.ScrollingDirection.X,
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollBarThickness = 0,
		Parent = parent,
	}, navChildren)
	App.keepScroll(nav, "hud2")
end

local function cardHead(icon: string, col: Color3, bg: Color3, kicker: string, title: string): Frame
	return Ui.row({
		Ui.ico(icon, col, bg, 32),
		Ui.grow(Ui.col({ Ui.lbl(kicker), Ui.text(title, { size = 15, weight = W.bold }) }, 1)),
	}, 10)
end

local function hc(children: { Instance? }, border: Color3?): Frame
	return Ui.card(children, { bg = Color3.fromHex("#0C0E13"), transparency = 0.06, radius = 14, stroke = border or Color3.fromHex("#2A2E39"), pad = 14, gap = 9 })
end

-- Tarjeta del objetivo: paso del tutorial (con su recompensa) o la próxima misión.
function Screen.objectiveCard(g: any): Frame
	local tut = Rules.currentTutorial(g)
	local m = (tut and not g.tutorial.skipped) and tut or nil
	if not m then
		for _, x in Catalog.MISSIONS do
			if x.kind ~= "tutorial" and Rules.missionState(g, x) ~= "reclamada" then
				m = x
				break
			end
		end
	end
	if not m then
		return hc({ cardHead("flag", T.vi2, Color3.fromHex("#211D45"), "Objetivo actual", "Hacé crecer tu marca"), Ui.text("Completaste todas las misiones disponibles.", { size = Ui.S.sm, color = T.mut }) })
	end
	local v = Rules.missionValue(g, m)
	local st = Rules.missionState(g, m)
	local isTut = m.kind == "tutorial"
	local index = 0
	for i, x in Catalog.MISSIONS do
		if x.id == m.id then
			index = i
		end
	end
	local money = m.counter == "marginToday"
	local bar = Ui.bar(math.min(1, v / m.goal) * 100, st == "lista" and T.gr or nil)
	local claim
	claim = Ui.button("Reclamar recompensa", "g", function()
		App.request("claimMission", { id = m.id }, { button = claim })
	end, { small = true, icon = "check", name = "Reclamar" })
	return hc({
		cardHead("flag", T.vi2, Color3.fromHex("#211D45"), isTut and ("Tutorial · paso " .. index .. " de 5") or "Objetivo actual", m.title),
		Ui.text(m.desc, { size = Ui.S.sm, color = T.mut, lineHeight = 1.3 }),
		Ui.row({ Ui.grow(bar, { Size = UDim2.new(0, 0, 0, 7) }), Ui.inline((money and Util.money(math.min(v, m.goal)) or tostring(math.min(v, m.goal))) .. "/" .. (money and Util.money(m.goal) or tostring(m.goal)), { size = Ui.S.sm, weight = W.bold }) }, 8),
		Ui.line("Recompensa", Rules.rewardText(m.reward), { leftColor = T.mut, color = T.gr, size = Ui.S.xs }),
		st == "lista" and claim or Ui.row({
			Ui.button("Ir", "p", function()
				App.go(m.go)
			end, { small = true }),
			isTut and Ui.button("Saltar tutorial", "q", function()
				App.openDialog("confirm", {
					title = "¿Saltar el tutorial?",
					body = "Se ocultan las guías. No se completan objetivos ni se entregan recompensas: las misiones del tutorial siguen en Misiones y se cumplen haciendo cada acción.",
					okLabel = "Saltar tutorial",
					onOk = function()
						App.request("setTutorial", { skipped = true })
					end,
				})
			end, { small = true }) or nil,
		}, 8),
	}, (isTut and st ~= "reclamada") and Color3.fromHex("#4B43A0") or nil)
end

local function buildSides(parent: Instance)
	local g = App.g
	local phone = App.isPhone()
	local wk = Rules.finance(g, 7)
	local alert = topAlert(g)
	local top = Screen.top() + 14

	local weekCard = hc({
		cardHead("chart", T.gr, Color3.fromHex("#13301F"), "Últimos 7 días de juego", wk.units .. (wk.units == 1 and " auto vendido" or " autos vendidos")),
		Ui.line("Ingresos por venta", Util.money(wk.revenue), { leftColor = T.mut }),
		Ui.line("Costo de lo vendido", Util.money(-wk.cogs), { leftColor = T.mut, color = T.or_ }),
		Ui.line("Margen bruto", Util.money(wk.margin), { color = wk.margin >= 0 and T.gr or T.re2, leftWeight = W.bold }),
		Ui.hr(),
		Ui.line("Flujo de caja neto", Util.money(wk.cash), { color = wk.cash >= 0 and T.gr or T.re2, leftWeight = W.bold }),
	})
	local leftChildren: { Instance? } = { Screen.objectiveCard(g), weekCard }
	if alert then
		local a = Ui.new("TextButton", {
			Name = "Alerta", Text = "", BackgroundColor3 = Color3.fromHex("#0C0E13"), BackgroundTransparency = 0.06,
			Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Corner = 14, Stroke = alert.border, Pad = { 12, 14 },
			List = { dir = "H", gap = 10, v = "C" },
		}, {
			Ui.ico(alert.icon, alert.col, alert.bg, 32),
			Ui.grow(Ui.col({ Ui.text(alert.title, { size = Ui.S.sm, weight = W.bold }), Ui.text(alert.text, { size = Ui.S.xs, color = T.mut }) }, 2)),
			Ui.icon("right", 16, T.mut),
		})
		a.Activated:Connect(function()
			App.go(alert.go)
		end)
		table.insert(leftChildren, a)
	end

	local forSale = {}
	for _, u in g.units do
		if u.status == "salon" or u.status == "mercado" then
			table.insert(forSale, u)
		end
	end
	local saleChildren: { Instance? } = {
		hc({ Ui.row({ Ui.ico("tag", T.gr, Color3.fromHex("#13301F"), 32), Ui.grow(Ui.text("En venta · " .. #forSale .. (#forSale == 1 and " unidad" or " unidades"), { size = 15, weight = W.bold })) }, 10) }),
	}
	if #forSale == 0 then
		table.insert(saleChildren, hc({ Ui.text("El salón está vacío. Fabricá una unidad y enviala desde Mis autos.", { size = Ui.S.sm, color = T.mut }) }))
	end
	for i, u in forSale do
		if i > 4 then
			break
		end
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
			Ui.row({ Ui.carThumb(u.spec, 64, 40), Ui.grow(Ui.col({ Ui.text(u.name, { size = 14, weight = W.bold }), Ui.text(u.serial .. (u.status == "mercado" and " · en el mercado" or " · en el salón"), { size = Ui.S.xs, color = T.mut }) }, 1)) }, 10),
			Ui.line("Precio final", Util.money(Rules.finalPrice(u)), { leftColor = T.mut }),
			Ui.line("Interesados", tostring(waiting), { leftColor = T.mut }),
			offer and Ui.row({ Ui.chip(offer.name .. " ofrece " .. Util.money(offer.offer), "cb"), Ui.spacer(), Ui.button("Responder", "p", function()
				App.go("ventas")
			end, { small = true }) }, 8) or nil,
		}))
	end

	if phone then
		-- Celular: botones que abren un panel por vez (las tarjetas no tapan el garaje).
		local open = App.ui.sidePanel
		local pills = Ui.row({
			Ui.button("Objetivo", open == "l" and "p" or "default", function()
				App.ui.sidePanel = open == "l" and nil or "l"
				App.forceRender()
			end, { small = true, icon = "flag" }),
			Ui.button("En venta " .. #forSale, open == "r" and "p" or "default", function()
				App.ui.sidePanel = open == "r" and nil or "r"
				App.forceRender()
			end, { small = true, icon = "tag" }),
			alert and Ui.button("Alerta", "default", function()
				App.go(alert.go)
			end, { small = true, icon = alert.icon }) or nil,
		}, 6, { Position = UDim2.fromOffset(8, 60), Size = UDim2.new(1, -16, 0, 0), wrap = true, Parent = parent })
		if open then
			local panel = Ui.scroll(open == "l" and leftChildren or saleChildren, { name = "PanelMovil", gap = 10, pad = { 2, 2, 8, 2 } })
			panel.Position = UDim2.fromOffset(8, 104)
			panel.Size = UDim2.new(1, -16, 1, -190)
			panel.Parent = parent
		end
		local _ = pills
	else
		local sideW = App.layout == "desktop" and 330 or 290
		local l = Ui.scroll(leftChildren, { name = "PanelIzquierdo", gap = 10, pad = { 2, 4, 8, 2 } })
		l.Position = UDim2.fromOffset(14, top)
		l.Size = UDim2.new(0, sideW, 1, -(top + 130))
		l.Parent = parent
		App.keepScroll(l, "sideL")
		if App.layout ~= "tablet" then
			local r = Ui.scroll(saleChildren, { name = "PanelDerecho", gap = 10, pad = { 2, 4, 8, 2 } })
			r.AnchorPoint = Vector2.new(1, 0)
			r.Position = UDim2.new(1, -14, 0, top)
			r.Size = UDim2.new(0, sideW + 10, 1, -(top + 130))
			r.Parent = parent
			App.keepScroll(r, "sideR")
		end
	end

	-- Botón de próxima acción (.cta). En celular queda al centro, lejos de los controles táctiles de Roblox.
	local cta = nextAction(g)
	local ctaBtn = Ui.new("TextButton", {
		Name = "ProximaAccion",
		Text = "",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, phone and -16 or -56),
		Size = UDim2.fromOffset(0, phone and 50 or 62),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = T.tx,
		BackgroundTransparency = 0,
		Corner = 16,
		Stroke = { T.tx, 6, 0.88 },
		Pad = { 0, 10, 0, phone and 16 or 24 },
		List = { dir = "H", gap = 14, v = "C" },
	}, {
		Ui.new("Frame", { Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY, List = { dir = "V", gap = 2 } }, {
			Ui.inline(cta.label, { size = phone and 15 or 17, weight = W.heavy, color = T.dark }),
			(not phone) and Ui.inline(cta.sub, { size = Ui.S.sm, weight = W.semi, color = Color3.fromHex("#4A4F5C") }) or nil,
		}),
		Ui.ico(cta.claim and "check" or "right", T.tx, T.dark, phone and 36 or 44),
	})
	local maxW = Instance.new("UISizeConstraint")
	maxW.MaxSize = Vector2.new(phone and App.vw * 0.55 or 560, 80)
	maxW.Parent = ctaBtn
	ctaBtn.Activated:Connect(function()
		if cta.claim then
			App.request("claimMission", { id = cta.claim })
		elseif cta.dialog then
			App.openDialog("order", {})
		else
			App.go(cta.go)
		end
	end)
	ctaBtn.Parent = parent

	if not phone then
		-- Accesos rápidos (minis) y noticias (ticker).
		Ui.row({
			hbtn("users", function()
				App.openDialog("future", { what = "amigos" })
			end),
			hbtn("cal", function()
				App.openDialog("future", { what = "eventos" })
			end),
			hbtn("gift", function()
				App.openDialog("daily", {})
			end, (g.daily.last ~= App.payload.today) and 1 or nil),
		}, 8, { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -14, 1, -46), Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY, Parent = parent })
		local news = {}
		local last = g.sales[#g.sales]
		if last then
			table.insert(news, { "TU EMPRESA", "#B3AAFF", g.company.name .. " vendió " .. last.name .. " por " .. Util.money(last.price) .. "." })
		end
		for _, n in Catalog.NEWS_POOL do
			table.insert(news, n)
		end
		local idx = (g.time.day % #news) + 1
		local item = news[idx]
		Ui.row({
			Ui.new("TextLabel", { Text = "NOTICIAS", TextSize = 11, Weight = W.heavy, TextColor3 = T.ye, BackgroundColor3 = T.p1, BackgroundTransparency = 0, Size = UDim2.new(0, 96, 1, 0), TextXAlignment = Enum.TextXAlignment.Center }),
			Ui.inline("<font color=\"" .. item[2] .. "\"><b>" .. item[1] .. "</b></font>  " .. item[3], { size = 13, color = T.tx2 }),
		}, 14, { Name = "Noticias", BackgroundColor3 = T.bg, BackgroundTransparency = 0.07, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 36), AutomaticSize = Enum.AutomaticSize.None, Parent = parent })
	end
end

function Screen.build(parent: Instance, route: string)
	buildHud(parent, route)
	if route == "juego" then
		buildSides(parent)
	end
end

return Screen
