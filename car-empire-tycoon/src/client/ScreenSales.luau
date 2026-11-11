--!strict
--[[
	Ventas › En venta. A la izquierda, la lista compacta de modelos comercializados (por lanzar, en venta y en
	fabricación); a la derecha, el modelo elegido: vista 3D, precio actual, costo por unidad, precio recomendado,
	demanda estimada en cinco niveles, vendidas, stock, ingresos y nota de los críticos. El precio es libre y se
	escribe a mano: la demanda y el margen se recalculan en la vista previa con el modelo económico real
	(Rules.demandInfo, el mismo peso con el que reparte la demanda el servidor); el servidor valida y aplica.
	Los modelos agotados y retirados quedan en el historial.
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
local STYLE = Factory.STYLE

local Screen = {
	title = "Centro de ventas",
	icon = "tag",
	noSide = true,
}

-- Estados comerciales: { texto, chip }
Screen.SALE = ({
	produccion = { "En fabricación", "cy" },
	["por lanzar"] = { "Por lanzar · elegí el precio", "cv" },
	["en venta"] = { "En venta", "cg" },
	agotado = { "Agotado", "cb" },
	retirado = { "Retirado", "cn" },
} :: { [string]: { string } })

-- Colores de los cinco niveles de demanda (muy baja → muy alta).
local LEVEL_COLORS = { Ui.hex("#FF5F68"), Ui.hex("#FFB36B"), Ui.hex("#F7C95C"), Ui.hex("#7FE0A8"), Ui.hex("#42E58D") }

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
		table.insert(out, Ui.chip(Catalog.MARKETING.kinds[camp.kind].name .. ": " .. camp.name, "cy"))
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

-- Precio escrito → número válido (entero de dólares, positivo y dentro del tope técnico) o nil y el motivo.
function Screen.parsePrice(text: string): (number?, string?)
	if string.gsub(text or "", "%s", "") == "" then
		return nil, "Escribí un precio."
	end
	local n = Util.parseNumber(text)
	if not n then
		return nil, "El precio tiene que ser un número."
	end
	local p = Rules.validPrice(n)
	if not p then
		return nil, n <= 0 and "El precio tiene que ser mayor que cero." or "El precio supera el tope técnico."
	end
	return p, nil
end

-- Indicador de demanda: cinco segmentos y la etiqueta. Devuelve el marco y una función para actualizarlo.
function Screen.demandBars(info: any, name: string?): (Frame, (any) -> ())
	local segs: { any } = {}
	for i = 1, 5 do
		table.insert(segs, Ui.new("Frame", { Name = "Nivel_" .. i, Size = UDim2.fromOffset(22, 8), BackgroundTransparency = 0, Corner = 3 }))
	end
	local label = Ui.inline("", { size = Ui.S.sm, weight = W.bold, name = "DemandaTexto" })
	local frame = Ui.row({ Ui.row(segs, 3, { Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY }), label }, 8, { Name = name or "Demanda" })
	local function set(x: any)
		for i, s in segs do
			s.BackgroundColor3 = i <= x.level and LEVEL_COLORS[x.level] or Ui.hex("#22304A")
		end
		label.Text = x.label
		label.TextColor3 = LEVEL_COLORS[x.level]
		frame:SetAttribute("nivel", x.level)
	end
	set(info)
	return frame, set
end

--[[ Editor de precio (panel de Ventas y diálogo de precio): campo numérico libre, precio recomendado, margen
	por unidad y demanda prevista en vivo mientras se escribe. Solo envía precios válidos. ]]
function Screen.priceEditor(g: any, l: any, onDone: (() -> ())?): Frame
	local launch = l.saleState == "por lanzar"
	local current = launch and l.refPrice or l.price
	local typed = tostring(current)
	local demand, setDemand = Screen.demandBars(Rules.demandInfo(g, l, current), "DemandaPrevista")
	local margin = Ui.inline("", { size = Ui.S.sm, weight = W.bold, name = "Margen" })
	local msg = Ui.text("", { size = Ui.S.xs, color = T.re2, name = "PrecioInvalido" })
	local apply: TextButton
	local function preview(text: string)
		typed = text
		local p, why = Screen.parsePrice(text)
		if p then
			setDemand(Rules.demandInfo(g, l, p))
			local m = p - l.unitCost
			margin.Text = (m >= 0 and "+" or "−") .. Util.money(math.abs(m)) .. " por unidad"
			margin.TextColor3 = m >= 0 and T.gr or T.re2
			msg.Text = p < l.unitCost and "Por debajo del costo: cada venta pierde " .. Util.money(l.unitCost - p) .. "." or ""
			msg.TextColor3 = T.ye
		else
			margin.Text = "—"
			margin.TextColor3 = T.mut
			msg.Text = why or ""
			msg.TextColor3 = T.re2
		end
		if apply then
			Ui.setEnabled(apply, p ~= nil and (launch or p ~= l.price), p == nil and (why or "Precio inválido") or "Es el precio actual")
		end
	end
	local box = Ui.input(typed, "Precio", function(text: string)
		preview(text)
	end, { name = "Precio", width = 160, onChange = preview })
	apply = Ui.button(launch and "Poner a la venta" or "Aplicar precio", "p", function()
		local p = Screen.parsePrice(typed)
		if not p then
			return
		end
		local r = App.request(launch and "launchSale" or "setLotPrice", { lotId = l.id, price = p }, { button = apply })
		if r.ok and onDone then
			onDone()
		end
	end, { name = launch and "PonerALaVenta" or "AplicarPrecio", icon = "tag", small = true })
	local rec = Ui.button("Usar el recomendado (" .. Util.money(l.refPrice) .. ")", "default", function()
		box.Text = tostring(l.refPrice)
		preview(box.Text)
	end, { small = true, name = "PrecioReferencia" })
	preview(typed)
	return Ui.col({
		Ui.fl(launch and "Precio de lanzamiento" or "Precio de venta"),
		Ui.row({ box, rec, apply }, 8, { wrap = true }),
		Ui.grid({
			Ui.col({ Ui.text("Demanda prevista", { size = Ui.S.xs, color = T.mut }), demand }, 4),
			Ui.col({ Ui.text("Margen bruto estimado", { size = Ui.S.xs, color = T.mut }), margin }, 4),
		}, 2, nil, 10),
		msg,
		Ui.text("El precio es libre (por encima o por debajo del costo). Afecta las ventas futuras; lo ya vendido no cambia.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.3 }),
	}, 8, { Name = "EditorPrecio" })
end

function Screen.askClose(l: any)
	local avail = Rules.lotAvailable(l)
	local body = "Se dejan de vender las unidades de <b>" .. l.design.name .. "</b>. "
	if avail > 0 then
		body ..= "Quedan <b>" .. Util.num(avail) .. " unidades sin vender</b>: se descartan y se pierde su costo de fabricación (" .. Util.money(avail * l.unitCost) .. "), sin reintegro. "
	else
		body ..= "No quedan unidades sin vender. "
	end
	body ..= "El modelo queda como <b>Retirado</b> en el historial, con sus ventas y resultados. No se puede deshacer."
	App.openDialog("confirm", {
		title = "¿Cerrar la venta de " .. l.design.name .. "?",
		body = body,
		lines = {
			"Vendidas|" .. Util.num(l.sold),
			"Se descartan|" .. Util.num(avail),
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

-- Modelos comercializados (columna izquierda): por lanzar, en venta y en fabricación.
local ORDER: { [string]: number } = { ["por lanzar"] = 1, ["en venta"] = 2, produccion = 3 }
local function models(g: any): { any }
	local out = {}
	for _, l in g.lots do
		if ORDER[l.saleState] then
			table.insert(out, l)
		end
	end
	table.sort(out, function(a: any, b: any): boolean
		if ORDER[a.saleState] ~= ORDER[b.saleState] then
			return ORDER[a.saleState] < ORDER[b.saleState]
		end
		return a.id < b.id
	end)
	return out
end
Screen.models = models

local function selected(list: { any }): any
	for _, l in list do
		if l.id == App.ui.salesSel then
			return l
		end
	end
	return list[1]
end

local function modelRow(l: any, isSel: boolean): TextButton
	local st = Screen.SALE[l.saleState] or Screen.SALE["en venta"]
	local stock = Ui.inline("", { size = Ui.S.xs, color = T.mut, name = "StockFila" })
	local function refresh(x: any)
		stock.Text = l.saleState == "produccion" and (Util.round(Rules.lotProgress(x) * 100) .. " % fabricado") or (Util.num(x.sold) .. " vendidas · " .. Util.num(Rules.lotAvailable(x)) .. " en stock")
	end
	refresh(l)
	App.live(function(gg: any)
		local x = findLot(gg, l.id)
		if x then
			refresh(x)
		end
	end)
	local row = Ui.new("TextButton", {
		Name = "Fila_" .. l.id, Text = "", AutoButtonColor = false,
		BackgroundColor3 = isSel and STYLE.accent or STYLE.card, BackgroundTransparency = isSel and 0.82 or 0.15,
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Corner = 12, Stroke = isSel and { STYLE.accent, 2 } or { STYLE.line, 1 },
		Pad = { 8, 10 }, List = { dir = "H", gap = 10, v = "C" },
	}, {
		Ui.paintChip(l.design.spec, 34, 22),
		Ui.grow(Ui.col({
			Ui.text(l.design.name, { size = Ui.S.base, weight = W.bold }),
			Ui.row({ Ui.chip(st[1], st[2]), l.saleState ~= "produccion" and Ui.inline(Util.money(l.price), { size = Ui.S.xs, color = T.tx2 }) or nil }, 6, { wrap = true }),
			stock,
		}, 3)),
	})
	row.Activated:Connect(function()
		App.ui.salesSel = l.id
		App.forceRender()
	end)
	return row
end

local function kv(label: string, value: string, opts: { [string]: any }?): (Frame, TextLabel)
	local o: { [string]: any } = opts or {}
	local v = Ui.text(value, { size = o.size or 15, weight = W.bold, color = o.color, name = o.name })
	return Ui.col({ Ui.text(label, { size = Ui.S.xs, color = T.mut }), v }, 2), v
end

-- Detalle del modelo elegido (columna derecha).
local function detail(g: any, l: any): Frame
	local spec = l.design.spec
	local st = Screen.SALE[l.saleState] or Screen.SALE["en venta"]
	local phone = App.isPhone()
	local cPrice = kv("Precio actual", l.saleState == "por lanzar" and "sin precio todavía" or Util.money(l.price), { name = "PrecioModelo" })
	local cCost = kv("Costo de fabricación por unidad", Util.money(l.unitCost))
	local cRef = kv("Precio recomendado", Util.money(l.refPrice))
	local demandNode = Ui.col({ Ui.text("Demanda estimada", { size = Ui.S.xs, color = T.mut }), (Screen.demandBars(Rules.demandInfo(g, l))) }, 2)
	local cSold, vSold = kv("Unidades vendidas", Util.num(l.sold), { name = "Vendidas" })
	local cStock, vStock = kv("Stock restante", Util.num(Rules.lotAvailable(l)), { name = "Disponibles" })
	local cRev, vRev = kv("Ingresos acumulados", Util.money(l.revenue), { color = T.gr, name = "Ingresos" })
	local cCrit = kv("Calificación de los críticos", l.review and (Util.num(l.review.avg, 1) .. " / 10") or "llega al terminar la fabricación", { name = "NotaCriticos", color = l.review and (l.review.avg >= 7 and T.gr or (l.review.avg >= 5 and T.ye or T.re2)) or T.mut })
	App.live(function(gg: any)
		local x = findLot(gg, l.id)
		if x then
			vSold.Text = Util.num(x.sold)
			vStock.Text = Util.num(Rules.lotAvailable(x))
			vRev.Text = Util.money(x.revenue)
		end
	end)
	local items: { Instance? } = {
		Ui.row({
			Ui.grow(Ui.col({
				Ui.text(l.design.name, { size = 20, weight = W.bold, name = "NombreModelo" }),
				Ui.text((spec.generation or "") .. " · " .. (Catalog.TYPES[l.design.type] or l.design.type) .. (l.line and (" · línea " .. l.line) or ""), { size = Ui.S.xs, color = T.mut }),
			}, 3)),
			Ui.chip(st[1], st[2]),
		}, 10, { v = "T" }),
		Ui.row({
			Ui.carThumb(spec, phone and 150 or 280, phone and 90 or 160),
			Ui.grow(Ui.grid({ cPrice, cCost, cRef, demandNode }, 2, nil, 12)),
		}, 16, { v = "T", wrap = phone }),
		Ui.grid({ cSold, cStock, cRev, cCrit }, phone and 2 or 4, nil, 12),
	}
	if l.saleState == "produccion" then
		table.insert(items, Ui.note("b", "Se vende cuando termina de fabricarse (" .. Util.round(Rules.lotProgress(l) * 100) .. " %): llegan las reseñas y elegís el precio acá."))
	else
		if l.saleState == "en venta" and l.sold == 0 then
			-- Recién lanzado: las ventas corren con el tiempo del juego (con este menú abierto, la empresa está en pausa).
			table.insert(items, Ui.text("A la venta: los autos se venden solos con el paso del tiempo. Mientras este menú está abierto la empresa está en pausa; volvé al juego para que empiecen las ventas.", { size = Ui.S.xs, color = T.tx2, lineHeight = 1.3, name = "AvisoVentasArrancan" }))
		end
		table.insert(items, Screen.priceEditor(g, l, function()
			App.forceRender()
		end))
	end
	table.insert(items, Ui.row({
		l.review and Ui.button("Ver reseñas", "default", function()
			App.openDialog("reviews", { lotId = l.id })
		end, { small = true, name = "VerResenas" }) or nil,
		Ui.spacer(),
		(not Rules.lotProducing(l)) and Ui.button("Cerrar venta", "d", function()
			Screen.askClose(l)
		end, { small = true, icon = "x", iconSize = 14, name = "CerrarVenta" }) or nil,
	}, 8, { wrap = true }))
	return Factory.panel(items, { name = "Modelo_" .. l.id, gap = 14, pad = { 16, 18 } })
end

local function historyRow(l: any): Frame
	local st = Screen.SALE[l.saleState] or Screen.SALE.agotado
	local profit = l.revenue - l.costSpent
	return Ui.card({
		Ui.row({
			Ui.paintChip(l.design.spec, 30, 20),
			Ui.grow(Ui.col({
				Ui.text(l.design.name .. " <font color=\"#A3AAB8\" size=\"11\">" .. (l.design.spec.generation or "") .. "</font>", { size = Ui.S.sm, weight = W.bold }),
				Ui.text(Util.gameDate(l.createdDay) .. " → " .. Util.gameDate(l.endDay or l.createdDay) .. " · " .. Util.num(l.sold) .. " vendidas de " .. Util.num(l.produced) .. " fabricadas" .. ((l.discarded or 0) > 0 and (" · " .. Util.num(l.discarded) .. " descartadas") or "") .. " · a " .. Util.money(l.price) .. (l.review and (" · críticos " .. Util.num(l.review.avg, 1)) or ""), { size = Ui.S.xs, color = T.mut }),
			}, 1)),
			Ui.col({
				Ui.chip(st[1], st[2]),
				Ui.inline((profit >= 0 and "+" or "") .. Util.money(profit), { size = Ui.S.sm, weight = W.bold, color = profit >= 0 and T.gr or T.re2 }),
			}, 3, { Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY, h = "R" }),
		}, 10, { wrap = App.isPhone() }),
	}, { gap = 4, pad = { 10, 12 }, name = "Historial_" .. l.id, bg = STYLE.card, transparency = 0.15, stroke = STYLE.line })
end

local function marketingCard(g: any): Frame
	local camp = Rules.campaign(g)
	local mk: { Instance? } = { Ui.lbl("Marketing") }
	if camp then
		table.insert(mk, Ui.text(Catalog.MARKETING.kinds[camp.kind].name .. " · «" .. camp.name .. "»", { size = Ui.S.sm, weight = W.bold }))
		table.insert(mk, (Ui.bar(camp.progress / camp.days * 100, T.ye)))
		table.insert(mk, Ui.text("+" .. Util.round(Rules.campaignBoost(g) * 100) .. " % de demanda · " .. math.floor(camp.progress) .. "/" .. camp.days .. " días", { size = Ui.S.xs, color = T.mut }))
		table.insert(mk, Ui.button("Cancelar campaña", "q", function()
			App.openDialog("confirm", {
				title = "¿Cancelar la campaña?",
				body = "Termina enseguida y el dinero invertido (" .. Util.money(camp.cost) .. ") no se devuelve. Después podés empezar otra.",
				okLabel = "Cancelar campaña",
				cancel = "Seguir",
				danger = true,
				onOk = function()
					App.request("cancelCampaign", {})
				end,
			})
		end, { small = true, fill = true, name = "CancelarCampana" }))
	else
		table.insert(mk, Ui.text("Sin campaña activa. Una campaña de modelo promociona un auto; la corporativa, toda la marca.", { size = Ui.S.xs, color = T.mut }))
		table.insert(mk, Ui.button("Nueva campaña", "p", function()
			App.openDialog("campaign", {})
		end, { small = true, fill = true, name = "NuevaCampana" }))
	end
	return Factory.panel(mk, { name = "Campana", gap = 8, pad = { 12, 12 } })
end

function Screen.build(main: Frame, _side: Frame)
	local g = App.g
	local phone = App.isPhone()
	Sheet.salesNav("ventas").Parent = main
	local list = models(g)
	local tabs, tab = Sheet.tabs("ventas", { { "venta", "Modelos", #list }, { "historial", "Agotados y retirados", #g.lotHistory } }, "venta")
	tabs.Parent = main
	if tab == "historial" then
		if #g.lotHistory == 0 then
			Ui.empty("box", "Todavía no hay lotes terminados. Un lote queda «Agotado» al venderse todo, o «Retirado» si cerrás su venta.").Parent = main
		end
		for _, l in g.lotHistory do
			historyRow(l).Parent = main
		end
		if #g.lotHistory > 0 then
			Ui.text("Se conservan los últimos " .. Catalog.RULES.maxLotHistory .. " lotes. Los totales de la empresa (Estadísticas) incluyen todos.", { size = Ui.S.xs, color = T.mut }).Parent = main
		end
		return
	end
	local sel = selected(list)
	local rows: { Instance? } = { Ui.lbl("Modelos comercializados") }
	for _, l in list do
		table.insert(rows, modelRow(l, sel ~= nil and l.id == sel.id))
	end
	if #list == 0 then
		table.insert(rows, Ui.text("Todavía no hay modelos. Iniciá un lote en Producción: al terminar llegan las reseñas y elegís el precio acá.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.3 }))
		table.insert(rows, Ui.button("Ir a Producción", "p", function()
			App.go("fabrica")
		end, { small = true, name = "IrProduccion" }))
	end
	local rate = Ui.inline(Util.num(Screen.totalRate(g), 1) .. " autos/min", { size = Ui.S.sm, weight = W.bold, color = T.gr, name = "RitmoTotal" })
	App.live(function(gg: any)
		rate.Text = Util.num(Screen.totalRate(gg), 1) .. " autos/min"
	end)
	table.insert(rows, Ui.row({ Ui.grow(Ui.text("Ritmo total de ventas", { size = Ui.S.xs, color = T.mut })), rate }, 8))
	local left = Ui.col({ Factory.panel(rows, { name = "ListaModelos", gap = 8, pad = { 12, 12 } }), marketingCard(g) }, 12, { Name = "ColModelos" })
	local right = sel and detail(g, sel) or Factory.panel({
		Ui.text("Elegí un modelo de la lista", { size = 18, weight = W.bold }),
		Ui.text("Acá vas a ver su precio, costo, demanda, ventas y reseñas, y vas a poder cambiar el precio.", { size = Ui.S.sm, color = T.mut }),
	}, { name = "SinModelo" })
	if phone then
		left.Parent = main
		right.Parent = main
	else
		left.Size = UDim2.new(0.28, -7, 0, 0)
		right.Size = UDim2.new(0.72, -7, 0, 0)
		Ui.row({ left, right }, 14, { Name = "Ventas", v = "T" }).Parent = main
	end
	if not Ui.reduceMotion then
		Ui.fadeIn(right)
	end
end

return Screen
