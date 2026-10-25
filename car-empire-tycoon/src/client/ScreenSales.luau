--!strict
-- Ventas y concesionario (SCREENS.ventas de la V3): clientes y ofertas, salón con precio de lista,
-- descuento y precio final, promoción, mayorista, historial con búsqueda y filtros, y movimientos.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local Rules = require(Shared.Rules)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local Sheet = require(script.Parent.ScreenSheet)
local Inventory = require(script.Parent.ScreenInventory)
local T = Ui.T
local W = Ui.W

local Screen = {
	title = "Ventas y concesionario",
	icon = "tag",
	color = Color3.fromHex("#42E58D"),
	bg = Color3.fromHex("#13301F"),
}

local CHANNEL = { concesionario = "Concesionario", mercado = "Mercado", mayorista = "Mayorista" }

function Screen.head(g: any): { Instance }
	return { Ui.chip("Salón " .. g.derived.showroomUsed .. "/" .. g.derived.caps.showroom, "cg"), g.promo and Ui.chip("Promoción activa", "cy") or nil :: any }
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
		local accept
		accept = Ui.button("Aceptar " .. Util.money(c.offer), "g", function()
			App.request("acceptOffer", { customerId = c.id }, { button = accept })
		end, { small = true, name = "Aceptar_" .. c.id })
		table.insert(actions, accept)
		table.insert(actions, Ui.button("Negociar", "p", function()
			App.openDialog("counter", { customerId = c.id, wide = true })
		end, { small = true }))
		table.insert(actions, Ui.button("Rechazar", "q", function()
			App.request("rejectCustomer", { customerId = c.id })
		end, { small = true }))
	end
	if u then
		table.insert(actions, Ui.button("Ver el auto", "q", function()
			App.openDialog("unitDetail", { unitId = u.id, wide = true })
		end, { small = true, icon = "eye" }))
	end
	local card = Ui.card({
		Ui.row({
			Ui.ico("user", T.pink, Color3.fromHex("#33182A"), 32),
			Ui.grow(Ui.col({
				Ui.text(c.name, { size = 15, weight = W.bold }),
				Ui.text("Busca " .. string.lower(Catalog.TYPES[c.wants] or c.wants) .. " · valora " .. (Catalog.PREF_LABEL[c.pref] or c.pref) .. " · interés " .. c.interest .. "%" .. (u and (" · mira el " .. u.name .. " (" .. u.serial .. ")") or ""), { size = Ui.S.xs, color = T.mut }),
			}, 2)),
			stateChip,
		}, 10),
		(c.state == "oferta" and u) and Ui.row({
			Ui.inline("Lista " .. Util.money(u.price), { size = Ui.S.xs, color = T.mut }),
			Ui.inline("Final " .. Util.money(Rules.finalPrice(u)), { size = Ui.S.xs, color = T.mut }),
			Ui.inline("Oferta " .. Util.money(c.offer), { size = Ui.S.xs, weight = W.bold }),
			Ui.inline("Margen si aceptás " .. Util.money(c.offer - u.cost), { size = Ui.S.xs, color = c.offer - u.cost >= 0 and T.gr or T.re2, weight = W.bold }),
		}, 14, { wrap = true }) or nil,
		(not gone) and Ui.row({ Ui.inline("Paciencia", { size = Ui.S.xs, color = T.mut }), Ui.grow(patienceBar, { Size = UDim2.new(0, 0, 0, 7) }), patienceLabel }, 8) or nil,
		#actions > 0 and Ui.row(actions, 6, { wrap = true }) or nil,
	}, { gap = 8, stroke = c.state == "oferta" and Color3.fromHex("#22406E") or nil, name = "Cliente_" .. c.id })
	if gone then
		card.BackgroundTransparency = 0.45
	end
	return card
end

