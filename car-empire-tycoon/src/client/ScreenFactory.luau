--!strict
--[[
	Fábrica (SCREENS.fabrica de la V3): nueva orden, líneas 1–4 con su cola (arrastre o flechas,
	pausa, prioridad, línea, costo fijado, cancelar), órdenes terminadas para repetir, estaciones de
	montaje y, al costado, capacidad, controles (automática y acelerar), materiales y tiempo.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local Rules = require(Shared.Rules)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local T = Ui.T
local W = Ui.W

local Screen = {
	title = "Fábrica",
	icon = "factory",
}

-- Texto único de capacidad del almacén (misma regla que valida el servidor).
function Screen.warehouseText(g: any): string
	local d = g.derived
	return d.warehouseUsed .. "/" .. d.caps.warehouse
end

function Screen.matsText(g: any): string
	local d = g.derived
	return d.matsUsed .. "/" .. d.caps.mats
end

function Screen.head(g: any): { Instance }
	local caps = g.derived.caps
	local full = g.derived.warehouseUsed >= caps.warehouse
	local out = {
		Ui.chip(caps.lines .. (caps.lines == 1 and " línea" or " líneas"), "cn"),
		Ui.chip("Almacén " .. g.derived.warehouseUsed .. "/" .. caps.warehouse, full and "cr" or "cb"),
	}
	if g.production.boost then
		table.insert(out, Ui.chip("Acelerada ×2", "cy"))
	end
	return out
end

local STATUS = { ["en producción"] = { "En producción", "cg" }, detenida = { "Detenida", "cr" }, pausada = { "En pausa", "cy" }, ["en cola"] = { "En cola", "cn" } }
local PRIOS = { { "alta", "Alta" }, { "media", "Media" }, { "baja", "Baja" } }

local function findOrder(g: any, id: string): any
	for _, o in g.production.orders do
		if o.id == id then
			return o
		end
	end
	return nil
end

-- Texto en vivo de la orden (LIVE.order de la V3).
local function liveText(g: any, o: any): string
	local base = o.done .. "/" .. o.qty .. " · "
	if o.status == "en producción" and o.unitStarted then
		local left = math.max(0, (o.unitTotal or 0) - (o.progress or 0)) / math.max(0.01, g.derived.lineSpeed)
		return base .. "unidad lista en " .. Util.gameDuration(left) .. " de juego (" .. Util.realDur(left, g.time.speed) .. ")"
	end
	if o.status == "detenida" then
		return base .. "Detenida"
	end
	return base .. (o.paused and "En pausa" or "En cola")
end

-- Arrastre vertical de la manija (equivale al arrastrar y soltar de la V3).
local ROW_H = 120
local function attachDrag(handle: GuiObject, row: GuiObject, orderId: string)
	local start: Vector2? = nil
	handle.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			start = Vector2.new(input.Position.X, input.Position.Y)
			row.BackgroundTransparency = 0.5
		end
	end)
	local conn = UserInputService.InputEnded:Connect(function(input: InputObject)
		if start and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
			local dy = (input.Position.Y - start.Y) / App.scale()
			start = nil
			row.BackgroundTransparency = 0
			local delta = math.floor(dy / ROW_H + (dy >= 0 and 0.5 or -0.5))
			if delta ~= 0 then
				App.request("moveOrder", { orderId = orderId, delta = delta })
			end
		end
	end)
	row.Destroying:Connect(function()
		conn:Disconnect()
	end)
end

local function fixButton(g: any, o: any): Instance?
	local reason = o.reason or ""
	if string.find(reason, "^Faltan materiales") then
		return Ui.button("Comprar faltantes", "p", function()
			Screen.askBuyMissing(g, o)
		end, { small = true, name = "ComprarFaltantes" })
	elseif string.find(reason, "^Almacén lleno") then
		return Ui.button("Liberar lugar", "default", function()
			App.go("autos")
		end, { small = true })
	elseif string.find(reason, "^Avería") then
		local b = Rules.brokenStation(g)
		if b then
			local cost = Rules.maintCost(g.stations[b[1]])
			return Ui.button("Reparar · " .. Util.money(cost), "p", function()
				App.request("repairStation", { station = b[1] })
			end, { small = true })
		end
	elseif string.find(reason, "^Fondos") then
		return Ui.button("Ver ventas", "default", function()
			App.go("ventas")
		end, { small = true })
	end
	return nil
end

function Screen.askBuyMissing(g: any, o: any)
	if not o.missing then
		return
	end
	local rows: { string } = {}
	local total, tax, qty = 0, 0, 0
	for _, m in o.missing do
		local p = Rules.supplierPrice(g, m[1], m[2])
		table.insert(rows, m[2] .. " × " .. Catalog.matLabel(m[1]) .. "|" .. Util.money(p.base))
		total += p.total
		tax += p.tax
		qty += m[2]
	end
	local err = g.money < total and "Fondos insuficientes." or ((g.derived.matsUsed + qty > g.derived.caps.mats) and "No hay lugar en el depósito de materiales." or nil)
	table.insert(rows, "Impuesto (" .. Util.round(Catalog.RULES.taxRate * 100) .. "%)|" .. Util.money(tax))
	App.openDialog("confirm", {
		title = "Comprar materiales faltantes",
		lines = rows,
		total = Util.money(total),
		note = err and { "r", err } or nil,
		after = err == nil and "La orden sigue sola cuando haya materiales." or nil,
		okLabel = "Comprar · " .. Util.money(total),
		onOk = function()
			App.request("buyMissing", { orderId = o.id })
		end,
	})
end

function Screen.askBuyMaterial(g: any, mat: string, n: number)
	if g.derived.matsUsed + n > g.derived.caps.mats then
		App.toast("error", "No hay lugar para materiales (" .. g.derived.matsUsed .. "/" .. g.derived.caps.mats .. ").")
		return
	end
	local p = Rules.supplierPrice(g, mat, n)
	App.openDialog("confirm", {
		title = "Comprar " .. n .. " de " .. string.lower(Catalog.matLabel(mat)),
		lines = { "Precio del proveedor|" .. Util.money(p.base), "Impuesto|" .. Util.money(p.tax) },
		total = Util.money(p.total),
		note = g.money < p.total and { "r", "Fondos insuficientes." } or nil,
		okLabel = "Comprar",
		onOk = function()
			App.request("buyMaterial", { mat = mat, qty = n })
		end,
	})
end

local function orderRow(g: any, o: any, i: number, list: { any }): Frame
	local sn = o.design
	local c = sn and sn.calc
	local src = nil
	for _, d in g.designs do
		if sn and d.id == sn.id then
			src = d
		end
	end
	local newer = src and not src.template and (src.version or 0) > sn.version
	local st = o.paused and "pausada" or o.status
	local stInfo = STATUS[st] or STATUS["en cola"]
	local lines = g.derived.caps.lines

	local bar, fill = Ui.bar(0)
	local live = Ui.inline("", { size = Ui.S.xs, name = "EnVivo" })
	App.live(function(gg: any)
		local x = findOrder(gg, o.id)
		if x then
			Ui.setBar(fill, x.unitStarted and math.min(100, x.progress / math.max(1, x.unitTotal or 1) * 100) or 0)
			live.Text = liveText(gg, x)
		end
	end)

	local handle = Ui.new("Frame", { Name = "Manija", Size = UDim2.fromOffset(16, 16), BackgroundTransparency = 1, Active = true }, { Ui.icon("drag", 16, T.mut) })
	local chips: { Instance? } = {
		handle,
		Ui.paintChip(sn and sn.spec or { paint = { primary = "#444444" } }, 26, 18),
		Ui.grow(Ui.row({
			Ui.inline(sn and sn.name or "Diseño desconocido", { size = 15, weight = W.bold }),
			sn and Ui.chip("v" .. sn.version, "cn") or nil,
			Ui.inline("× " .. o.qty, { size = 15, weight = W.bold }),
		}, 6, { Size = UDim2.new(1, 0, 0, 0) })),
		newer and Ui.chip("Hay una versión nueva disponible (v" .. src.version .. ")", "cv") or nil,
		(sn and not src) and Ui.chip("Proyecto original eliminado", "cy") or nil,
		Ui.chip(stInfo[1], stInfo[2]),
		o.auto and Ui.chip("automática", "cv") or nil,
	}
	local curText = nil
	if o.unitStarted and o.cur then
		local mats = {}
		for _, k in Util.keys(o.cur.mats) do
			table.insert(mats, o.cur.mats[k] .. " " .. string.lower(Catalog.matLabel(k)))
		end
		curText = Ui.text("Unidad en curso: cobrado " .. Util.money(o.cur.charged) .. (o.cur.boost and (" (con recargo de aceleración ×" .. Util.num(o.cur.factor, 2) .. ")") or "") .. " · materiales " .. table.concat(mats, ", "), { size = Ui.S.xs, color = T.mut })
	end
	local cancel = Ui.button("Cancelar", "d", function()
		Screen.askCancel(g, o)
	end, { small = true, icon = "x", iconSize = 14, name = "CancelarOrden" })
	local row = Ui.card({
		Ui.row(chips, 10, { wrap = true }),
		Ui.row({ Ui.grow(bar), live }, 10),
		curText,
		st == "detenida" and Ui.note("r", o.reason or "Detenida", fixButton(g, o)) or nil,
		Ui.row({
			Ui.button("", "default", function()
				App.request("moveOrder", { orderId = o.id, delta = -1 })
			end, { small = true, icon = "up", iconSize = 14, disabled = i == 1, why = "Ya es la primera", name = "Subir" }),
			Ui.button("", "default", function()
				App.request("moveOrder", { orderId = o.id, delta = 1 })
			end, { small = true, icon = "down", iconSize = 14, disabled = i == #list, why = "Ya es la última", name = "Bajar" }),
			Ui.button(o.paused and "Reanudar" or "Pausar", "default", function()
				App.request("togglePause", { orderId = o.id })
			end, { small = true, icon = o.paused and "play" or "pause", iconSize = 14 }),
			Ui.selectF("Prioridad", o.priority, PRIOS, function(v: any)
				App.request("setPriority", { orderId = o.id, priority = v })
			end, { height = 32, name = "Prioridad" }),
			lines > 1 and Ui.selectF("Línea", o.line, (function()
				local opts = {}
				for k = 1, lines do
					table.insert(opts, { k, tostring(k) })
				end
				return opts
			end)(), function(v: any)
				App.request("setLine", { orderId = o.id, line = v })
			end, { height = 32, name = "Linea", disabled = o.unitStarted, why = "La unidad en curso no puede cambiar de línea" }) or nil,
			Ui.spacer(),
			Ui.inline(c and (Util.money(c.unitCost) .. " por unidad (fijado) · " .. Util.gameDuration(c.build) .. " base") or "", { size = Ui.S.xs, color = T.mut }),
			cancel,
		}, 6, { wrap = true }),
	}, { gap = 8, pad = { 10, 12 }, name = "Orden_" .. o.id })
	attachDrag(handle, row, o.id)
	return row
end

function Screen.askCancel(_g: any, o: any)
	local cu = o.unitStarted and o.cur or nil
	local matsTxt = ""
	if cu then
		local parts = {}
		for _, k in Util.keys(cu.mats) do
			table.insert(parts, cu.mats[k] .. " de " .. string.lower(Catalog.matLabel(k)))
		end
		matsTxt = table.concat(parts, ", ")
	end
	App.openDialog("confirm", {
		title = "¿Cancelar la orden?",
		body = "Quedan " .. (o.qty - o.done) .. " unidad(es) sin fabricar. " .. (cu and ("La unidad en curso se interrumpe y se reintegra exactamente lo que se registró al empezarla: <b>" .. Util.money(cu.charged) .. "</b>" .. (matsTxt ~= "" and (" y " .. matsTxt) or "") .. ".") or "No hay unidades en curso.") .. " Las terminadas siguen en el almacén.",
		okLabel = "Cancelar orden",
		cancel = "Volver",
		danger = true,
		onOk = function()
			App.request("cancelOrder", { orderId = o.id })
		end,
	})
end

function Screen.build(main: Frame, side: Frame)
	local g = App.g
	local caps = g.derived.caps
	local canOrder = false
	for _, d in g.designs do
		if not d.template then
			canOrder = true
		end
	end
	local staffed = false
	for _, e in g.employees do
		for _, s in Catalog.STATIONS do
			if e.assign == s[1] then
				staffed = true
			end
		end
	end
	Ui.row({
		Ui.button("Nueva orden de producción", "p", function()
			App.openDialog("order", { wide = true })
		end, { icon = "plus", disabled = not canOrder, why = "Primero guardá un diseño en el editor", name = "NuevaOrden" }),
		Ui.inline("Velocidad de las líneas ×" .. Util.num(g.derived.lineSpeed, 2) .. (staffed and "" or " · sin personal asignado (50%)"), { size = Ui.S.sm, color = T.mut }),
	}, 10, { wrap = true }).Parent = main
	if not canOrder then
		Ui.note("b", "Para fabricar necesitás un diseño guardado.", Ui.button("Abrir el editor", "default", function()
			App.go("editor")
		end, { small = true })).Parent = main
	end

	for line = 1, 4 do
		if line > caps.lines then
			local sede = nil
			for _, s in Catalog.SEDES do
				if s.lines >= line then
					sede = s
					break
				end
			end
			Ui.card({
				Ui.icon("lock", 16, T.mut),
				Ui.grow(Ui.inline("Línea " .. line, { size = 15, weight = W.bold, color = T.tx, transparency = 0.4 })),
				Ui.inline("Se habilita con la sede «" .. (sede and sede.name or "—") .. "»", { size = Ui.S.xs, color = T.mut, transparency = 0.4 }),
			}, { dir = "H", v = "C", gap = 10, transparency = 0.4, name = "LineaBloqueada_" .. line }).Parent = main
			continue
		end
		local orders = {}
		for _, o in g.production.orders do
			if o.line == line then
				table.insert(orders, o)
			end
		end
		local section = Ui.card({
			Ui.row({
				Ui.grow(Ui.inline("Línea " .. line, { size = 15, weight = W.bold })),
				#orders > 0 and Ui.row({
					Ui.inline(#orders .. " orden" .. (#orders > 1 and "es" or "") .. " · arrastrá", { size = Ui.S.xs, color = T.mut }),
					Ui.icon("drag", 12, T.mut),
					Ui.inline("o usá las flechas para reordenar", { size = Ui.S.xs, color = T.mut }),
				}, 4, { Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY }) or Ui.inline("Línea libre", { size = Ui.S.xs, color = T.mut }),
			}, 10),
		}, { gap = 8, name = "Linea_" .. line })
		if #orders > 0 then
			for i, o in orders do
				orderRow(g, o, i, orders).Parent = section
			end
		else
			Ui.empty(nil, "Sin órdenes. Las unidades se fabrican de a una, en el orden de la lista.", nil, { pad = 14 }).Parent = section
		end
		section.Parent = main
	end

	local hist = g.production.history or {}
	if #hist > 0 then
		local items: { Instance? } = { Ui.lbl("Órdenes terminadas · repetir") }
		for _, h in hist do
			local src = nil
			for _, d in g.designs do
				if d.id == h.design.id and not d.template then
					src = d
				end
			end
			local newer = src and (src.version or 0) > h.design.version
			local same
			same = Ui.button("Repetir con la misma versión (v" .. h.design.version .. ")", "default", function()
				App.request("repeatOrder", { historyId = h.id, mode = "same" }, { button = same })
			end, { small = true })
			local latest = nil
			if newer then
				latest = Ui.button("Repetir con la última versión (v" .. src.version .. ")", "p", function()
					App.request("repeatOrder", { historyId = h.id, mode = "latest" }, { button = latest })
				end, { small = true })
			end
			table.insert(items, Ui.card({
				Ui.paintChip(h.design.spec, 26, 18),
				Ui.grow(Ui.text(h.design.name .. " v" .. h.design.version .. " × " .. h.qty .. " <font color=\"#A3AAB8\" size=\"11\">· terminada el día " .. (h.day + 1) .. "</font>", { size = Ui.S.sm, weight = W.bold })),
				same,
				latest,
			}, { dir = "H", v = "C", gap = 10, wrap = true }))
		end
		Ui.col(items, 8).Parent = main
	end

	-- Estaciones de montaje
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
		local mt = Rules.maintCost(s)
		local cond = s.condition
		table.insert(stations, Ui.card({
			Ui.row({ Ui.grow(Ui.inline(st[2], { size = 15, weight = W.bold })), Ui.chip("Nv. " .. s.level, "cn"), s.broken and Ui.chip("Averiada", "cr") or nil }, 6),
			Ui.row({ Ui.inline("Estado", { size = Ui.S.xs, color = T.mut, width = 54 }), Ui.grow((Ui.bar(cond, cond < 30 and T.re or (cond < 60 and T.ye or T.gr)))), Ui.inline(math.floor(cond + 0.5) .. "%", { size = Ui.S.xs, weight = W.bold }) }, 10),
			Ui.text((#staff > 0 and table.concat(staff, ", ") or "Sin personal") .. " · ideal: " .. string.lower(st[3]), { size = Ui.S.xs, color = T.mut }),
			Ui.row({
				Ui.button((s.broken and "Reparar" or "Mantenimiento") .. " · " .. Util.money(mt), s.broken and "p" or "default", function()
					App.request("repairStation", { station = id })
				end, { small = true, disabled = mt == 0 or g.money < mt, why = mt == 0 and "En perfecto estado" or "Fondos insuficientes", name = "Reparar_" .. id }),
				Ui.button("Mejorar · " .. Util.money(up), "default", function()
					App.request("upgradeStation", { station = id })
				end, { small = true, disabled = s.level >= maxL or g.money < up, why = s.level >= maxL and "Nivel máximo para esta sede" or "Fondos insuficientes", name = "Mejorar_" .. id }),
			}, 6, { wrap = true }),
		}, { gap = 6, name = "Estacion_" .. id }))
	end
	Ui.col({
		Ui.lbl("Estaciones de montaje"),
		Ui.grid(stations, App.isPhone() and 2 or 3, nil, 10),
		Ui.text("Cada unidad desgasta las estaciones. Por debajo de " .. Catalog.RULES.breakdownAt .. "% se averían y la línea se detiene. Mejorar sube la velocidad un 15% por nivel promedio.", { size = Ui.S.xs, color = T.mut }),
	}, 8).Parent = main

	-- Columna lateral
	local wh = g.derived.warehouseUsed
	Ui.card({
		Ui.lbl("Capacidad"),
		Ui.row({ Ui.inline("Almacén", { size = Ui.S.xs, color = T.mut, width = 90 }), Ui.grow((Ui.bar(wh / math.max(1, caps.warehouse) * 100, wh >= caps.warehouse and T.re or nil))), Ui.inline(wh .. "/" .. caps.warehouse, { size = Ui.S.xs, weight = W.bold }) }, 10),
		Ui.text("Ocupan lugar las unidades en el almacén, reservadas o publicadas. Una unidad en fabricación reserva su lugar al empezar.", { size = Ui.S.xs, color = T.mut }),
	}, { gap = 8 }).Parent = side
	local hasAuto = Rules.has(g, "p3")
	local autoNode = Catalog.researchNode("p3")
	Ui.card({
		Ui.lbl("Controles"),
		Ui.row({
			Ui.grow(Ui.col({ Ui.text("Producción automática", { size = Ui.S.sm, weight = W.bold }), Ui.text(hasAuto and "Si una línea queda libre, crea una orden de 1 unidad con la última versión guardada del último diseño fabricado (si el proyecto se eliminó, repite la copia de esa orden)." or ("Requiere investigar «" .. (autoNode and autoNode.name or "Producción automática") .. "»."), { size = Ui.S.xs, color = T.mut }) }, 2)),
			Ui.toggle(g.production.auto == true, function()
				App.request("toggleAuto")
			end, not hasAuto, "Requiere investigar «" .. (autoNode and autoNode.name or "Producción automática") .. "»."),
		}, 10),
		Ui.row({
			Ui.grow(Ui.col({ Ui.text("Acelerar producción", { size = Ui.S.sm, weight = W.bold }), Ui.text("Regla: el recargo de +" .. Util.round((Catalog.RULES.boostCostFactor - 1) * 100) .. "% se decide al empezar cada unidad y queda registrado; apagarlo después no cambia lo cobrado. La velocidad ×2 rige mientras esté activa.", { size = Ui.S.xs, color = T.mut }) }, 2)),
			Ui.toggle(g.production.boost == true, function()
				App.request("toggleBoost")
			end),
		}, 10),
	}, { gap = 10, name = "Controles" }).Parent = side
	local mats: { Instance? } = { Ui.row({ Ui.grow(Ui.lbl("Materiales")), Ui.inline(Screen.matsText(g), { size = Ui.S.xs, color = T.mut }) }, 10) }
	for _, m in Catalog.MATERIALS do
		table.insert(mats, Ui.row({
			Ui.grow(Ui.text(m[2], { size = Ui.S.sm })),
			Ui.inline(Util.num(g.materials[m[1]] or 0), { size = Ui.S.sm, weight = W.bold }),
			Ui.button("+20", "q", function()
				Screen.askBuyMaterial(g, m[1], 20)
			end, { small = true, name = "Comprar_" .. m[1] }),
		}, 10))
	end
	table.insert(mats, Ui.text("Compra directa al proveedor con impuesto del " .. Util.round(Catalog.RULES.taxRate * 100) .. "%. También hay ofertas en el Mercado.", { size = Ui.S.xs, color = T.mut }))
	Ui.card(mats, { gap = 6, name = "Materiales" }).Parent = side
	Ui.card({
		Ui.lbl("Tiempo"),
		Ui.text("Los tiempos de fabricación están en <b>tiempo de juego</b>. A 1×, 1 segundo real = " .. Catalog.RULES.minutesPerRealSecond .. " minutos de juego; a 2× y 4× avanza más rápido. En pausa no se fabrica.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.4 }),
	}, { gap = 4 }).Parent = side
end

return Screen
