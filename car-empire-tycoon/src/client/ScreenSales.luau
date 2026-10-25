--!strict
-- Ventas y concesionario (SCREENS.ventas de la V3): clientes, salón, historial y movimientos.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local Sheet = require(script.Parent.ScreenSheet)
local Hud = require(script.Parent.ScreenHud)
local Inventory = require(script.Parent.ScreenInventory)
local T = Ui.T
local W = Ui.W

local Screen = {
	title = "Ventas y concesionario",
	symbol = "🏷",
	color = Color3.fromHex("#42E58D"),
	bg = Color3.fromHex("#13301F"),
}

function Screen.head(g: any): { Instance }
	return { Ui.chip("Salón " .. g.derived.showroomUsed .. "/" .. g.derived.caps.showroom, "cg") }
end

local function findUnit(g: any, id: any): any
	for _, u in g.units do
		if u.id == id then
			return u
		end
	end
	return nil
end

local function custRow(g: any, c: any): Frame
	local u = findUnit(g, c.unitId)
	local gone = c.state == "se fue"
	local stateChip = gone and Ui.chip("Se fue sin comprar", "cn") or (c.state == "oferta" and Ui.chip("Ofrece " .. Util.money(c.offer), "cb") or Ui.chip("Mirando", "cn"))
	local patienceBar, patienceFill = Ui.bar(100, T.ye)
	local patienceLabel = Ui.inline("", { size = Ui.S.xs, color = T.mut })
	if not gone then
		App.live(function(gg: any)
			for _, x in gg.customers do
				if x.id == c.id then
					local left = math.max(0, x.patience - x.waited)
					Ui.setBar(patienceFill, left / math.max(1, x.patience) * 100)
					patienceLabel.Text = Util.gameDuration(left)
				end
			end
		end)
	end
	local actions: { Instance? } = {}
	if c.state == "oferta" and u then
		table.insert(actions, Ui.button("Aceptar " .. Util.money(c.offer), "g", function()
			App.request("acceptOffer", { customerId = c.id })
		end, { small = true }))
		table.insert(actions, Ui.button("Contraofertar", "p", function()
			App.openDialog("counter", { customerId = c.id })
		end, { small = true }))
		table.insert(actions, Ui.button("Rechazar", "q", function()
			App.request("rejectCustomer", { customerId = c.id })
		end, { small = true }))
	end
	local card = Ui.card({
		Ui.row({
			Ui.ico("👤", T.pink, Color3.fromHex("#33182A"), 32),
			Ui.grow(Ui.col({
				Ui.text(c.name, { size = 15, weight = W.bold }),
				Ui.text("Busca " .. string.lower(Catalog.TYPES[c.wants] or c.wants) .. " · valora " .. (Catalog.PREF_LABEL[c.pref] or c.pref) .. " · interés " .. c.interest .. "%" .. (u and (" · mira el " .. u.name .. " (" .. u.serial .. ")") or ""), { size = Ui.S.xs, color = T.mut }),
			}, 2)),
			stateChip,
		}, 10),
		(not gone) and Ui.row({ Ui.inline("Paciencia", { size = Ui.S.xs, color = T.mut }), Ui.grow(patienceBar, { Size = UDim2.new(0, 0, 0, 7) }), patienceLabel }, 8) or nil,
		#actions > 0 and Ui.row(actions, 6, { wrap = true }) or nil,
	}, { gap = 8, stroke = c.state == "oferta" and Color3.fromHex("#22406E") or nil })
	if gone then
		card.BackgroundTransparency = 0.45
	end
	return card
end

local function showCard(g: any, u: any): Frame
	local margin = u.price - u.cost
	return Ui.card({
		Ui.row({ Ui.paintChip(u.spec, 44, 28), Ui.grow(Ui.text(u.name .. "  <font color=\"#7D8493\">" .. u.serial .. "</font>", { size = 15, weight = W.bold })), Ui.chip("En el salón", "cg") }, 10),
		Ui.row({
			Ui.inline("Precio de lista " .. Util.money(u.price), { size = Ui.S.sm }),
			Ui.inline("Costo " .. Util.money(u.cost), { size = Ui.S.sm, color = T.mut }),
			Ui.inline("Margen " .. Util.money(margin), { size = Ui.S.sm, color = margin >= 0 and T.gr or T.re2, weight = W.bold }),
		}, 16),
		Ui.row(Inventory.unitActions(g, u), 6),
	}, { gap = 8 })
end