-- Tarjeta del salón con precio de lista editable, descuento, precio final, margen y demanda.
local function showCard(g: any, u: any): Frame
	local fp = Rules.finalPrice(u)
	local dem = Rules.interest(g, u, nil)
	local priceBox = Ui.input(tostring(u.price), "Precio de lista", function(text: string)
		local n = tonumber((string.gsub(text, "[^%d]", "")))
		if n and n ~= u.price then
			App.request("setPrice", { unitId = u.id, price = n })
		elseif not n then
			App.forceRender()
		end
	end, { width = 140, height = 36 })
	local discs = {}
	for _, d in { 0, 5, 10, 15, 20, 30 } do
		table.insert(discs, Ui.opt(d .. "%", u.discount == d, function()
			App.request("setDiscount", { unitId = u.id, discount = d })
		end, { height = 32, width = 46 }))
	end
	local demBar = Ui.bar(dem, dem > 66 and T.gr or (dem > 33 and T.bl or T.ye))
	return Ui.card({
		Ui.row({ Ui.carThumb(u.spec, 84, 50), Ui.grow(Ui.col({ Ui.text(u.name .. "  <font color=\"#7D8493\">" .. u.serial .. "</font>", { size = 15, weight = W.bold }), Ui.text("Recomendado " .. Util.money(u.stats.price) .. " · costo " .. Util.money(u.cost), { size = Ui.S.xs, color = T.mut }) }, 2)), Ui.chip("En el salón", "cg") }, 10),
		Ui.row({ Ui.inline("Precio de lista", { size = Ui.S.xs, color = T.mut }), priceBox, Ui.inline("Descuento", { size = Ui.S.xs, color = T.mut }), Ui.row(discs, 4, { Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY }) }, 8, { wrap = true }),
		Ui.row({
			Ui.inline("Precio final " .. Util.money(fp), { size = 15, weight = W.bold }),
			Ui.inline("Margen " .. Util.money(fp - u.cost), { size = Ui.S.sm, color = fp - u.cost >= 0 and T.gr or T.re2, weight = W.bold }),
		}, 16, { wrap = true }),
		Ui.row({ Ui.inline("Demanda", { size = Ui.S.xs, color = T.mut }), Ui.grow(demBar, { Size = UDim2.new(0, 0, 0, 7) }), Ui.inline(dem .. "/100", { size = Ui.S.xs, weight = W.bold }) }, 8),
		Ui.text("Un precio final por encima del recomendado baja el interés de los clientes; un descuento lo sube.", { size = Ui.S.xs, color = T.mut }),
		Ui.row({
			table.unpack(Inventory.unitActions(g, u, true)),
		}, 6, { wrap = true }),
		Ui.row({
			Ui.button("Mayorista · " .. Util.money(Rules.wholesale(u)), "default", function()
				App.openDialog("wholesale", { unitId = u.id })
			end, { small = true }),
			Ui.button("Detalle", "q", function()
				App.openDialog("unitDetail", { unitId = u.id, wide = true })
			end, { small = true, icon = "eye" }),
		}, 6, { wrap = true }),
	}, { gap = 8, name = "Salon_" .. u.serial })
end

