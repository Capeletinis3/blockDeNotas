--!strict
--[[
	HUD superior (renderHud de la V3: .hud1 recursos y controles, .hud2 navegación, menú «Más»,
	menú de celular) y vista de la sede (renderGameView: tarjetas laterales, «En venta», ocultar paneles,
	botón principal, accesos, noticias y globo del tutorial).
	El margen izquierdo de 150 px de la V3 deja libre la zona de los botones de Roblox.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local Rules = require(Shared.Rules)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local T = Ui.T
local W = Ui.W
local hex = Ui.hex

local Screen = {}

-- Alturas de la V3 (--hud1, --hud2)
function Screen.top(): number
	return App.isPhone() and 52 or 108
end

-- id, etiqueta, ícono, color, fondo (con su transparencia rgba)
Screen.NAV = {
	{ "editor", "Diseño", "pen", hex("#B3AAFF"), T.vi, 0.2 },
	{ "autos", "Mis autos", "car", hex("#8DB8FF"), T.bl, 0.18 },
	{ "fabrica", "Fábrica", "factory", hex("#FFB36B"), hex("#FFA050"), 0.16 },
	{ "ventas", "Ventas", "tag", T.gr, T.gr, 0.15 },
	{ "mercado", "Mercado", "globe", T.ye, T.ye, 0.15 },
	{ "investigacion", "Investigación", "flask", T.cyan, hex("#50D2E6"), 0.15 },
	{ "personal", "Personal", "users", T.pink, hex("#FF78AA"), 0.14 },
	{ "compania", "Compañía", "building", hex("#C9CED8"), hex("#C9CED8"), 0.12 },
}
Screen.MORE = {
	{ "misiones", "Misiones", "flag" },
	{ "estadisticas", "Estadísticas y finanzas", "chart" },
}

-- navCounts de la V3: { texto, color de fondo, transparencia, color de texto }
function Screen.counts(g: any): { [string]: any }
	local out = {}
	local ready = 0
	for _, u in g.units do
		if u.status == "almacen" then
			ready += 1
		end
	end
	if ready > 0 then
		out.autos = { ready .. " listos", T.gr, 0.82, T.gr }
	end
	local stopped = 0
	for _, o in g.production.orders do
		if o.status == "detenida" then
			stopped += 1
		end
	end
	if stopped > 0 then
		out.fabrica = { stopped .. " detenida" .. (stopped > 1 and "s" or ""), T.re, 0.8, T.re2 }
	end
	local off = 0
	for _, c in g.customers do
		if c.state == "oferta" then
			off += 1
		end
	end
	if off > 0 then
		out.ventas = { off .. " oferta" .. (off > 1 and "s" or ""), T.bl, 0.78, T.bl2 }
	end
	local moff = 0
	for _, o in g.market.offers do
		if o.status == "pendiente" then
			moff += 1
		end
	end
	if moff > 0 then
		out.mercado = { moff .. " ofertas", T.ye, 0.82, T.ye }
	end
	if not g.research.active then
		for _, cat in Catalog.RESEARCH_ORDER do
			local found = false
			for _, n in Catalog.RESEARCH[cat].nodes do
				if Rules.researchState(g, n) == "disponible" then
					found = true
					break
				end
			end
			if found then
				out.investigacion = { "libre", T.vi, 0.78, T.vi3 }
				break
			end
		end
	end
	local tired = 0
	for _, e in g.employees do
		if e.energy < 20 and e.status == "activo" then
			tired += 1
		end
	end
	if tired > 0 then
		out.personal = { tired .. " cansado" .. (tired > 1 and "s" or ""), T.ye, 0.82, T.ye }
	end
	if #g.designs == 0 then
		out.editor = { "Empezá acá", T.vi, 0.75, T.vi3 }
	end
	return out
end

-- Botón principal (nextAction de la V3)
function Screen.nextAction(g: any): any
	local ed = App.ui.editor
	if #g.designs == 0 then
		return { label = ed and "Continuar diseño" or "Diseñar mi primer auto", sub = ed and "Tenés un proyecto sin guardar" or "Abrí el escritorio de diseño", go = "editor", key = "1" }
	end
	if ed and ed.dirty then
		return { label = "Continuar diseño", sub = ed.draft.name .. " tiene cambios sin guardar", go = "editor", key = "1" }
	end
	for _, c in g.customers do
		if c.state == "oferta" then
			return { label = "Abrir concesionario", sub = c.name .. " hizo una oferta", go = "ventas", key = "4" }
		end
	end
	local ready = 0
	for _, u in g.units do
		if u.status == "almacen" then
			ready += 1
		end
	end
	if ready > 0 then
		return { label = "Enviar autos al salón", sub = ready .. " unidades esperando", go = "autos", key = "2" }
	end
	local n = #g.production.orders
	if n > 0 then
		return { label = "Ver producción", sub = n .. " orden" .. (n > 1 and "es" or "") .. " en curso", go = "fabrica", key = "3" }
	end
	local designs = 0
	for _, d in g.designs do
		if not d.template then
			designs += 1
		end
	end
	return { label = "Fabricar un auto", sub = "Elegí uno de tus " .. designs .. " diseños", dialog = "order", key = "3" }
end
function Screen.runNext(g: any)
	local cta = Screen.nextAction(g)
	if cta.dialog then
		App.openDialog(cta.dialog, { wide = true })
	else
		App.go(cta.go)
	end
end

-- topAlert de la V3
function Screen.topAlert(g: any): any
	for _, o in g.production.orders do
		if o.status == "detenida" then
			return { title = "Producción detenida", text = o.reason, go = "fabrica", icon = "warn", col = T.re2, bg = T.re, a = 0.15, border = T.re, ba = 0.5 }
		end
	end
	local ready = 0
	for _, u in g.units do
		if u.status == "almacen" then
			ready += 1
		end
	end
	if ready > 0 then
		return { title = ready .. " vehículo" .. (ready > 1 and "s" or "") .. " listo" .. (ready > 1 and "s" or ""), text = "Esperan en el almacén. Enviálos al salón o publicálos.", go = "autos", icon = "check", col = T.gr, bg = T.gr, a = 0.15, border = T.gr, ba = 0.5 }
	end
	local off = 0
	for _, c in g.customers do
		if c.state == "oferta" then
			off += 1
		end
	end
	if off > 0 then
		return { title = off .. " cliente" .. (off > 1 and "s" or "") .. " con oferta", text = "Respondé antes de que se vayan.", go = "ventas", icon = "tag", col = T.bl2, bg = T.bl, a = 0.18, border = T.bl, ba = 0.5 }
	end
	if not g.research.active and g.rp >= 20 then
		return { title = "Laboratorio libre", text = "Tenés " .. math.floor(g.rp) .. " PI para investigar.", go = "investigacion", icon = "flask", col = T.vi2, bg = T.vi, a = 0.2, border = T.vi, ba = 0.5 }
	end
	for _, e in g.employees do
		if e.energy < 20 and e.status == "activo" then
			return { title = e.name .. " está agotado/a", text = "Rinde la mitad. Dale un descanso.", go = "personal", icon = "users", col = T.ye, bg = T.ye, a = 0.15, border = T.ye, ba = 0.5 }
		end
	end
	return nil
end

-- Objetivo actual (objective de la V3)
function Screen.objective(g: any): any
	local t = Rules.currentTutorial(g)
	if t and not g.tutorial.skipped then
		return t
	end
	for _, m in Catalog.MISSIONS do
		if m.kind ~= "tutorial" and Rules.missionState(g, m) ~= "reclamada" then
			return m
		end
	end
	return { title = "Hacé crecer tu marca", desc = "Todas las misiones disponibles están completas." }
end

-- Elementos del HUD ----------------------------------------------------------------------------
local function res(icon: string, col: Color3, bg: Color3, a: number, kicker: string?, value: string, opts: any?): (Frame, TextLabel, TextLabel?)
	local o = opts or {}
	local valueLabel = Ui.inline(value, { size = 14, weight = W.bold, name = "Valor" })
	local kickerLabel = kicker and Ui.inline(kicker, { size = 10, color = T.mut, weight = W.bold, name = "Rotulo" }) or nil
	local f = Ui.new("Frame", {
		Name = o.name or "Recurso",
		BackgroundColor3 = T.p1,
		BackgroundTransparency = 0,
		Size = UDim2.fromOffset(0, 42),
		AutomaticSize = Enum.AutomaticSize.X,
		Corner = 10,
		Stroke = T.hudLine,
		Pad = { 0, 11 },
		List = { dir = "H", gap = 8, v = "C" },
	}, {
		(not o.noIcon) and Ui.ico(icon, col, bg, 28, { alpha = a, iconSize = 15 }) or nil,
		Ui.new("Frame", { Name = "T", Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY, List = { dir = "V", gap = 1 } }, { kickerLabel, valueLabel }),
	})
	return f, valueLabel, kickerLabel
end

local function hbtn(icon: string, onClick: () -> (), badge: number?, name: string?): TextButton
	local b = Ui.new("TextButton", {
		Name = name or ("BotonHud_" .. icon),
		Text = "",
		BackgroundColor3 = T.p1,
		BackgroundTransparency = 0,
		Size = UDim2.fromOffset(42, 42),
		Corner = 10,
		Stroke = T.hudLine,
	})
	local ic = Ui.icon(icon, 18, T.tx)
	ic.AnchorPoint = Vector2.new(0.5, 0.5)
	ic.Position = UDim2.fromScale(0.5, 0.5)
	ic.Parent = b
	if badge and badge > 0 then
		Ui.new("TextLabel", {
			Name = "Insignia",
			Text = tostring(badge), TextSize = 11, Weight = W.heavy, TextColor3 = hex("#1A0507"),
			BackgroundColor3 = T.re, BackgroundTransparency = 0, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 5, 0, -5),
			Size = UDim2.fromOffset(19, 19), Corner = 10, TextXAlignment = Enum.TextXAlignment.Center, Stroke = { T.bg, 2 }, ZIndex = 2, Parent = b,
		})
	end
	b.Activated:Connect(function()
		if Ui.onClickSound then
			Ui.onClickSound()
		end
		onClick()
	end)
	return b
end
Screen.hbtn = hbtn

local SPEEDS = { { 0, "❚❚", "Pausa" }, { 1, "1×", "Velocidad normal" }, { 2, "2×", "Velocidad doble" }, { 4, "4×", "Velocidad cuádruple" } }
function Screen.speedGroup(g: any, compact: boolean?): Frame
	local group = Ui.new("Frame", {
		Name = "Velocidad",
		BackgroundColor3 = T.p1,
		BackgroundTransparency = 0,
		Size = UDim2.fromOffset(0, 42),
		AutomaticSize = Enum.AutomaticSize.X,
		Corner = 10,
		Stroke = T.hudLine,
		Pad = 3,
		List = { dir = "H", gap = 2, v = "C" },
	})
	for _, sp in SPEEDS do
		if compact and (sp[1] == 2 or sp[1] == 4) then
			continue
		end
		local on = g.time.speed == sp[1]
		local b = Ui.new("TextButton", {
			Name = "Velocidad_" .. sp[1],
			Text = sp[2],
			TextSize = 14,
			Weight = W.heavy,
			TextColor3 = on and (sp[1] == 0 and hex("#1D1503") or T.dark) or T.tx2,
			BackgroundColor3 = sp[1] == 0 and T.ye or T.tx,
			BackgroundTransparency = on and 0 or 1,
			Size = UDim2.fromOffset(42, 36),
			Corner = 7,
			TextXAlignment = Enum.TextXAlignment.Center,
		})
		b.Activated:Connect(function()
			App.ui.pop = nil
			App.request("setSpeed", { speed = sp[1] })
		end)
		b.Parent = group
	end
	return group
end

-- Fila 1: marca, recursos y controles ----------------------------------------------------------
local function hud1(g: any): Frame
	local L = App.layout
	local phone = L == "phone"
	local narrow = phone and App.narrowPhone
	local deskOnly = not phone
	local deskWide = L == "desktop"
	local unread = 0
	for _, n in g.notifications do
		if not n.read then
			unread += 1
		end
	end
	local brandText = Ui.col({
		Ui.inline(g.company.name, { size = 14, weight = W.bold, truncate = L ~= "desktop", width = L ~= "desktop" and 150 or nil, name = "NombreEmpresa" }),
		Ui.inline(g.derived.sedeName .. " · Nv. " .. g.level, { size = Ui.S.xs, color = T.mut, name = "SedeNivel" }),
	}, 1, { Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY })
	local brand = Ui.new("TextButton", {
		Name = "Marca",
		Text = "",
		BackgroundColor3 = T.p1,
		BackgroundTransparency = 0,
		Size = UDim2.fromOffset(0, 42),
		AutomaticSize = Enum.AutomaticSize.X,
		Corner = 10,
		Stroke = T.hudLine,
		Pad = { 0, narrow and 5 or 12, 0, 5 },
		List = { dir = "H", gap = 10, v = "C" },
	}, { Ui.logo(g.company, 30), (not narrow) and brandText or nil })
	brand.Activated:Connect(function()
		App.go("compania")
	end)

	local items: { Instance? } = { brand }
	if deskOnly then
		local f, v, k = res("cal", T.bl2, T.bl, 0.16, "FECHA · " .. Util.clock(g.time.minute), Util.gameDate(g.time.day), { name = "Fecha" })
		App.live(function(gg: any)
			v.Text = Util.gameDate(gg.time.day)
			if k then
				k.Text = "FECHA · " .. Util.clock(gg.time.minute)
			end
		end)
		table.insert(items, f)
	end
	do
		local f, v = res("money", T.gr, T.gr, 0.14, deskOnly and "DINERO" or nil, Util.money(g.money), { name = "Dinero" })
		App.live(function(gg: any)
			v.Text = Util.money(gg.money)
		end)
		table.insert(items, f)
	end
	if not phone then
		local f, v = res("flask", T.vi2, T.vi, 0.18, "INVESTIGACIÓN", Util.num(g.rp) .. " PI", { name = "PI" })
		App.live(function(gg: any)
			v.Text = Util.num(gg.rp) .. " PI"
		end)
		table.insert(items, f)
		if deskWide then
			local f2 = res("users", T.pink, hex("#FF78AA"), 0.14, "PERSONAL", #g.employees .. "/" .. g.derived.caps.staff, { name = "Personal" })
			table.insert(items, f2)
		end
	end
	if not narrow then
		local f, v = res("star", T.ye, T.ye, 0.14, deskOnly and "REPUTACIÓN" or nil, Util.num(g.reputation, 1) .. " / 5", { name = "Reputacion", noIcon = not deskOnly })
		App.live(function(gg: any)
			v.Text = Util.num(gg.reputation, 1) .. " / 5"
		end)
		table.insert(items, f)
	end
	if g.demo then
		local KIND = { tutorial = "Tutorial", operacion = "Empresa en funcionamiento", avanzada = "Fábrica avanzada" }
		local chip = Ui.new("TextButton", {
			Name = "Demo",
			Text = "<b>DEMO</b>" .. (deskWide and "  · no se guarda · Salir" or ""),
			TextSize = 12,
			Weight = W.heavy,
			TextColor3 = T.ye,
			BackgroundColor3 = T.ye,
			BackgroundTransparency = 0.86,
			Size = UDim2.fromOffset(0, 30),
			AutomaticSize = Enum.AutomaticSize.X,
			Corner = 7,
			Pad = { 0, 9 },
			TextXAlignment = Enum.TextXAlignment.Center,
		})
		chip:SetAttribute("why", "Demostración «" .. (KIND[g.demo] or g.demo) .. "»: los cambios no se guardan. Tocá para salir.")
		chip.Activated:Connect(function()
			App.leaveToMenu()
		end)
		table.insert(items, chip)
	end
	table.insert(items, Ui.spacer())
	if g.time.speed == 0 and deskWide then
		table.insert(items, Ui.chip("❚❚ Simulación en pausa", "cy"))
	end
	if not narrow then
		table.insert(items, Screen.speedGroup(g, not deskOnly))
		table.insert(items, hbtn("bell", function()
			App.openDialog("notifications", {})
		end, unread, "Notificaciones"))
	end
	if deskWide then
		table.insert(items, hbtn(App.settings.sound and "sound" or "mute", function()
			App.request("setSetting", { key = "sound", value = not App.settings.sound })
		end, nil, "Sonido"))
	end
	if deskOnly then
		table.insert(items, hbtn("gear", function()
			App.ui.pop = nil
			App.openDialog("settings", { wide = true })
		end, nil, "Configuracion"))
	else
		table.insert(items, Ui.button("Menú", "p", function()
			App.ui.pop = App.ui.pop == "mob" and nil or "mob"
			Screen.renderPop()
		end, { small = true, icon = "menu", name = "MenuCelular" }))
	end
	local leftPad = phone and (narrow and 96 or 118) or 150
	return Ui.new("Frame", {
		Name = "Hud1",
		Size = UDim2.new(1, 0, 0, phone and 52 or 56),
		BackgroundColor3 = T.bg,
		BackgroundTransparency = 0.08,
		Pad = { 0, phone and 8 or 14, 0, leftPad },
		List = { dir = "H", gap = phone and (narrow and 5 or 6) or 8, v = "C" },
	}, items)
end

-- Fila 2: navegación
local function hud2(g: any): Frame
	local compact = App.layout ~= "desktop"
	local counts = Screen.counts(g)
	local route = App.ui.route
	local items: { Instance? } = {}
	local function navItem(id: string, label: string, icon: string, col: Color3, bg: Color3, a: number, key: string)
		local on = route == id
		local b = Ui.new("TextButton", {
			Name = "Nav_" .. id,
			Text = "",
			BackgroundColor3 = T.tx,
			BackgroundTransparency = on and 0 or 1,
			Size = UDim2.fromOffset(0, 42),
			AutomaticSize = Enum.AutomaticSize.X,
			Corner = 10,
			Pad = { 0, compact and 8 or 10, 0, compact and 4 or 6 },
			List = { dir = "H", gap = compact and 6 or 8, v = "C" },
		}, {
			-- «Sede» usa el color del texto (currentColor en la V3): oscuro cuando está elegida.
			Ui.ico(icon, (id == "juego" and on) and T.dark or col, bg, 28, { alpha = a, radius = 8, iconSize = 16 }),
			Ui.inline(label, { size = compact and 13 or 14, weight = W.semi, color = on and T.dark or hex("#E4E7EC") }),
		})
		local cnt = counts[id]
		if cnt then
			Ui.new("TextLabel", {
				Name = "Contador", Text = cnt[1], TextSize = 11, Weight = W.heavy, TextColor3 = cnt[4], BackgroundColor3 = cnt[2], BackgroundTransparency = cnt[3],
				Size = UDim2.fromOffset(0, 20), AutomaticSize = Enum.AutomaticSize.X, Corner = 10, Pad = { 0, compact and 5 or 7 }, TextXAlignment = Enum.TextXAlignment.Center, Parent = b,
			})
		end
		if not compact and Ui.showKeys then
			Ui.kbd(key, false).Parent = b
		end
		if not on then
			b.MouseEnter:Connect(function()
				b.BackgroundColor3 = hex("#FFFFFF")
				b.BackgroundTransparency = 0.95
			end)
			b.MouseLeave:Connect(function()
				b.BackgroundColor3 = T.tx
				b.BackgroundTransparency = 1
			end)
		end
		b.Activated:Connect(function()
			App.go(id)
		end)
		table.insert(items, b)
	end
	navItem("juego", "Sede", "home", T.tx, hex("#FFFFFF"), 0.08, "0")
	for i, n in Screen.NAV do
		navItem(n[1], n[2], n[3], n[4], n[5], n[6], tostring(i))
	end
	local more = Ui.new("TextButton", {
		Name = "Mas",
		Text = "",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(0, 42),
		AutomaticSize = Enum.AutomaticSize.X,
		Corner = 10,
		Pad = { 0, 10, 0, 10 },
		List = { dir = "H", gap = 8, v = "C" },
	}, { Ui.inline("Más", { size = compact and 13 or 14, weight = W.semi, color = hex("#E4E7EC") }), Ui.icon("down", 14, hex("#E4E7EC")) })
	more.Activated:Connect(function()
		App.ui.popX = more.AbsolutePosition.X
		App.ui.pop = App.ui.pop == "more" and nil or "more"
		Screen.renderPop()
	end)
	table.insert(items, more)
	return Ui.new("ScrollingFrame", {
		Name = "Hud2",
		Size = UDim2.new(1, 0, 0, 52),
		Position = UDim2.fromOffset(0, 56),
		BackgroundColor3 = hex("#0C0E14"),
		BackgroundTransparency = 0.14,
		ScrollingDirection = Enum.ScrollingDirection.X,
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollBarThickness = 0,
		Pad = { 0, 14, 0, 150 },
		List = { dir = "H", gap = 4, v = "C" },
	}, items)
end

-- Menús emergentes («Más» y menú de celular) en la capa de menús.
local function popItem(label: string, onClick: () -> (), right: Instance?, icon: string?, iconColor: Color3?): TextButton
	local b = Ui.new("TextButton", {
		Name = "Item_" .. label,
		Text = "",
		BackgroundColor3 = hex("#FFFFFF"),
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 42),
		Corner = 8,
		Pad = { 0, 10 },
		List = { dir = "H", gap = 10, v = "C" },
	}, {
		icon and Ui.icon(icon, 18, iconColor or T.tx) or nil,
		Ui.grow(Ui.inline(label, { size = 15, weight = W.semi })),
		right,
	})
	b.MouseEnter:Connect(function()
		b.BackgroundTransparency = 0.94
	end)
	b.MouseLeave:Connect(function()
		b.BackgroundTransparency = 1
	end)
	b.Activated:Connect(function()
		App.ui.pop = nil
		Screen.renderPop()
		onClick()
	end)
	return b
end

function Screen.renderPop()
	local layer = App.popLayer
	for _, c in layer:GetChildren() do
		c:Destroy()
	end
	local g = App.g
	local pop = App.ui.pop
	if not g or not pop then
		return
	end
	local catcher = Ui.new("TextButton", { Name = "CerrarMenu", Text = "", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = layer })
	catcher.Activated:Connect(function()
		App.ui.pop = nil
		Screen.renderPop()
	end)
	local panel = Ui.new("Frame", {
		Name = pop == "more" and "MenuMas" or "MenuCelular",
		BackgroundColor3 = T.p1,
		BackgroundTransparency = 0,
		Corner = 12,
		Stroke = T.line,
		Pad = 6,
		List = { dir = "V", gap = 0 },
		Parent = layer,
	})
	if pop == "more" then
		local ready = Rules.readyMissions(g)
		panel.Size = UDim2.fromOffset(260, 0)
		panel.AutomaticSize = Enum.AutomaticSize.Y
		panel.Position = UDim2.fromOffset(math.min(App.ui.popX or (App.vw - 300), App.vw - 300), 110)
		popItem("Misiones", function()
			App.go("misiones")
		end, Ui.chip(ready .. " listas", "cv")).Parent = panel
		popItem("Estadísticas y finanzas", function()
			App.go("estadisticas")
		end).Parent = panel
		popItem("Noticias del sector", function()
			App.ui.newsHidden = not App.ui.newsHidden
			App.forceRender()
		end).Parent = panel
		popItem("Recompensa diaria", function()
			App.openDialog("daily", {})
		end).Parent = panel
		popItem("Tienda", function()
			App.openDialog("future", { what = "tienda" })
		end, Ui.inline("sin compras reales", { size = Ui.S.xs, color = T.mut })).Parent = panel
		popItem("Ayuda", function()
			App.openDialog("help", { screen = App.ui.route })
		end).Parent = panel
		popItem("Volver al menú de empresas", function()
			App.leaveToMenu()
		end).Parent = panel
	else
		panel.Position = UDim2.fromOffset(8, 58)
		panel.Size = UDim2.new(1, -16, 0, 0)
		panel.AutomaticSize = Enum.AutomaticSize.Y
		local counts = Screen.counts(g)
		local cells = {}
		local function cell(label: string, icon: string, col: Color3?, onClick: () -> (), chip: Instance?)
			local b = Ui.new("TextButton", {
				Name = "Celda_" .. label, Text = "", BackgroundColor3 = T.p2, BackgroundTransparency = 0, Size = UDim2.new(1, 0, 0, 56), Corner = 10, Stroke = T.line2, Pad = { 0, 12 }, List = { dir = "H", gap = 10, v = "C" },
			}, { Ui.icon(icon, 18, col or T.tx), Ui.inline(label, { size = 15, weight = W.semi }), chip })
			b.Activated:Connect(function()
				App.ui.pop = nil
				Screen.renderPop()
				onClick()
			end)
			table.insert(cells, b)
		end
		cell("Sede", "home", nil, function()
			App.go("juego")
		end)
		for _, n in Screen.NAV do
			cell(n[2], n[3], n[4], function()
				App.go(n[1])
			end, counts[n[1]] and Ui.chip(counts[n[1]][1], "cg") or nil)
		end
		cell("Misiones", "flag", nil, function()
			App.go("misiones")
		end)
		cell("Estadísticas", "chart", nil, function()
			App.go("estadisticas")
		end)
		local unread = 0
		for _, n in g.notifications do
			if not n.read then
				unread += 1
			end
		end
		cell("Avisos", "bell", nil, function()
			App.openDialog("notifications", {})
		end, unread > 0 and Ui.chip(tostring(unread), "cv") or nil)
		cell("Diaria", "gift", nil, function()
			App.openDialog("daily", {})
		end)
		cell("Configuración", "gear", nil, function()
			App.openDialog("settings", { wide = true })
		end)
		cell("Menú de empresas", "left", nil, function()
			App.leaveToMenu()
		end)
		local scroller = Ui.new("ScrollingFrame", { Name = "Opciones", Size = UDim2.new(1, 0, 0, math.min(App.vh - 140, 6 * 66 + 12)), Pad = 4, List = { dir = "V", gap = 10 }, Parent = panel })
		Ui.grid(cells, 2, nil, 10).Parent = scroller
		Ui.row({ Ui.grow(Ui.text("Velocidad", { size = Ui.S.sm, color = T.mut })), Screen.speedGroup(g) }, 10, { Pad = { 8, 8, 4, 8 }, Parent = panel })
	end
end

-- Tarjetas laterales de la sede ---------------------------------------------------------------------
local function chevron(down: boolean): Frame
	return Ui.icon(down and "down" or "up", 16, hex("#8E95A3"))
end

local function hcCard(name: string, children: { Instance? }, border: Color3?, ba: number?): Frame
	return Ui.new("Frame", {
		Name = name,
		BackgroundColor3 = hex("#0C0E13"),
		BackgroundTransparency = 0.08,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Corner = 14,
		Stroke = border and { border, 1, ba or 0 } or hex("#2A2E39"),
		List = { dir = "V", gap = 0 },
		ClipsDescendants = true,
	}, children)
end

local function cardHead(key: string, icon: string, col: Color3, bg: Color3, a: number, kicker: string, title: string): TextButton
	local coll = App.ui.collapsed[key] == true
	local b = Ui.new("TextButton", {
		Name = "Cabecera_" .. key,
		Text = "",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Pad = { 12, 14 },
		List = { dir = "H", gap = 10, v = "C" },
	}, {
		Ui.ico(icon, col, bg, 32, { alpha = a, iconSize = 16 }),
		Ui.grow(Ui.col({ Ui.lbl(kicker, nil, 10), Ui.text(title, { size = 14, weight = W.bold }) }, 1)),
		chevron(coll),
	})
	b.Activated:Connect(function()
		App.ui.collapsed[key] = not coll
		App.forceRender()
	end)
	return b
end

local function hb(children: { Instance? }): Frame
	return Ui.col(children, 9, { Name = "Cuerpo", Pad = { 0, 14, 14, 14 } })
end

local function objectiveBody(g: any): Frame?
	local m = Screen.objective(g)
	if not m.id then
		return nil
	end
	local v = Rules.missionValue(g, m)
	local st = Rules.missionState(g, m)
	local tut = m.kind == "tutorial" and not g.tutorial.skipped
	local money = m.counter == "marginToday"
	local bar = Ui.bar(math.min(1, v / m.goal) * 100, st == "lista" and T.gr or nil)
	local nodes: { Instance? } = {
		Ui.row({ Ui.grow(bar, { Size = UDim2.new(0, 0, 0, 7) }), Ui.inline((money and Util.money(math.min(v, m.goal)) or tostring(math.min(v, m.goal))) .. "/" .. (money and Util.money(m.goal) or tostring(m.goal)), { size = Ui.S.sm, weight = W.bold }) }, 10),
		Ui.between("Recompensa", Rules.rewardText(m.reward), { size = Ui.S.xs, color = T.gr }),
	}
	if st == "lista" then
		local claim
		claim = Ui.button("Reclamar recompensa", "g", function()
			App.request("claimMission", { id = m.id }, { button = claim })
		end, { small = true, icon = "check", fill = true, name = "Reclamar" })
		table.insert(nodes, claim)
	else
		table.insert(nodes, Ui.row({
			Ui.button("Ir", "p", function()
				App.go(m.go)
			end, { small = true, name = "IrObjetivo" }),
			(tut and g.tutorial.tips ~= false) and Ui.button("Entendido", "default", function()
				App.request("setTutorial", { tips = false })
			end, { small = true, name = "Entendido" }) or nil,
			tut and Ui.button("Saltar tutorial", "q", Screen.askSkipTutorial, { small = true, name = "SaltarTutorial" }) or nil,
		}, 10))
	end
	return Ui.col(nodes, 9)
end

function Screen.askSkipTutorial()
	App.openDialog("confirm", {
		title = "¿Saltar el tutorial?",
		body = "Se ocultan las guías. <b>No</b> se completan objetivos ni se entregan recompensas: las misiones del tutorial siguen en Misiones y se cumplen haciendo cada acción. Podés reactivar las guías desde Misiones.",
		okLabel = "Saltar tutorial",
		onOk = function()
			App.request("setTutorial", { skipped = true })
		end,
	})
end

local function leftCards(g: any): { Instance }
	local out = {}
	local tut = Rules.currentTutorial(g)
	local inTut = tut ~= nil and not g.tutorial.skipped
	local m = Screen.objective(g)
	local tutIndex = 0
	if inTut then
		for _, x in Catalog.MISSIONS do
			if x.kind == "tutorial" then
				tutIndex += 1
				if x.id == tut.id then
					break
				end
			end
		end
	end
	local coll = App.ui.collapsed
	-- Objetivo
	local obj = hcCard("Objetivo", {
		cardHead("obj", "flag", T.vi2, T.vi, 0.2, inTut and ("Tutorial · paso " .. tutIndex .. " de 5") or "Objetivo actual", m.title),
		(not coll.obj) and hb({ Ui.text(m.desc, { size = Ui.S.sm, color = T.mut, lineHeight = 1.4 }), objectiveBody(g) }) or nil,
	}, inTut and T.vi or nil, inTut and 0.4 or nil)
	table.insert(out, obj)
	-- Últimos 7 días
	local f = Rules.finance(g, 7)
	local net = f.cash
	local week = hcCard("Semana", {
		cardHead("week", "chart", T.gr, T.gr, 0.15, "Últimos 7 días de juego", f.units .. " auto" .. (f.units == 1 and "" or "s") .. " vendido" .. (f.units == 1 and "" or "s")),
		(not coll.week) and hb({
			Ui.between("Ingresos por venta", Util.money(f.revenue)),
			Ui.between("Costo de lo vendido", Util.money(-f.cogs), { color = T.or_ }),
			Ui.between("Margen bruto", Util.money(f.margin), { color = f.margin >= 0 and T.gr or T.re2 }),
			Ui.hr(),
			Ui.between("Flujo de caja neto", (net >= 0 and "▲ +" or "▼ ") .. Util.money(math.abs(net)), { size = 15, leftColor = T.tx, leftWeight = W.bold, color = net >= 0 and T.gr or T.re2 }),
			Ui.between("Cuota de mercado estimada", Util.num(f.share, 1) .. "%"),
			f.demo and Ui.text("Incluye ventas de demostración", { size = Ui.S.xs, color = T.ye }) or nil,
			Ui.button("Ver estadísticas", "default", function()
				App.go("estadisticas")
			end, { small = true, fill = true }),
		}) or nil,
	})
	table.insert(out, week)
	-- Alerta
	local alert = Screen.topAlert(g)
	if alert then
		local b = Ui.new("TextButton", {
			Name = "Alerta",
			Text = "",
			BackgroundColor3 = hex("#0C0E13"),
			BackgroundTransparency = 0.08,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Corner = 14,
			Stroke = { alert.border, 1, 1 - alert.ba },
			Pad = { 12, 14 },
			List = { dir = "H", gap = 10, v = "C" },
		}, {
			Ui.ico(alert.icon, alert.col, alert.bg, 32, { alpha = alert.a, iconSize = 16 }),
			Ui.grow(Ui.col({ Ui.text(alert.title, { size = Ui.S.sm, weight = W.bold }), Ui.text(alert.text, { size = Ui.S.xs, color = T.mut }) }, 2)),
			Ui.icon("right", 16, hex("#8E95A3")),
		})
		b.Activated:Connect(function()
			App.go(alert.go)
		end)
		table.insert(out, b)
	end
	-- Sede
	local nx = Rules.nextSede(g)
	local sedeBody: Instance
	if nx then
		local s1 = math.clamp(g.counters.unitsSold / math.max(1, nx.req.sold), 0, 1)
		local s2 = math.clamp(g.money / nx.cost, 0, 1)
		local s3 = math.clamp(g.reputation / math.max(0.1, nx.req.rep), 0, 1)
		local pct = Util.round((s1 + s2 + s3) / 3 * 100)
		sedeBody = Ui.col({
			Ui.row({ Ui.grow((Ui.bar(pct, T.ye))), Ui.inline(pct .. "%", { size = Ui.S.sm, weight = W.bold }) }, 10),
			Ui.text("Próxima: <b><font color=\"#F5F7FA\">" .. nx.name .. "</font></b> · " .. g.counters.unitsSold .. "/" .. nx.req.sold .. " autos vendidos · reputación " .. Util.num(g.reputation, 1) .. "/" .. Util.num(nx.req.rep, 1) .. " · costo " .. Util.money(nx.cost), { size = Ui.S.xs, color = T.mut, lineHeight = 1.4 }),
		}, 9)
	else
		sedeBody = Ui.text("Sede máxima alcanzada.", { size = Ui.S.sm })
	end
	table.insert(out, hcCard("Sede", {
		cardHead("sede", "building", T.ye, T.ye, 0.15, "Sede · nivel " .. g.sede, g.derived.sedeName),
		(not coll.sede) and hb({ sedeBody }) or nil,
	}))
	return out
end

local function saleCards(g: any, list: { any }): { Instance }
	local out = {}
	if #list == 0 then
		table.insert(out, hcCard("SinVentas", {
			Ui.col({
				Ui.icon("car", 22, T.mut),
				Ui.text("Todavía no tenés autos a la venta", { size = Ui.S.sm, weight = W.bold, align = "C" }),
				Ui.text("Fabricá una unidad y enviala al salón o publicala en el mercado.", { size = Ui.S.xs, color = T.mut, align = "C" }),
			}, 8, { h = "C", Pad = 22 }),
		}))
		return out
	end
	local show = App.ui.allSale and #list or math.min(4, #list)
	for i = 1, show do
		local u = list[i]
		local rev, mar, sold = 0, 0, 0
		for _, s in g.sales do
			if u.designId and s.designId == u.designId then
				rev += s.price
				mar += s.margin
				sold += 1
			end
		end
		local stock = 0
		for _, x in g.units do
			if x.status ~= "vendido" and ((u.designId and x.designId == u.designId) or x.id == u.id) then
				stock += 1
			end
		end
		local dem = Rules.interest(g, u, nil)
		local rating = Util.num(math.clamp(2.5 + (u.quality or 50) / 40, 1, 5), 1)
		local function col3(label: string, value: string, color: Color3?)
			return Ui.col({ Ui.text(label, { size = Ui.S.xs, color = T.mut }), Ui.text(value, { size = Ui.S.xs, weight = W.bold, color = color }) }, 1)
		end
		local card = Ui.new("TextButton", {
			Name = "EnVenta_" .. u.serial,
			Text = "",
			BackgroundColor3 = hex("#0C0E13"),
			BackgroundTransparency = 0.08,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Corner = 14,
			Stroke = hex("#2A2E39"),
			Pad = 12,
			List = { dir = "V", gap = 7 },
		}, {
			Ui.row({
				Ui.paintChip(u.spec, 42, 28),
				Ui.grow(Ui.col({
					Ui.text(u.name .. " <font color=\"#A3AAB8\" size=\"11\">" .. u.serial .. "</font>", { size = Ui.S.sm, weight = W.bold }),
					Ui.text("<font color=\"#F7C95C\">★ " .. rating .. "</font> · " .. sold .. " vendidos · " .. (u.status == "salon" and "en el salón" or "en el mercado"), { size = Ui.S.xs, color = T.mut }),
				}, 1)),
			}, 10),
			Ui.grid({ col3("Ingresos", Util.money(rev)), col3("Margen", (mar < 0 and "▼ " or "▲ ") .. Util.money(mar), mar < 0 and T.re2 or T.gr), col3("Stock", tostring(stock)) }, 3, nil, 10),
			Ui.row({
				Ui.inline("Demanda", { size = Ui.S.xs, color = T.mut, width = 62 }),
				Ui.grow((Ui.bar(dem, dem > 66 and T.gr or (dem > 33 and T.bl or T.ye)))),
				Ui.inline(dem > 66 and "Alta" or (dem > 33 and "Media" or "Baja"), { size = Ui.S.xs, weight = W.bold }),
			}, 10),
		})
		card.Activated:Connect(function()
			App.openDialog("unitDetail", { unitId = u.id, wide = true })
		end)
		table.insert(out, card)
	end
	if #list > 4 then
		local more = Ui.button(App.ui.allSale and "Mostrar menos" or ("Ver las " .. #list .. " unidades"), "default", function()
			App.ui.allSale = not App.ui.allSale
			App.forceRender()
		end, { small = true, fill = true })
		table.insert(out, more)
	end
	return out
end

-- Cinta de noticias que se desplaza (.ticker)
local function ticker(g: any): Frame
	local items = {}
	local last = g.sales[#g.sales]
	if last then
		table.insert(items, { "TU EMPRESA", "#B3AAFF", g.company.name .. " vendió " .. last.name .. " por " .. Util.money(last.price) .. "." })
	end
	for _, n in Catalog.NEWS_POOL do
		table.insert(items, n)
	end
	table.insert(items, { "TU EMPRESA", "#B3AAFF", "Flujo de caja neto de los últimos 7 días: " .. Util.money(Rules.finance(g, 7).cash) .. "." })
	local track = Ui.new("Frame", { Name = "Cinta", Size = UDim2.fromScale(0, 1), AutomaticSize = Enum.AutomaticSize.X, List = { dir = "H", gap = 48, v = "C" }, Pad = { 0, 0, 0, 24 } })
	for _ = 1, 2 do
		for _, n in items do
			Ui.inline("<font size=\"11\" color=\"" .. n[2] .. "\"><b>" .. n[1] .. "</b></font>  " .. n[3], { size = 13 }).Parent = track
		end
	end
	local window = Ui.new("Frame", { Name = "Ventana", Size = UDim2.new(0, 0, 1, 0), ClipsDescendants = true, Flex = "fill" }, { track })
	if not Ui.reduceMotion then
		task.defer(function()
			local w = track.AbsoluteSize.X / 2
			if w > 0 and track.Parent then
				local tw = TweenService:Create(track, TweenInfo.new(70, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1), { Position = UDim2.fromOffset(-w, 0) })
				tw:Play()
				track.Destroying:Connect(function()
					tw:Cancel()
				end)
			end
		end)
	end
	local close = Ui.button("", "q", function()
		App.ui.newsHidden = true
		App.forceRender()
	end, { small = true, icon = "x", iconSize = 14, name = "OcultarNoticias" })
	return Ui.new("Frame", {
		Name = "Noticias",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 36),
		BackgroundColor3 = T.bg,
		BackgroundTransparency = 0.07,
		List = { dir = "H", gap = 0, v = "C" },
	}, {
		Ui.new("TextLabel", { Name = "Rotulo", Text = "NOTICIAS", TextSize = 11, Weight = W.heavy, TextColor3 = T.ye, BackgroundColor3 = T.p1, BackgroundTransparency = 0, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, Pad = { 0, 14 }, TextXAlignment = Enum.TextXAlignment.Center }),
		window,
		close,
	})
end

local TIPS = {
	t1 = "Abrí <b>Diseño</b> en la barra (tecla 1) o caminá hasta el escritorio con el monitor violeta y presioná <b>E</b>.",
	t2 = "Abrí <b>Personal</b> (tecla 7) y contratá a alguien de la pestaña Contratar.",
	t3 = "En <b>Fábrica</b> (tecla 3) creá una orden con tu diseño guardado.",
	t4 = "En <b>Mis autos</b> (tecla 2) enviá la unidad terminada al salón.",
	t5 = "En <b>Ventas</b> (tecla 4) respondé la oferta de un cliente.",
}

-- Construcción ---------------------------------------------------------------------------------------
function Screen.build(parent: Instance, route: string)
	local g = App.g
	local phone = App.isPhone()
	local hud = Ui.new("Frame", { Name = "Hud", Size = UDim2.new(1, 0, 0, Screen.top()), BackgroundTransparency = 1, ZIndex = 4, Parent = parent })
	local h1 = hud1(g)
	h1.Parent = hud
	Ui.new("Frame", { Name = "Borde1", Size = UDim2.new(1, 0, 0, 1), Position = UDim2.new(0, 0, 0, phone and 52 or 56), BackgroundColor3 = hex("#1C1F28"), BackgroundTransparency = 0, Parent = hud })
	if not phone then
		hud2(g).Parent = hud
		Ui.new("Frame", { Name = "Borde2", Size = UDim2.new(1, 0, 0, 1), Position = UDim2.new(0, 0, 0, 108), BackgroundColor3 = hex("#1C1F28"), BackgroundTransparency = 0, Parent = hud })
	end
	Screen.renderPop()
	if route ~= "juego" then
		return
	end

	local top = Screen.top()
	local newsOn = not App.ui.newsHidden and not phone
	local panelsOn = not App.ui.panelsHidden
	local forSale = {}
	for _, u in g.units do
		if u.status == "salon" or u.status == "mercado" then
			table.insert(forSale, u)
		end
	end
	local alert = Screen.topAlert(g)

	if panelsOn and (not phone or App.ui.sidePanel == "l") then
		local left = Ui.new("ScrollingFrame", {
			Name = "PanelIzquierdo",
			Position = phone and UDim2.fromOffset(8, top + 8) or UDim2.fromOffset(14, top + 14),
			Size = phone and UDim2.new(1, -16, 0, App.vh - 220) or UDim2.new(0, App.layout == "tablet" and 290 or 330, 0, App.vh - top - 150),
			ScrollBarThickness = 0,
			Pad = 2,
			List = { dir = "V", gap = 10 },
			ZIndex = phone and 7 or 2,
			Parent = parent,
		}, leftCards(g))
		App.keepScroll(left, "sede-izq")
	end
	if panelsOn and (not phone or App.ui.sidePanel == "r") then
		local coll = App.ui.collapsed.sale == true
		local head = Ui.new("TextButton", {
			Name = "EnVenta",
			Text = "",
			BackgroundColor3 = hex("#0C0E13"),
			BackgroundTransparency = 0.08,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Corner = 14,
			Stroke = hex("#2A2E39"),
			Pad = { 12, 14 },
			List = { dir = "H", gap = 10, v = "C" },
		}, {
			Ui.ico("tag", T.gr, T.gr, 32, { alpha = 0.15, iconSize = 16 }),
			Ui.grow(Ui.text("En venta · " .. #forSale .. " unidad" .. (#forSale == 1 and "" or "es"), { size = 15, weight = W.bold })),
			Ui.inline(coll and "Ver" or "Contraer", { size = Ui.S.xs, color = T.mut }),
			chevron(coll),
		})
		head.Activated:Connect(function()
			App.ui.collapsed.sale = not coll
			App.forceRender()
		end)
		local kids: { Instance? } = { head }
		if not coll then
			for _, c in saleCards(g, forSale) do
				table.insert(kids, c)
			end
		end
		local right = Ui.new("ScrollingFrame", {
			Name = "PanelDerecho",
			AnchorPoint = phone and Vector2.new(0, 0) or Vector2.new(1, 0),
			Position = phone and UDim2.fromOffset(8, top + 8) or UDim2.new(1, -14, 0, top + 14),
			Size = phone and UDim2.new(1, -16, 0, App.vh - 220) or UDim2.new(0, App.layout == "tablet" and 300 or 340, 0, App.vh - top - 150),
			ScrollBarThickness = 0,
			Pad = 2,
			List = { dir = "V", gap = 10 },
			ZIndex = phone and 7 or 2,
			Parent = parent,
		}, kids)
		App.keepScroll(right, "sede-der")
	end

	if phone and panelsOn then
		local pills: { Instance? } = {
			Ui.button("Objetivo", "default", function()
				App.ui.sidePanel = App.ui.sidePanel == "l" and nil or "l"
				App.forceRender()
			end, { small = true, icon = "flag", height = 40, radius = 20, name = "PildoraObjetivo" }),
			Ui.button("En venta " .. #forSale, "default", function()
				App.ui.sidePanel = App.ui.sidePanel == "r" and nil or "r"
				App.forceRender()
			end, { small = true, icon = "tag", height = 40, radius = 20, name = "PildoraVenta" }),
			alert and Ui.button("Alerta", "default", function()
				App.go(alert.go)
			end, { small = true, icon = alert.icon, height = 40, radius = 20 }) or nil,
		}
		if not App.ui.sidePanel then
			Ui.row(pills, 6, { Name = "Pildoras", Position = UDim2.fromOffset(8, top + 8), Size = UDim2.new(1, -16, 0, 0), wrap = true, Parent = parent, ZIndex = 5 })
		end
	end

	-- Ocultar / mostrar paneles (Tab)
	if not phone then
		local toggle = Ui.button(panelsOn and "Ocultar paneles" or "Mostrar paneles", "default", function()
			App.ui.panelsHidden = not App.ui.panelsHidden
			App.forceRender()
		end, { small = true, icon = panelsOn and "left" or "right", kbd = "Tab", name = "OcultarPaneles" })
		toggle.BackgroundColor3 = hex("#0C0E13")
		toggle.BackgroundTransparency = 0.12
		toggle.AnchorPoint = Vector2.new(0, 1)
		toggle.Position = UDim2.new(0, 14, 1, newsOn and -50 or -14)
		toggle.Parent = parent
	end

	-- Botón principal (.cta)
	local cta = Screen.nextAction(g)
	local ctaBtn = Ui.new("TextButton", {
		Name = "Principal",
		Text = "",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = phone and UDim2.new(0.5, 0, 1, -20) or UDim2.new(0.5, 0, 1, newsOn and -56 or -22),
		Size = UDim2.fromOffset(0, phone and 52 or 62),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = T.tx,
		BackgroundTransparency = 0,
		Corner = 16,
		Stroke = { T.tx, 6, 0.88 },
		Pad = { 0, phone and 8 or 10, 0, phone and 16 or 24 },
		List = { dir = "H", gap = 14, v = "C" },
		ZIndex = 3,
	}, {
		Ui.col({
			Ui.inline(cta.label, { size = phone and 15 or 17, weight = W.bold, color = T.dark }),
			(not phone) and Ui.inline(cta.sub, { size = 12, weight = W.semi, color = hex("#4A4F5C") }) or nil,
		}, 1, { Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY }),
		(not phone) and Ui.new("TextLabel", { Name = "Tecla", Text = cta.key or "↵", TextSize = 12, Weight = W.bold, TextColor3 = T.tx, BackgroundColor3 = T.dark, BackgroundTransparency = 0, Size = UDim2.fromOffset(44, 44), Corner = 12, TextXAlignment = Enum.TextXAlignment.Center }) or nil,
	})
	if phone then
		local mx = Instance.new("UISizeConstraint")
		mx.MaxSize = Vector2.new(math.max(160, App.vw - 260), 52)
		mx.Parent = ctaBtn
	end
	ctaBtn.Activated:Connect(function()
		Screen.runNext(g)
	end)
	ctaBtn.Parent = parent

	-- Accesos (Amigos, Evento, Diaria)
	if not phone then
		local daily = hbtn("gift", function()
			App.openDialog("daily", {})
		end, nil, "Diaria")
		if App.payload and g.daily.last ~= App.payload.today then
			Ui.new("Frame", { Name = "Punto", BackgroundColor3 = T.gr, BackgroundTransparency = 0, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 2, 0, -2), Size = UDim2.fromOffset(10, 10), Corner = 5, Parent = daily })
		end
		Ui.row({
			hbtn("users", function()
				App.openDialog("future", { what = "amigos" })
			end, nil, "Amigos"),
			hbtn("cal", function()
				App.openDialog("future", { what = "eventos" })
			end, nil, "Evento"),
			daily,
		}, 8, { Name = "Accesos", AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -14, 1, newsOn and -50 or -14), Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY, Parent = parent })
	end

	-- Noticias
	if newsOn then
		ticker(g).Parent = parent
	elseif not phone then
		local show = Ui.button("Mostrar noticias", "default", function()
			App.ui.newsHidden = false
			App.forceRender()
		end, { small = true, height = 26, size = 11, name = "MostrarNoticias" })
		show.AnchorPoint = Vector2.new(0.5, 1)
		show.Position = UDim2.new(0.5, 0, 1, 2)
		show.Parent = parent
	end

	-- Globo del tutorial
	local tut = Rules.currentTutorial(g)
	if tut and not g.tutorial.skipped and g.tutorial.tips ~= false and panelsOn and not phone then
		local entendido = Ui.button("Entendido", "p", function()
			App.request("setTutorial", { tips = false })
		end, { small = true })
		local saltar = Ui.button("Saltar tutorial", "q", Screen.askSkipTutorial, { small = true, fg = hex("#FFFFFF") })
		Ui.new("Frame", {
			Name = "GloboTutorial",
			Position = UDim2.fromOffset(360, top + 14),
			Size = UDim2.fromOffset(320, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = T.vi,
			BackgroundTransparency = 0,
			Corner = 12,
			Pad = { 12, 14 },
			List = { dir = "V", gap = 4 },
			ZIndex = 6,
			Parent = parent,
		}, {
			Ui.text("<b>Tutorial · " .. tut.title .. "</b>", { size = 13, color = hex("#FFFFFF") }),
			Ui.text(TIPS[tut.id] or tut.desc, { size = 13, color = hex("#FFFFFF"), lineHeight = 1.4 }),
			Ui.row({ entendido, saltar }, 10, { Pad = { 4, 0, 0, 0 } }),
		})
	end
end

return Screen