function Screen.build(main: Frame, side: Frame)
	local g = App.g
	local offers = 0
	for _, c in g.customers do
		if c.state == "oferta" then
			offers += 1
		end
	end
	local tabs, tab = Sheet.tabs("ventas", { { "salon", "Salón y clientes", offers }, { "hist", "Historial de ventas", #g.sales }, { "mov", "Movimientos" } }, "salon")
	tabs.Parent = main
	if tab == "salon" then
		local show, store = {}, {}
		for _, u in g.units do
			if u.status == "salon" then
				table.insert(show, u)
			elseif u.status == "almacen" then
				table.insert(store, u)
			end
		end
		Ui.row({ Ui.lbl("Clientes en el concesionario"), Ui.spacer(), Ui.inline("Llegan solo si hay autos en el salón", { size = Ui.S.xs, color = T.mut }) }, 8).Parent = main
		if #g.customers == 0 then
			Ui.note("b", #show > 0 and "Todavía no llegó nadie. Los clientes aparecen con el tiempo de juego (probá 2× o 4×)." or "El salón está vacío. Enviá un auto desde Mis autos para que lleguen clientes.").Parent = main
		end
		for _, c in g.customers do
			custRow(g, c).Parent = main
		end
		Ui.lbl("En exhibición (" .. #show .. "/" .. g.derived.caps.showroom .. ")").Parent = main
		if #show == 0 then
			Ui.text("Sin autos en el salón.", { size = Ui.S.sm, color = T.mut }).Parent = main
		end
		for _, u in show do
			showCard(g, u).Parent = main
		end
		Ui.lbl("En el almacén (" .. #store .. ")").Parent = main
		for _, u in store do
			Ui.card({
				Ui.row({ Ui.paintChip(u.spec, 36, 24), Ui.grow(Ui.text(u.name .. "  <font color=\"#7D8493\">" .. u.serial .. " · " .. Util.money(u.price) .. "</font>", { size = Ui.S.sm, weight = W.semi })), table.unpack(Inventory.unitActions(g, u)) }, 8),
			}, { pad = { 8, 12 } }).Parent = main
		end
	elseif tab == "hist" then
		if #g.sales == 0 then
			Ui.note("b", "Todavía no hay ventas.").Parent = main
		else
			local rows: { Instance? } = {}
			for i = #g.sales, 1, -1 do
				local s = g.sales[i]
				table.insert(rows, Ui.col({
					Ui.line(s.name .. " v" .. tostring(s.designVersion or 1) .. "  <font color=\"#7D8493\">" .. s.serial .. " · día " .. (s.day + 1) .. " " .. (s.at or "") .. " · " .. s.channel .. " · " .. s.buyer .. "</font>", Util.money(s.price)),
					Ui.line("Costo " .. Util.money(s.cost), "Margen " .. Util.money(s.margin), { leftColor = T.mut, color = s.margin >= 0 and T.gr or T.re2, size = Ui.S.xs }),
					Ui.hr(),
				}, 0))
			end
			Ui.card(rows, { gap = 0, pad = { 4, 14 } }).Parent = main
		end
	else
		local rows: { Instance? } = {}
		for i = #g.ledger, 1, -1 do
			local l = g.ledger[i]
			table.insert(rows, Ui.line(l.note .. "  <font color=\"#7D8493\">día " .. (l.day + 1) .. " · " .. Util.clock(l.min) .. " · " .. l.type .. "</font>", Util.money(l.amount), { color = l.amount >= 0 and T.gr or T.or_ }))
		end
		if #rows == 0 then
			table.insert(rows, Ui.text("Sin movimientos todavía.", { size = Ui.S.sm, color = T.mut }))
		end
		Ui.card(rows, { gap = 0, pad = { 4, 14 } }).Parent = main
		Ui.text("Se muestran los últimos 60 movimientos de dinero.", { size = Ui.S.xs, color = T.mut }).Parent = main
	end

	local wk = Hud.week(g)
	Ui.card({
		Ui.lbl("Últimos 7 días"),
		Ui.line("Autos vendidos", tostring(wk.units), { leftColor = T.mut }),
		Ui.line("Ingresos por venta", Util.money(wk.revenue), { leftColor = T.mut }),
		Ui.line("Costo de lo vendido", Util.money(-wk.cogs), { leftColor = T.mut, color = T.or_ }),
		Ui.hr(),
		Ui.line("Margen bruto", Util.money(wk.margin), { color = wk.margin >= 0 and T.gr or T.re2 }),
	}, { gap = 2 }).Parent = side
	Ui.card({
		Ui.lbl("Cómo deciden los clientes"),
		Ui.text("Cada cliente tiene un presupuesto oculto, un tipo de auto buscado, una preferencia y paciencia. El interés sube con la calidad, la reputación y si el auto coincide con lo que busca. Con interés de 35 o más hace una oferta; si no respondés antes de que se le acabe la paciencia, se va.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.3 }),
	}, { gap = 6 }).Parent = side
end

return Screen