function Screen.build(main: Frame, side: Frame)
	local g = App.g
	local offers = 0
	for _, c in g.customers do
		if c.state == "oferta" then
			offers += 1
		end
	end
	local tabs, tab = Sheet.tabs("ventas", { { "salon", "Salón y clientes", offers }, { "hist", "Historial de ventas", g.counters.unitsSold }, { "mov", "Movimientos" } }, "salon")
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
			Ui.note("b", #show > 0 and "Todavía no llegó nadie. Los clientes aparecen con el tiempo de juego (probá 2× o 4×); una promoción atrae más." or "El salón está vacío. Enviá un auto desde Mis autos para que lleguen clientes.").Parent = main
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
				Ui.row({ Ui.carThumb(u.spec, 64, 38), Ui.grow(Ui.text(u.name .. "  <font color=\"#7D8493\">" .. u.serial .. " · " .. Util.money(Rules.finalPrice(u)) .. "</font>", { size = Ui.S.sm, weight = W.semi })), table.unpack(Inventory.unitActions(g, u, true)) }, 8, { wrap = true }),
			}, { pad = { 8, 12 } }).Parent = main
		end
	elseif tab == "hist" then
		Ui.row({
			Sheet.search("sal", "Buscar modelo, serie o comprador"),
			Sheet.filter("sCh", "Canal", { { "todos", "Todos" }, { "concesionario", "Concesionario" }, { "mercado", "Mercado" }, { "mayorista", "Mayorista" } }, "todos"),
			Sheet.filter("sDays", "Período", { { "0", "Todo lo guardado" }, { "7", "7 días" }, { "30", "30 días" } }, "0"),
		}, 8, { wrap = true }).Parent = main
		local ch = App.ui.filters.sCh or "todos"
		local days = tonumber(App.ui.filters.sDays or "0") or 0
		local rows: { Instance? } = {}
		for i = #g.sales, 1, -1 do
			local s = g.sales[i]
			if (ch == "todos" or s.channel == ch) and (days == 0 or s.day > g.time.day - days) and Sheet.matches("sal", s.name, s.serial, s.buyer) then
				local b = Ui.new("TextButton", { Name = "Venta_" .. s.id, Text = "", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, List = { dir = "V", gap = 0 } }, {
					Ui.line(s.name .. " v" .. tostring(s.designVersion or "—") .. "  <font color=\"#7D8493\">" .. s.serial .. " · día " .. (s.day + 1) .. " " .. (s.at or "") .. " · " .. (CHANNEL[s.channel] or s.channel) .. " · " .. tostring(s.buyer) .. "</font>", Util.money(s.price)),
					Ui.line("Costo " .. Util.money(s.cost) .. (s.fee and s.fee > 0 and (" · comisión " .. Util.money(s.fee)) or ""), "Margen " .. Util.money(s.margin), { leftColor = T.mut, color = s.margin >= 0 and T.gr or T.re2, size = Ui.S.xs }),
					Ui.hr(),
				})
				b.Activated:Connect(function()
					App.openDialog("saleDetail", { saleId = s.id })
				end)
				table.insert(rows, b)
			end
		end
		if #rows == 0 then
			Ui.note("b", #g.sales == 0 and "Todavía no hay ventas." or "No hay ventas con esos filtros.").Parent = main
		else
			Ui.card(rows, { gap = 0, pad = { 4, 14 } }).Parent = main
		end
		Ui.text("Se conservan las últimas " .. #g.sales .. " ventas con detalle. Los totales (" .. g.counters.unitsSold .. " ventas, " .. Util.money(g.counters.revenueTotal or 0) .. ") y las estadísticas por período usan agregados que no se recortan.", { size = Ui.S.xs, color = T.mut }).Parent = main
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
		Ui.text("Se muestran los últimos movimientos de dinero. Para totales por período, abrí Estadísticas.", { size = Ui.S.xs, color = T.mut }).Parent = main
	end

	-- Lateral: promoción, resumen de 7 días (misma fuente que el HUD y Estadísticas) y reglas.
	local promoOk = Rules.has(g, "mk2")
	local promoBtn
	promoBtn = Ui.button(g.promo and "Apagar promoción" or "Activar promoción", g.promo and "d" or "p", function()
		App.request("togglePromo", nil, { button = promoBtn })
	end, { small = true, disabled = not promoOk and not g.promo, why = "Requiere investigar «Promociones» (Marketing)" })
	Ui.card({
		Ui.lbl("Promoción del concesionario"),
		Ui.text("+" .. Util.round((Catalog.RULES.promoBoost - 1) * 100) .. " % de clientes. Cuesta " .. Util.money(Catalog.RULES.promoCostPerDay) .. " al empezar cada día de juego mientras esté activa; se apaga sola si no alcanza el dinero.", { size = Ui.S.xs, color = T.mut }),
		Ui.row({ g.promo and Ui.chip("Activa", "cy") or Ui.chip("Apagada", "cn"), Ui.spacer(), promoBtn }, 8),
	}, { gap = 8 }).Parent = side
	local f = Rules.finance(g, 7)
	Ui.card({
		Ui.lbl("Últimos 7 días"),
		Ui.line("Autos vendidos", tostring(f.units), { leftColor = T.mut }),
		Ui.line("Ingresos por venta", Util.money(f.revenue), { leftColor = T.mut }),
		Ui.line("Costo de lo vendido", Util.money(-f.cogs), { leftColor = T.mut, color = T.or_ }),
		Ui.hr(),
		Ui.line("Margen bruto", Util.money(f.margin), { color = f.margin >= 0 and T.gr or T.re2 }),
		Ui.button("Ver estadísticas", "q", function()
			App.go("estadisticas")
		end, { small = true, icon = "chart" }),
	}, { gap = 2 }).Parent = side
	Ui.card({
		Ui.lbl("Cómo deciden los clientes"),
		Ui.text("Cada cliente tiene un presupuesto oculto, un tipo de auto buscado, una preferencia y paciencia. El interés sube con la calidad, la reputación, el personal de ventas y si el auto coincide con lo que busca; baja si el precio final supera al recomendado. Con interés de 35 o más hace una oferta; si no respondés antes de que se le acabe la paciencia, se va.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.3 }),
	}, { gap = 6 }).Parent = side
end

return Screen
