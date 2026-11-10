--!strict
--[[
	Ventas › Producción. A la izquierda (≈ 28 %), las líneas de producción; a la derecha, el detalle de la
	elegida:
	- bloqueada: cómo se desbloquea (línea 2 con dinero del juego, línea 3 con Robux para toda la cuenta);
	- libre: «Iniciar producción» abre el catálogo de modelos finalizados (Dialogs.lot);
	- ocupada: el lote que fabrica, con vista 3D, avance, días restantes, costo pagado y bonificaciones.
	La fabricación no se pausa ni se cancela: la línea completa el lote (todo lo valida el servidor). Abajo, las
	estaciones (mejoras de velocidad) como antes.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local Rules = require(Shared.Rules)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local Sheet = require(script.Parent.ScreenSheet)
local T = Ui.T
local W = Ui.W

local Screen = {
	title = "Producción",
	icon = "factory",
	noSide = true, -- dos columnas propias (líneas y detalle) en lugar de la columna lateral
}

-- Estilo común de Producción y Ventas (azul oscuro, paneles semitransparentes, acentos azules).
local STYLE = {
	panel = Ui.hex("#0B1220"),
	card = Ui.hex("#111A2B"),
	line = Ui.hex("#22304A"),
	accent = Ui.hex("#3B8BFF"),
	accent2 = Ui.hex("#8DB8FF"),
}
Screen.STYLE = STYLE

-- Estados de producción de un lote: { texto, chip }
Screen.PROD = {
	produciendo = { "Fabricando", "cg" },
	cola = { "Esperando una línea", "cn" },
	pausado = { "Esperando una línea", "cn" },
	["sin fondos"] = { "Sin fondos", "cr" },
	completado = { "Lote completo", "cb" },
	cancelado = { "Cancelado", "cn" },
}

function Screen.head(g: any): { Instance }
	local caps = g.derived.caps
	return {
		Ui.chip(caps.lines .. (caps.lines == 1 and " línea" or " líneas"), "cn"),
		Ui.chip(Util.num(caps.perLine, 1) .. " autos/min por línea", "cb"),
	}
end

local function findLot(g: any, id: string): any
	for _, l in g.lots do
		if l.id == id then
			return l
		end
	end
	return nil
end

-- Panel con el estilo de Producción / Ventas.
function Screen.panel(children: { Instance? }, props: { [string]: any }?): Frame
	local p: { [string]: any } = props or {}
	return Ui.card(children, {
		bg = STYLE.panel, transparency = 0.1, stroke = { STYLE.line, 1, 0 }, radius = 14, pad = p.pad or { 14, 16 }, gap = p.gap or 10, name = p.name,
	})
end

-- Días de juego → texto («≈ 12 días»). El tiempo real depende de la velocidad elegida (1×, 2×, 3×).
function Screen.daysText(days: number): string
	if days == math.huge then
		return "—"
	end
	if days < 1 then
		return "menos de un día"
	end
	local d = math.ceil(days)
	return "≈ " .. Util.num(d) .. (d == 1 and " día" or " días")
end

-- Tiempo real equivalente a `days` días de juego a la velocidad actual (en pausa: «en pausa»).
function Screen.realText(g: any, days: number): string
	local speed = g.time.speed
	if days == math.huge then
		return "—"
	end
	if speed <= 0 then
		return "en pausa"
	end
	return "≈ " .. Util.realTime(days * Catalog.CALENDAR.realSecondsPerDay / speed) .. " reales a " .. speed .. "×"
end

-- Estado de una línea: "bloqueada", "obra", "libre" u "ocupada" (y su lote).
function Screen.lineState(g: any, n: number): (string, any)
	if not Rules.ownsLine(g, n) then
		if n == 2 and Rules.build(g, "line2") then
			return "obra", nil
		end
		return "bloqueada", nil
	end
	local lot = Rules.lineLot(g, n)
	if lot then
		return "ocupada", lot
	end
	return "libre", nil
end

local function selectedLine(g: any): number
	local sel = tonumber(App.ui.lineSel)
	if sel and sel >= 1 and sel <= Catalog.FACILITIES.maxLines then
		return sel
	end
	for n = 1, Catalog.FACILITIES.maxLines do
		if Rules.lineLot(g, n) then
			return n
		end
	end
	return 1
end
Screen.selectedLine = selectedLine

-- Tarjeta compacta de una línea (columna izquierda).
local function lineCard(g: any, n: number, selected: boolean): TextButton
	local state, lot = Screen.lineState(g, n)
	local sub, color = "", T.mut
	if state == "bloqueada" then
		sub = n == 3 and "Bloqueada · Robux (toda la cuenta)" or "Bloqueada · dinero del juego"
		color = T.ye
	elseif state == "obra" then
		sub = "Obra en curso"
		color = T.ye
	elseif state == "libre" then
		sub = "Libre · lista para fabricar"
		color = T.gr
	else
		sub = "Fabricando «" .. lot.design.name .. "»"
		color = STYLE.accent2
	end
	local items: { Instance? } = {
		Ui.row({
			Ui.ico(state == "bloqueada" and "lock" or "factory", state == "bloqueada" and T.ye or (state == "ocupada" and STYLE.accent2 or T.tx), state == "ocupada" and STYLE.accent or Ui.hex("#16223A"), 32, { alpha = state == "ocupada" and 0.5 or 1, radius = 8, iconSize = 16 }),
			Ui.grow(Ui.col({
				Ui.text("Línea " .. n, { size = 15, weight = W.bold }),
				Ui.text(sub, { size = Ui.S.xs, color = color, name = "EstadoLinea" }),
			}, 1)),
		}, 10),
	}
	if lot then
		local bar, fill = Ui.bar(Rules.lotProgress(lot) * 100, STYLE.accent, 4)
		local pct = Ui.inline(Util.round(Rules.lotProgress(lot) * 100) .. " %", { size = Ui.S.xs, color = T.mut, name = "AvanceLinea" })
		App.live(function(gg: any)
			local x = findLot(gg, lot.id)
			if x then
				Ui.setBar(fill, Rules.lotProgress(x) * 100)
				pct.Text = Util.round(Rules.lotProgress(x) * 100) .. " %"
			end
		end)
		table.insert(items, Ui.row({ Ui.grow(bar), pct }, 8))
	end
	local card = Ui.new("TextButton", {
		Name = "Linea_" .. n, Text = "", AutoButtonColor = false,
		BackgroundColor3 = selected and STYLE.accent or STYLE.card, BackgroundTransparency = selected and 0.82 or 0.15,
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Corner = 12,
		Stroke = selected and { STYLE.accent, 2 } or { STYLE.line, 1 }, Pad = { 10, 12 }, List = { dir = "V", gap = 8 },
	}, items)
	card:SetAttribute("estado", state)
	card.Activated:Connect(function()
		App.ui.lineSel = n
		App.forceRender()
	end)
	return card
end

local function kv(label: string, value: string, opts: { [string]: any }?): Frame
	local o: { [string]: any } = opts or {}
	return Ui.col({
		Ui.text(label, { size = Ui.S.xs, color = T.mut }),
		Ui.text(value, { size = o.size or 15, weight = W.bold, color = o.color, name = o.name }),
	}, 2)
end

local function bonusList(g: any): Frame
	local rows: { Instance? } = {}
	for _, b in Rules.productionBonuses(g) do
		table.insert(rows, Ui.between(b[1], b[2], { color = T.gr }))
	end
	if #rows == 0 then
		table.insert(rows, Ui.text("Sin bonificaciones por ahora: mejoran con las estaciones, la fábrica, la tecnología y el personal de Producción.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.3 }))
	end
	return Ui.col(rows, 4, { Name = "Bonificaciones" })
end
Screen.bonusList = bonusList

-- Detalle de la línea elegida (columna derecha).
local function lineDetail(g: any, n: number): Frame
	local state, lot = Screen.lineState(g, n)
	local items: { Instance? } = {}
	if state == "ocupada" then
		local spec = lot.design.spec
		local phone = App.isPhone()
		local pctLabel = Ui.inline(Util.round(Rules.lotProgress(lot) * 100) .. " %", { size = 26, weight = W.heavy, name = "Porcentaje" })
		local bar, fill = Ui.bar(Rules.lotProgress(lot) * 100, STYLE.accent, 8)
		local made = Ui.text(Util.num(lot.produced) .. " de " .. Util.num(lot.qty) .. " unidades", { size = Ui.S.sm, color = T.tx2, name = "Fabricadas" })
		local daysLabel = Ui.text(Screen.daysText(Rules.lotDaysLeft(g, lot)), { size = 15, weight = W.bold, name = "DiasRestantes" })
		local realLabel = Ui.text(Screen.realText(g, Rules.lotDaysLeft(g, lot)), { size = Ui.S.xs, color = T.mut, name = "TiempoReal" })
		local st = Screen.PROD[lot.prodState] or Screen.PROD.produciendo
		local chip = Ui.chip(st[1], st[2])
		App.live(function(gg: any)
			local x = findLot(gg, lot.id)
			if x then
				Ui.setBar(fill, Rules.lotProgress(x) * 100)
				pctLabel.Text = Util.round(Rules.lotProgress(x) * 100) .. " %"
				made.Text = Util.num(x.produced) .. " de " .. Util.num(x.qty) .. " unidades"
				daysLabel.Text = Screen.daysText(Rules.lotDaysLeft(gg, x))
				realLabel.Text = Screen.realText(gg, Rules.lotDaysLeft(gg, x))
			end
		end)
		local base = Catalog.base(spec.baseId)
		local motor = Catalog.part("motor", spec.parts and spec.parts.motor)
		items = {
			Ui.row({
				Ui.grow(Ui.col({
					Ui.inline("LÍNEA " .. n .. " · EN FABRICACIÓN", { size = Ui.S.xs, weight = W.bold, color = STYLE.accent2 }),
					Ui.text(lot.design.name, { size = 20, weight = W.bold, name = "ModeloLinea" }),
					Ui.text((spec.generation or "") .. " · " .. (base and base.name or "") .. (motor and (" · " .. (string.gsub(motor.name, " · nivel %d+$", "")) .. " nivel " .. tostring(spec.motorLevel or 1)) or ""), { size = Ui.S.xs, color = T.mut }),
				}, 3)),
				chip,
			}, 10, { v = "T" }),
			Ui.row({
				Ui.carThumb(spec, phone and 150 or 300, phone and 90 or 170),
				Ui.grow(Ui.col({
					Ui.row({ pctLabel, Ui.inline("completado", { size = Ui.S.sm, color = T.mut }) }, 8, { v = "B" }),
					bar,
					made,
					Ui.grid({
						Ui.col({ Ui.text("Días restantes (estimado)", { size = Ui.S.xs, color = T.mut }), daysLabel, realLabel }, 2),
						kv("Costo total pagado", Util.money(lot.costSpent), { name = "CostoPagado" }),
					}, 2, nil, 10),
				}, 8)),
			}, 16, { v = "T", wrap = phone }),
		}
		table.insert(items, Ui.grid({
			kv("Cantidad del lote", Util.num(lot.qty) .. " unidades"),
			kv("Costo por unidad", Util.money(lot.unitCost)),
			kv("Velocidad de la línea", Util.num(g.derived.lineRate, 1) .. " autos/min real a 1×"),
		}, phone and 1 or 3, nil, 10))
		table.insert(items, Ui.col({ Ui.lbl("Bonificaciones activas"), bonusList(g) }, 6))
		table.insert(items, Ui.note("b", "La fabricación no se puede cancelar ni pausar: la línea completa el lote. Avanza con el calendario de la empresa (1×, 2× o 3×) y se detiene en pausa o sin conexión. Al terminar llegan las reseñas y elegís el precio en Ventas."))
	elseif state == "libre" then
		local available = 0
		for _, d in g.designs do
			if not d.template and not d.lotLaunched then
				available += 1
			end
		end
		items = {
			Ui.inline("LÍNEA " .. n, { size = Ui.S.xs, weight = W.bold, color = STYLE.accent2 }),
			Ui.text("Libre", { size = 20, weight = W.bold }),
			Ui.text("Elegí un modelo finalizado y la cantidad. El lote se paga completo al confirmarlo y la línea lo fabrica hasta terminarlo.", { size = Ui.S.sm, color = T.mut, lineHeight = 1.35 }),
			Ui.grid({
				kv("Velocidad por línea", Util.num(g.derived.lineRate, 1) .. " autos/min real a 1×"),
				kv("Modelos disponibles", tostring(available)),
			}, 2, nil, 10),
			Ui.col({ Ui.lbl("Bonificaciones de fabricación"), bonusList(g) }, 6),
			Ui.button("Iniciar producción", "p", function()
				App.ui.lotDraft = nil
				App.openDialog("lot", { line = n, wide = true })
			end, { icon = "factory", name = "IniciarProduccion" }),
			available == 0 and Ui.note("b", "No tenés modelos para fabricar: los borradores no se fabrican y cada modelo produce un solo lote. Finalizá un diseño nuevo o una nueva generación en el editor.", Ui.button("Abrir el editor", "default", function()
				App.go("editor")
			end, { small = true })) or nil,
		}
	elseif state == "obra" then
		local b = Rules.build(g, "line2")
		items = {
			Ui.inline("LÍNEA 2", { size = Ui.S.xs, weight = W.bold, color = STYLE.accent2 }),
			Ui.text("En construcción", { size = 20, weight = W.bold }),
			(Ui.bar(b.progress / math.max(1, b.days) * 100, T.ye)),
			Ui.text(math.floor(b.progress) .. " de " .. b.days .. " días de obra. Al terminar, la línea queda disponible para siempre en esta empresa.", { size = Ui.S.sm, color = T.mut }),
		}
	elseif n == 3 then
		local product = Catalog.PRODUCTS.line3
		local ready = product.id ~= 0
		items = {
			Ui.inline("LÍNEA 3", { size = Ui.S.xs, weight = W.bold, color = STYLE.accent2 }),
			Ui.text("Bloqueada", { size = 20, weight = W.bold }),
			Ui.text("Compra permanente con Robux para tu cuenta: vale en todas tus empresas, también en las que crees después. No hace falta tener la línea 2.", { size = Ui.S.sm, color = T.mut, lineHeight = 1.35 }),
			Ui.button("Desbloquear con Robux", "p", function()
				App.request("buyProduct", { product = "line3" })
			end, { icon = "lock", name = "DesbloquearLinea_3", disabled = not ready or g.demo ~= nil, why = (not ready) and "Compra no configurada todavía" or "No disponible en demostraciones" }),
			(not ready) and Ui.text("La compra todavía no está configurada en este juego.", { size = Ui.S.xs, color = T.mut }) or nil,
		}
	else
		local nx = Rules.nextFacility(g, "line2")
		local checks: { Instance? } = {}
		local ok = nx ~= nil
		for _, c in Rules.facilityChecks(g, "line2") do
			ok = ok and c[1]
			table.insert(checks, Ui.text((c[1] and "✓ " or "✕ ") .. c[2], { size = Ui.S.xs, color = c[1] and T.gr or T.re2 }))
		end
		items = {
			Ui.inline("LÍNEA 2", { size = Ui.S.xs, weight = W.bold, color = STYLE.accent2 }),
			Ui.text("Bloqueada", { size = 20, weight = W.bold }),
			Ui.text("Se desbloquea para siempre en esta empresa con dinero del juego: es una obra que se paga al empezar y tarda unos días.", { size = Ui.S.sm, color = T.mut, lineHeight = 1.35 }),
			nx and Ui.grid({ kv("Costo", Util.money(nx.cost)), kv("Duración de la obra", nx.days .. " días") }, 2, nil, 10) or nil,
			#checks > 0 and Ui.col(checks, 3) or nil,
			nx and Ui.button("Desbloquear línea 2 · " .. Util.money(nx.cost), "p", function()
				App.openDialog("confirm", {
					title = "¿Construir la línea 2?",
					body = "Se paga " .. Util.money(nx.cost) .. " al empezar y la obra dura " .. nx.days .. " días de juego. La línea queda disponible para siempre en esta empresa.",
					okLabel = "Empezar la obra",
					onOk = function()
						App.request("upgradeFacility", { kind = "line2" })
					end,
				})
			end, { icon = "lock", name = "DesbloquearLinea_2", disabled = not ok, why = "Faltan requisitos" }) or nil,
		}
	end
	return Screen.panel(items, { name = "DetalleLinea", gap = 12, pad = { 16, 18 } })
end

function Screen.build(main: Frame, _side: Frame)
	local g = App.g
	local phone = App.isPhone()
	Sheet.salesNav("fabrica").Parent = main
	-- Recién finalizado en el editor: acceso directo a su lote (la cantidad se elige acá, no en el editor).
	for _, d in g.designs do
		if d.id == App.ui.lastFinalized and not d.lotLaunched then
			local free = Rules.freeLine(g)
			Ui.note("g", "«" .. d.name .. "» está finalizado y listo para fabricar. Cada modelo tiene un solo lote: elegí cuántas unidades." .. (free and "" or " Todas las líneas están ocupadas: esperá a que una termine."), free and Ui.button("Fabricar «" .. d.name .. "»", "p", function()
				App.ui.lotDraft = nil
				App.openDialog("lot", { line = free, designId = d.id, wide = true })
			end, { small = true, name = "LoteRecienFinalizado" }) or nil).Parent = main
		end
	end
	local sel = selectedLine(g)
	local lines: { Instance? } = { Ui.lbl("Líneas de producción") }
	for n = 1, Catalog.FACILITIES.maxLines do
		table.insert(lines, lineCard(g, n, n == sel))
	end
	-- Lotes de partidas anteriores que esperan una línea (antes había una cola).
	local waiting = 0
	for _, l in g.lots do
		if Rules.lotProducing(l) and l.line == nil then
			waiting += 1
		end
	end
	if waiting > 0 then
		table.insert(lines, Ui.text(waiting .. (waiting == 1 and " lote espera" or " lotes esperan") .. " una línea libre (de una versión anterior): toman la próxima que se libere.", { size = Ui.S.xs, color = T.ye, lineHeight = 1.3, name = "LotesEnEspera" }))
	end
	local caps = g.derived.caps
	table.insert(lines, Ui.text(caps.lines .. (caps.lines == 1 and " línea propia" or " líneas propias") .. " · " .. Util.num(caps.capacity, 1) .. " autos/min en total", { size = Ui.S.xs, color = T.mut }))
	local left = Screen.panel(lines, { name = "ListaLineas", gap = 8, pad = { 12, 12 } })
	local right = lineDetail(g, sel)
	if phone then
		left.Parent = main
		right.Parent = main
	else
		left.Size = UDim2.new(0.28, -7, 0, 0)
		right.Size = UDim2.new(0.72, -7, 0, 0)
		Ui.row({ left, right }, 14, { Name = "Produccion", v = "T" }).Parent = main
	end
	if not Ui.reduceMotion then
		Ui.fadeIn(right)
	end

	-- Estaciones (mejoras de velocidad para todas las líneas).
	local stations = {}
	local maxL = Rules.maxStationLevel(g)
	for _, st in Catalog.STATIONS do
		local id = st[1]
		local s = g.stations[id]
		local up = Rules.upgradeCost(s)
		table.insert(stations, Ui.card({
			Ui.row({ Ui.grow(Ui.inline(st[2], { size = 15, weight = W.bold })), Ui.chip("Nv. " .. s.level, "cn") }, 6),
			Ui.text("+" .. Util.round(Catalog.STATION_SPEED * 100) .. " % de velocidad por nivel", { size = Ui.S.xs, color = T.mut }),
			Ui.button("Mejorar · " .. Util.money(up), "default", function()
				App.request("upgradeStation", { station = id })
			end, { small = true, fill = true, disabled = s.level >= maxL or g.money < up, why = s.level >= maxL and "Nivel máximo para esta sede" or "Fondos insuficientes", name = "Mejorar_" .. id }),
		}, { gap = 6, name = "Estacion_" .. id, bg = STYLE.card, transparency = 0.15, stroke = STYLE.line }))
	end
	Screen.panel({
		Ui.lbl("Estaciones"),
		Ui.grid(stations, phone and 2 or 4, nil, 10),
		Ui.text("Cada nivel por encima del primero suma un " .. Util.round(Catalog.STATION_SPEED * 100) .. " % de velocidad a todas las líneas (también al lote que se está fabricando: su tiempo restante se recalcula). Nivel máximo con esta sede: " .. maxL .. ".", { size = Ui.S.xs, color = T.mut, lineHeight = 1.35 }),
	}, { name = "Estaciones" }).Parent = main
end

return Screen
