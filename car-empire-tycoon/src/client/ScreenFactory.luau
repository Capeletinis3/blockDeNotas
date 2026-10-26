--!strict
--[[
	Producción por lotes: el jugador elige un diseño y cuántas unidades fabricar; la fábrica produce
	exactamente esa cantidad y se detiene. Cada línea de la sede fabrica un lote a la vez; los demás
	esperan en cola (se pueden reordenar o pausar). Las unidades se pagan a medida que se terminan y
	se venden solas (Centro de ventas). Al costado: capacidad, estaciones (mejoras) y cómo funciona.
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

local Screen = {
	title = "Producción",
	icon = "factory",
}

-- Estados de producción de un lote: { texto, chip }
Screen.PROD = {
	produciendo = { "Fabricando", "cg" },
	cola = { "En cola", "cn" },
	pausado = { "En pausa", "cy" },
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

-- Tiempo real restante del lote a la velocidad actual de su línea.
function Screen.etaText(g: any, l: any): string
	local pending = l.qty - l.produced
	if pending <= 0 then
		return "terminado"
	end
	local rate = g.derived.lineRate * math.max(0, g.time.speed)
	if rate <= 0 then
		return "en pausa"
	end
	return "≈ " .. Util.realTime(pending / rate * 60) .. " para terminar"
end

local function liveText(g: any, l: any): string
	local base = Util.num(l.produced) .. " de " .. Util.num(l.qty) .. " fabricadas"
	if l.prodState == "produciendo" then
		return base .. " · " .. Util.num(g.derived.lineRate, 1) .. "/min · " .. Screen.etaText(g, l)
	elseif l.prodState == "sin fondos" then
		return base .. " · espera " .. Util.money(l.unitCost) .. " para la próxima unidad"
	elseif l.prodState == "pausado" then
		return base .. " · en pausa"
	end
	return base .. " · espera una línea libre"
end

local function lotRow(g: any, l: any, i: number, total: number): Frame
	local st = Screen.PROD[l.prodState] or Screen.PROD.cola
	local bar, fill = Ui.bar(l.produced / math.max(1, l.qty) * 100, l.prodState == "sin fondos" and T.re or nil)
	local live = Ui.inline(liveText(g, l), { size = Ui.S.xs, name = "EnVivo" })
	local chip = Ui.chip(st[1], st[2])
	App.live(function(gg: any)
		local x = findLot(gg, l.id)
		if x then
			Ui.setBar(fill, x.produced / math.max(1, x.qty) * 100)
			live.Text = liveText(gg, x)
		end
	end)
	local spec = l.design.spec
	return Ui.card({
		Ui.row({
			Ui.paintChip(spec, 34, 22),
			Ui.grow(Ui.col({
				Ui.text(l.design.name .. " <font color=\"#A3AAB8\" size=\"12\">" .. (spec.generation or "") .. "</font>", { size = 15, weight = W.bold }),
				Ui.text("Lote de " .. Util.num(l.qty) .. " · " .. Util.money(l.unitCost) .. " por unidad · se vende a " .. Util.money(l.price), { size = Ui.S.xs, color = T.mut }),
			}, 2)),
			chip,
		}, 10, { wrap = true }),
		Ui.row({ Ui.grow(bar), live }, 10, { wrap = App.isPhone() }),
		l.prodState == "sin fondos" and Ui.note("r", "No alcanza el dinero para terminar la próxima unidad. La producción sigue sola cuando entren ventas; nunca se genera deuda.") or nil,
		Ui.row({
			Ui.button("", "default", function()
				App.request("moveLot", { lotId = l.id, delta = -1 })
			end, { small = true, icon = "up", iconSize = 14, disabled = i == 1, why = "Ya es el primero", name = "Subir" }),
			Ui.button("", "default", function()
				App.request("moveLot", { lotId = l.id, delta = 1 })
			end, { small = true, icon = "down", iconSize = 14, disabled = i == total, why = "Ya es el último", name = "Bajar" }),
			Ui.button(l.prodState == "pausado" and "Reanudar" or "Pausar", "default", function()
				App.request("toggleLotPause", { lotId = l.id })
			end, { small = true, icon = l.prodState == "pausado" and "play" or "pause", iconSize = 14, name = "Pausa" }),
			Ui.spacer(),
			Ui.button("Ver en ventas", "default", function()
				App.go("ventas")
			end, { small = true, name = "VerVentas" }),
		}, 6, { wrap = true }),
	}, { gap = 8, pad = { 10, 12 }, name = "Lote_" .. l.id })
end

function Screen.build(main: Frame, side: Frame)
	local g = App.g
	local caps = g.derived.caps
	local canLot = false
	for _, d in g.designs do
		if not d.template then
			canLot = true
		end
	end
	Ui.row({
		Ui.button("Lanzar lote", "p", function()
			App.openDialog("lot", { wide = true })
		end, { icon = "plus", disabled = not canLot, why = "Primero guardá un diseño en el editor", name = "LanzarLote" }),
		Ui.inline("Capacidad: " .. Util.num(caps.capacity, 1) .. " autos/min en " .. caps.lines .. (caps.lines == 1 and " línea" or " líneas"), { size = Ui.S.sm, color = T.mut }),
	}, 10, { wrap = true }).Parent = main
	if not canLot then
		Ui.note("b", "Para fabricar necesitás un diseño guardado.", Ui.button("Abrir el editor", "default", function()
			App.go("editor")
		end, { small = true })).Parent = main
	end

	-- Lotes con producción pendiente (en línea, en cola o en pausa)
	local pending = {}
	for _, l in g.lots do
		if Rules.lotProducing(l) then
			table.insert(pending, l)
		end
	end
	local onLine = {}
	for _, l in Rules.producingLots(g) do
		onLine[l.id] = true
	end
	local section = Ui.card({
		Ui.row({
			Ui.grow(Ui.inline("Lotes en producción", { size = 15, weight = W.bold })),
			Ui.inline(#pending > 0 and (#pending .. " lote" .. (#pending > 1 and "s" or "") .. " · las líneas toman los primeros de la lista") or "Fábrica libre", { size = Ui.S.xs, color = T.mut }),
		}, 10, { wrap = true }),
	}, { gap = 8, name = "Produccion" })
	if #pending == 0 then
		Ui.empty("factory", "No hay lotes en producción. Lanzá un lote: la fábrica produce exactamente esa cantidad y se detiene.", nil, { pad = 14 }).Parent = section
	end
	for i, l in pending do
		local row = lotRow(g, l, i, #pending)
		if onLine[l.id] then
			row:SetAttribute("linea", true)
		end
		row.Parent = section
	end
	section.Parent = main

	-- Lotes ya fabricados que siguen a la venta
	local done = {}
	for _, l in g.lots do
		if not Rules.lotProducing(l) then
			table.insert(done, l)
		end
	end
	if #done > 0 then
		local items: { Instance? } = { Ui.lbl("Fabricados · vendiéndose") }
		for _, l in done do
			table.insert(items, Ui.card({
				Ui.paintChip(l.design.spec, 26, 18),
				Ui.grow(Ui.text(l.design.name .. " × " .. Util.num(l.qty) .. " <font color=\"#A3AAB8\" size=\"11\">· " .. Util.num(Rules.lotAvailable(l)) .. " sin vender</font>", { size = Ui.S.sm, weight = W.bold })),
				Ui.chip("Producción detenida", "cn"),
			}, { dir = "H", v = "C", gap = 10, wrap = true }))
		end
		table.insert(items, Ui.text("Un lote terminado no se repite solo. Para fabricar más, lanzá un lote nuevo.", { size = Ui.S.xs, color = T.mut }))
		Ui.col(items, 8).Parent = main
	end

	-- Estaciones (mejoras de velocidad)
	local stations = {}
	local maxL = Rules.maxStationLevel(g)
	for _, st in Catalog.STATIONS do
		local id = st[1]
		local s = g.stations[id]
		local staff = {}
		for _, e in g.employees do
			if e.assign == id then
				table.insert(staff, e.name)
			end
		end
		local up = Rules.upgradeCost(s)
		table.insert(stations, Ui.card({
			Ui.row({ Ui.grow(Ui.inline(st[2], { size = 15, weight = W.bold })), Ui.chip("Nv. " .. s.level, "cn") }, 6),
			Ui.text((#staff > 0 and table.concat(staff, ", ") or "Sin personal") .. " · ideal: " .. string.lower(st[3]), { size = Ui.S.xs, color = T.mut }),
			Ui.button("Mejorar · " .. Util.money(up), "default", function()
				App.request("upgradeStation", { station = id })
			end, { small = true, fill = true, disabled = s.level >= maxL or g.money < up, why = s.level >= maxL and "Nivel máximo para esta sede" or "Fondos insuficientes", name = "Mejorar_" .. id }),
		}, { gap = 6, name = "Estacion_" .. id }))
	end
	Ui.col({
		Ui.lbl("Estaciones"),
		Ui.grid(stations, App.isPhone() and 2 or 3, nil, 10),
		Ui.text("Cada nivel por encima del primero suma un " .. Util.round(Catalog.STATION_SPEED * 100) .. " % de velocidad a todas las líneas. El nivel máximo depende de la sede (ahora " .. maxL .. ").", { size = Ui.S.xs, color = T.mut }),
	}, 8).Parent = main

	-- Columna lateral
	local nx = Rules.nextSede(g)
	Ui.card({
		Ui.lbl("Capacidad"),
		Ui.between("Líneas", tostring(caps.lines)),
		Ui.between("Por línea", Util.num(caps.perLine, 1) .. " autos/min"),
		Ui.between("Total", Util.num(caps.capacity, 1) .. " autos/min", { color = T.gr }),
		nx and Ui.text("Con «" .. nx.name .. "»: " .. nx.lines .. " líneas de " .. nx.perLine .. " autos/min de base.", { size = Ui.S.xs, color = T.mut }) or nil,
	}, { gap = 6, name = "Capacidad" }).Parent = side
	Ui.card({
		Ui.lbl("Cómo funciona"),
		Ui.text("1. Lanzá un lote: elegís el diseño, la cantidad y el precio.\n2. Cada línea fabrica un lote; cada unidad se paga al terminarla (" .. "no hay pago por adelantado).\n3. Lo terminado se vende solo según la demanda.\n4. Al completar la cantidad la producción se detiene.\n5. Si falta dinero, la línea espera sin generar deuda.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.45 }),
	}, { gap = 4, name = "ComoFunciona" }).Parent = side
	Ui.card({
		Ui.lbl("Tiempo"),
		Ui.text("A 1×, un año de juego dura " .. Util.round(Catalog.CALENDAR.realSecondsPerYear / 60) .. " minutos reales. Los ritmos se muestran en autos por minuto real; a 2× y 4× todo va más rápido. En pausa no se fabrica ni se vende.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.4 }),
	}, { gap = 4 }).Parent = side
end

return Screen
