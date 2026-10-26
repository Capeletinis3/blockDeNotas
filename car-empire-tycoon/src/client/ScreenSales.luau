--!strict
--[[
	Centro de ventas: cada lote se vende solo, sin negociar, según la demanda de su tipo, el atractivo
	del auto frente a los rivales, el precio, la reputación y el alcance de la sede. Por modelo se ve:
	miniatura, año/generación, precio, fabricadas, vendidas, disponibles, avance del lote, ventas por
	minuto, ingresos y resultado, estado de producción y estado comercial, con «Modificar precio» y
	«Cerrar venta». El historial conserva los lotes agotados y retirados con todos sus números.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local Rules = require(Shared.Rules)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local Sheet = require(script.Parent.ScreenSheet)
local Factory = require(script.Parent.ScreenFactory)
local T = Ui.T
local W = Ui.W

local Screen = {
	title = "Centro de ventas",
	icon = "tag",
}

-- Estados comerciales: { texto, chip }
Screen.SALE = {
	["en venta"] = { "En venta", "cg" },
	agotado = { "Agotado", "cb" },
	retirado = { "Retirado", "cn" },
}

function Screen.totalRate(g: any): number
	local total = 0
	local markets = {}
	for _, l in g.lots do
		local t = l.design.type
		markets[t] = markets[t] or Rules.market(g, t)
		total += Rules.lotSalesRate(g, l, markets[t])
	end
	return total
end

function Screen.head(g: any): { Instance }
	local n = 0
	for _, l in g.lots do
		if l.saleState == "en venta" then
			n += 1
		end
	end
	local out = { Ui.chip(n .. (n == 1 and " modelo en venta" or " modelos en venta"), "cg") }
	local camp = Rules.campaign(g)
	if camp then
		table.insert(out, Ui.chip("Campaña: " .. camp.name, "cy"))
	end
	return out
end

local function findLot(g: any, id: string): any
	for _, l in g.lots do
		if l.id == id then
			return l
		end
	end
	return nil
end

local function stat(label: string, value: string, color: Color3?, name: string?): (Frame, TextLabel)
	local v = Ui.text(value, { size = Ui.S.sm, weight = W.bold, color = color, name = name })
	return Ui.col({ Ui.text(label, { size = Ui.S.xs, color = T.mut }), v }, 1), v
end

function Screen.askClose(l: any)
	local avail = Rules.lotAvailable(l)
	local pending = Rules.lotPending(l)
	local body = "Se dejan de vender las unidades de <b>" .. l.design.name .. "</b>. "
	if avail > 0 then
		body ..= "Quedan <b>" .. Util.num(avail) .. " unidades sin vender</b>: se descartan y se pierde su costo de fabricación (" .. Util.money(avail * l.unitCost) .. "), sin reintegro. "
	else
		body ..= "No quedan unidades sin vender. "
	end
	if pending > 0 then
		body ..= "Las " .. Util.num(pending) .. " unidades que faltaban fabricar se cancelan sin costo. "
	end
	body ..= "El modelo queda como <b>Retirado</b> en el historial, con sus ventas y resultados. No se puede deshacer."
	App.openDialog("confirm", {
		title = "¿Cerrar la venta de " .. l.design.name .. "?",
		body = body,
		lines = {
			"Vendidas|" .. Util.num(l.sold),
			"Se descartan|" .. Util.num(avail),
			"Sin fabricar (se cancelan)|" .. Util.num(pending),
			"Resultado actual del lote|" .. Util.money(l.revenue - l.costSpent),
		},
		okLabel = avail > 0 and ("Cerrar venta y descartar " .. Util.num(avail)) or "Cerrar venta",
		cancel = "Volver",
		danger = true,
		onOk = function()
			App.request("closeSale", { lotId = l.id })
		end,
	})
end

local function lotCard(g: any, l: any): Frame
	local spec = l.design.spec
	local st = Screen.SALE[l.saleState] or Screen.SALE["en venta"]
	local ps = Factory.PROD[l.prodState] or Factory.PROD.cola
	local profit = l.revenue - l.costSpent
	local cQty = stat("Encargadas", Util.num(l.qty), nil, "Encargadas")
	local cProd, vProd = stat("Fabricadas", Util.num(l.produced), nil, "Fabricadas")
	local cPend, vPend = stat("Por fabricar", Util.num(Rules.lotPending(l)), nil, "Pendientes")
	local cAvail, vAvail = stat("Disponibles", Util.num(Rules.lotAvailable(l)), nil, "Disponibles")
	local cSold, vSold = stat("Vendidas", Util.num(l.sold), nil, "Vendidas")
	local cRate, vRate = stat("Ventas por minuto", "—", T.gr, "Ritmo")
	local cRev, vRev = stat("Ingresos", Util.money(l.revenue), T.gr, "Ingresos")
	local cCost, vCost = stat("Gastos de fabricación", Util.money(l.costSpent), T.or_, "Gastos")
	local cRes, vRes = stat("Beneficio", Util.money(profit), profit >= 0 and T.gr or T.re2, "Resultado")
	local bar, fill = Ui.bar(l.sold / math.max(1, l.qty) * 100, T.gr)
	local barText = Ui.inline("", { size = Ui.S.xs, color = T.mut, name = "Avance" })
	local function refresh(gg: any, x: any)
		vAvail.Text = Util.num(Rules.lotAvailable(x))
		vProd.Text = Util.num(x.produced)
		vPend.Text = Util.num(Rules.lotPending(x))
		vCost.Text = Util.money(x.costSpent)
		vSold.Text = Util.num(x.sold)
		local rate = Rules.lotSalesRate(gg, x)
		local avail = Rules.lotAvailable(x)
		if avail == 0 and x.prodState == "produciendo" then
			vRate.Text = Util.num(math.min(gg.derived.lineRate, Rules.lotPotentialRate(gg, x)), 1) .. " (al ritmo de la fábrica)"
		elseif avail == 0 then
			vRate.Text = "0 · sin stock (≈ " .. Util.num(Rules.lotPotentialRate(gg, x), 1) .. " con stock)"
		else
			vRate.Text = Util.num(rate, 1)
		end
		vRev.Text = Util.money(x.revenue)
		local p = x.revenue - x.costSpent
		vRes.Text = Util.money(p)
		vRes.TextColor3 = p >= 0 and T.gr or T.re2
		Ui.setBar(fill, x.sold / math.max(1, x.qty) * 100)
		barText.Text = Util.round(x.sold / math.max(1, x.qty) * 100) .. " % vendido"
	end
	refresh(g, l)
	App.live(function(gg: any)
		local x = findLot(gg, l.id)
		if x then
			refresh(gg, x)
		end
	end)
	local thumb = App.isPhone() and Ui.paintChip(spec, 64, 40) or Ui.carThumb(spec, 112, 68)
	return Ui.card({
		Ui.row({
			thumb,
			Ui.grow(Ui.col({
				Ui.text(l.design.name, { size = 16, weight = W.bold }),
				Ui.text((spec.generation or (tostring(l.design.modelYear) .. " · " .. tostring(l.design.gen) .. ".ª gen.")) .. " · " .. (Catalog.TYPES[l.design.type] or l.design.type), { size = Ui.S.xs, color = T.mut }),
				Ui.row({ Ui.chip(st[1], st[2]), Ui.chip(ps[1], ps[2]) }, 6, { wrap = true }),
			}, 4)),
			Ui.col({
				Ui.inline("Precio", { size = Ui.S.xs, color = T.mut }),
				Ui.inline(Util.money(l.price), { size = 18, weight = W.bold, name = "PrecioModelo" }),
				Ui.inline("costo " .. Util.money(l.unitCost) .. " · ref. " .. Util.money(l.refPrice), { size = Ui.S.xs, color = T.mut }),
			}, 1, { Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY, h = App.isPhone() and "L" or "R" }),
		}, 12, { wrap = App.isPhone() }),
		Ui.grid({ cQty, cProd, cPend, cAvail, cSold, cRate, cRev, cCost, cRes }, App.isPhone() and 3 or (App.layout == "desktop" and 9 or 5), nil, 10),
		Ui.row({ Ui.grow(bar), barText }, 10),
		l.price < l.unitCost and Ui.note("r", "El precio está por debajo del costo: cada venta pierde " .. Util.money(l.unitCost - l.price) .. ".") or nil,
		Ui.row({
			Ui.button("Modificar precio", "default", function()
				App.openDialog("price", { lotId = l.id })
			end, { small = true, icon = "tag", iconSize = 14, name = "ModificarPrecio" }),
			Ui.spacer(),
			Ui.button("Cerrar venta", "d", function()
				Screen.askClose(l)
			end, { small = true, icon = "x", iconSize = 14, name = "CerrarVenta" }),
		}, 8, { wrap = true }),
	}, { gap = 10, pad = { 12, 14 }, name = "Modelo_" .. l.id })
end

local function historyRow(l: any): Frame
	local st = Screen.SALE[l.saleState] or Screen.SALE.agotado
	local profit = l.revenue - l.costSpent
	return Ui.card({
		Ui.row({
			Ui.paintChip(l.design.spec, 30, 20),
			Ui.grow(Ui.col({
				Ui.text(l.design.name .. " <font color=\"#A3AAB8\" size=\"11\">" .. (l.design.spec.generation or "") .. "</font>", { size = Ui.S.sm, weight = W.bold }),
				Ui.text(Util.gameDate(l.createdDay) .. " → " .. Util.gameDate(l.endDay or l.createdDay) .. " · " .. Util.num(l.sold) .. " vendidas de " .. Util.num(l.produced) .. " fabricadas" .. ((l.discarded or 0) > 0 and (" · " .. Util.num(l.discarded) .. " descartadas") or "") .. " · a " .. Util.money(l.price), { size = Ui.S.xs, color = T.mut }),
			}, 1)),
			Ui.col({
				Ui.chip(st[1], st[2]),
				Ui.inline((profit >= 0 and "+" or "") .. Util.money(profit), { size = Ui.S.sm, weight = W.bold, color = profit >= 0 and T.gr or T.re2 }),
			}, 3, { Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY, h = "R" }),
		}, 10, { wrap = App.isPhone() }),
	}, { gap = 4, pad = { 10, 12 }, name = "Historial_" .. l.id })
end

function Screen.build(main: Frame, side: Frame)
	local g = App.g
	local selling, done = {}, {}
	for _, l in g.lots do
		if l.saleState == "en venta" then
			table.insert(selling, l)
		end
	end
	for _, l in g.lotHistory do
		table.insert(done, l)
	end
	local tabs, tab = Sheet.tabs("ventas", { { "venta", "En venta", #selling }, { "historial", "Agotados y retirados", #done } }, "venta")
	tabs.Parent = main
	if tab == "venta" then
		if #selling == 0 then
			Ui.empty("tag", "No hay modelos a la venta. Lanzá un lote en Producción: cada auto terminado se vende solo.", Ui.button("Lanzar lote", "p", function()
				App.openDialog("lot", { wide = true })
			end, { small = true, name = "LanzarLote" })).Parent = main
		end
		for _, l in selling do
			lotCard(g, l).Parent = main
		end
	else
		if #done == 0 then
			Ui.empty("box", "Todavía no hay lotes terminados. Un lote queda «Agotado» al venderse todo, o «Retirado» si cerrás su venta.").Parent = main
		end
		for _, l in done do
			historyRow(l).Parent = main
		end
		if #done > 0 then
			Ui.text("Se conservan los últimos " .. Catalog.RULES.maxLotHistory .. " lotes. Los totales de la empresa (Estadísticas) incluyen todos.", { size = Ui.S.xs, color = T.mut }).Parent = main
		end
	end

	-- Columna lateral
	local rateLabel = Ui.text(Util.num(Screen.totalRate(g), 1) .. " autos/min", { size = 22, weight = W.bold, color = T.gr, name = "RitmoTotal" })
	App.live(function(gg: any)
		rateLabel.Text = Util.num(Screen.totalRate(gg), 1) .. " autos/min"
	end)
	local f = Rules.finance(g, 3)
	Ui.card({
		Ui.lbl("Ritmo de ventas"),
		rateLabel,
		Ui.between("Vendidos (últimos 3 meses)", Util.num(f.units)),
		Ui.between("Ingresos (últimos 3 meses)", Util.money(f.revenue), { color = T.gr }),
		Ui.between("Margen de lo vendido", Util.money(f.margin), { color = f.margin >= 0 and T.gr or T.re2 }),
	}, { gap = 6, name = "Ritmo" }).Parent = side
	-- Campaña publicitaria por niveles: cada uno requiere su investigación; el primer mes se paga al activarla.
	local cur = tonumber(g.promo) or 0
	local opts: { Instance? } = {}
	table.insert(opts, Ui.opt("Sin campaña", cur == 0, function()
		App.request("setCampaign", { level = 0 })
	end, { height = 34, fill = true, name = "Campana_0" }))
	for _, c in Catalog.CAMPAIGNS do
		local why = Rules.campaignBlock(g, c.level)
		table.insert(opts, Ui.opt(c.name .. " · +" .. Util.round(c.boost * 100) .. " % · " .. Util.money(Rules.campaignCost(g, c.level)) .. "/mes", cur == c.level, function()
			App.request("setCampaign", { level = c.level })
		end, { height = 34, fill = true, autoY = true, name = "Campana_" .. c.level, disabled = why ~= nil, why = why }))
	end
	Ui.card({
		Ui.lbl("Campaña publicitaria"),
		Ui.text("Suma atractivo a todos tus autos en venta. Se paga cada mes; al activarla o subir de nivel se cobra el primer mes enseguida.", { size = Ui.S.xs, color = T.mut }),
		Ui.col(opts, 6),
	}, { gap = 8, name = "Campana" }).Parent = side
	Ui.card({
		Ui.lbl("Qué hace vender un auto"),
		Ui.text("• <b>Demanda</b> del tipo de vehículo en el año actual (Mercado).\n• <b>Atractivo</b>: calidad y prestaciones según el objetivo del diseño, frente a lo que el mercado espera en esa época.\n• <b>Precio</b>: por encima del de referencia vende menos; por debajo, más.\n• <b>Reputación</b> (" .. Util.num(g.reputation, 1) .. "/5) y <b>alcance</b> de la sede (×" .. Util.num(Rules.sede(g).reach, 1) .. ").\n• <b>Rivales</b>: marcas que venden el mismo tipo.\nNo hay negociación: lo terminado se vende solo.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.45 }),
	}, { gap = 4, name = "QueVende" }).Parent = side
end

return Screen
