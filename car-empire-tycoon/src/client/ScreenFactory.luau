--!strict
--[[
	Fábrica (SCREENS.fabrica de la V3): líneas con su cola, prioridades, reordenamiento (botones o
	arrastre), unidad en curso con lo cobrado, estaciones de montaje (estado, desgaste, averías,
	mantenimiento, mejoras), producción acelerada y automática, repetición de órdenes y materiales.
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
	color = Color3.fromHex("#FFB36B"),
	bg = Color3.fromHex("#33241A"),
}

local STATUS_CHIP = { ["en producción"] = "cg", detenida = "cr", pausada = "cy", ["en cola"] = "cn" }
local PRIO = { alta = "Alta", media = "Media", baja = "Baja" }
local PRIO_NEXT = { alta = "media", media = "baja", baja = "alta" }
local ROW_H = 150

-- Texto único de capacidad del almacén (misma regla que valida el servidor).
function Screen.warehouseText(g: any): string
	local d = g.derived
	return d.warehouseUsed .. "/" .. d.caps.warehouse .. " (" .. d.warehouseFinished .. " terminadas + " .. d.inProgress .. " en fabricación)"
end

function Screen.matsText(g: any): string
	local d = g.derived
	return d.matsUsed .. "/" .. d.caps.mats .. (d.matsInProcess > 0 and (" (" .. d.matsInProcess .. " en fabricación)") or "")
end

function Screen.head(g: any): { Instance }
	local caps = g.derived.caps
	local full = g.derived.warehouseUsed >= caps.warehouse
	return {
		Ui.chip(caps.lines .. (caps.lines == 1 and " línea" or " líneas"), "cn"),
		Ui.chip("Almacén " .. g.derived.warehouseUsed .. "/" .. caps.warehouse, full and "cr" or "cb"),
		g.production.boost and Ui.chip("Acelerada ×2", "cy") or nil :: any,
		g.production.auto and Ui.chip("Automática", "cv") or nil :: any,
	}
end

local function packsFor(g: any, missing: { any }): ({ any }, number)
	local list, total = {}, 0
	for _, m in missing do
		local need = m[2]
		while need > 0 do
			local pack = need <= 10 and 10 or 50
			table.insert(list, { m[1], pack })
			total += Rules.supplierPrice(g, m[1], pack).total
			need -= pack
		end
	end
	return list, total
end

local function buyMissing(g: any, missing: { any }, btn: any)
	local list = packsFor(g, missing)
	for _, item in list do
		local r = App.request("buyMaterial", { mat = item[1], qty = item[2] }, { button = btn, key = item[1] })
		if not r.ok then
			return
		end
	end
end

local function remainingText(g: any, o: any): string
	local mins = math.max(0, (o.unitTotal or 0) - (o.progress or 0)) / math.max(0.01, g.derived.lineSpeed)
	if g.time.speed == 0 then
		return Util.gameDuration(mins) .. " de juego · en pausa"
	end
	local secs = math.ceil(mins / (Catalog.RULES.minutesPerRealSecond * g.time.speed))
	return Util.gameDuration(mins) .. " de juego · ≈ " .. secs .. " s reales"
end

-- Arrastre vertical de la manija: al soltar, mueve la orden tantas posiciones como filas recorrió.
local function attachDrag(handle: GuiObject, row: GuiObject, orderId: string)
	local start: Vector2? = nil
	handle.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			start = Vector2.new(input.Position.X, input.Position.Y)
			row.BackgroundTransparency = 0.3
		end
	end)
	local conn
	conn = UserInputService.InputEnded:Connect(function(input: InputObject)
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
	-- La conexión global se suelta cuando la fila se destruye (cada reconstrucción crea filas nuevas).
	row.Destroying:Connect(function()
		conn:Disconnect()
	end)
end

local function orderRow(g: any, o: any, i: number, n: number): Frame
	local sn = o.design
	local st = o.paused and "pausada" or o.status
	local pctLabel = Ui.inline("", { size = Ui.S.xs, color = T.tx2 })
	local bar, fill = Ui.bar(0, st == "detenida" and T.re or T.vi)
	local etaLabel = Ui.text("", { size = Ui.S.xs, color = T.mut })
	App.live(function(gg: any)
		for _, x in gg.production.orders do
			if x.id == o.id then
				local pct = x.unitStarted and (x.progress / math.max(1, x.unitTotal) * 100) or 0
				Ui.setBar(fill, pct)
				pctLabel.Text = x.unitStarted and (math.floor(pct) .. "%") or "—"
				etaLabel.Text = x.unitStarted and ("Faltan " .. remainingText(gg, x)) or (x.paused and "Pausada" or "Esperando para empezar la próxima unidad")
			end
		end
	end)

	local curText = nil
	if o.unitStarted and o.cur then
		local mats = {}
		for _, k in Util.keys(o.cur.mats) do
			table.insert(mats, o.cur.mats[k] .. " " .. string.lower(Catalog.matLabel(k)))
		end
		curText = Ui.text("Unidad en curso: cobrado " .. Util.money(o.cur.charged) .. (o.cur.boost and (" (con recargo de aceleración ×" .. Util.num(o.cur.factor, 2) .. ")") or "") .. " · materiales " .. table.concat(mats, ", "), { size = Ui.S.xs, color = T.mut })
	end

	local stopped = nil
	if st == "detenida" then
		local fix = nil
		if o.missing then
			local _, total = packsFor(g, o.missing)
			local btn
			btn = Ui.button("Comprar faltantes · " .. Util.money(total), "p", function()
				buyMissing(g, o.missing, btn)
			end, { small = true })
			fix = btn
		elseif string.find(o.reason, "^Almacén") then
			fix = Ui.button("Liberar lugar", "default", function()
				App.go("autos")
			end, { small = true })
		elseif string.find(o.reason, "^Fondos") then
			fix = Ui.button("Ver ventas", "default", function()
				App.go("ventas")
			end, { small = true })
		elseif string.find(o.reason, "^Avería") then
			for _, s in Catalog.STATIONS do
				local station = g.stations[s[1]]
				if station.broken then
					local cost = Rules.maintCost(station)
					local btn
					btn = Ui.button("Reparar · " .. Util.money(cost), "p", function()
						App.request("repairStation", { station = s[1] }, { button = btn })
					end, { small = true })
					fix = btn
					break
				end
			end
		end
		stopped = Ui.note("r", o.reason, fix)
	end

	local lines = g.derived.caps.lines
	local handle = Ui.new("TextButton", { Name = "Arrastrar", Text = "", Size = UDim2.fromOffset(24, 30), BackgroundTransparency = 1 }, { Ui.icon("grip", 18, T.mut) })
	local card = Ui.card({
		Ui.row({
			handle,
			Ui.carThumb(sn.spec, 56, 34),
			Ui.inline(sn.name .. " v" .. sn.version, { size = 15, weight = W.bold }),
			Ui.chip(st, STATUS_CHIP[st] or "cn"),
			Ui.chip(o.done .. " de " .. o.qty, "cn"),
			o.auto and Ui.chip("automática", "cv") or nil,
			Ui.spacer(),
			Ui.inline(Util.money(sn.calc.unitCost) .. "/u fijado", { size = Ui.S.xs, color = T.mut }),
		}, 8, { wrap = true }),
		Ui.row({ Ui.grow(bar, { Size = UDim2.new(0, 0, 0, 7) }), pctLabel }, 10),
		etaLabel,
		curText,
		stopped,
		Ui.row({
			Ui.button("", "default", function()
				App.request("moveOrder", { orderId = o.id, delta = -1 })
			end, { small = true, width = 36, icon = "up", disabled = i == 1, why = "Ya es la primera de la línea", name = "Subir" }),
			Ui.button("", "default", function()
				App.request("moveOrder", { orderId = o.id, delta = 1 })
			end, { small = true, width = 36, icon = "down", disabled = i == n, why = "Ya es la última de la línea", name = "Bajar" }),
			Ui.button("Prioridad: " .. PRIO[o.priority], "default", function()
				App.request("setPriority", { orderId = o.id, priority = PRIO_NEXT[o.priority] })
			end, { small = true, name = "Prioridad" }),
			lines > 1 and Ui.button("Línea " .. o.line, "default", function()
				App.request("setLine", { orderId = o.id, line = (o.line % lines) + 1 })
			end, { small = true, disabled = o.unitStarted, why = "La unidad en curso no puede cambiar de línea" }) or nil,
			Ui.button(o.paused and "Reanudar" or "Pausar", "default", function()
				App.request("togglePause", { orderId = o.id })
			end, { small = true, icon = o.paused and "play" or "pause" }),
			Ui.spacer(),
			Ui.button("Cancelar", "d", function()
				local refund = o.unitStarted and o.cur and o.cur.charged or 0
				App.openDialog("confirm", {
					title = "¿Cancelar la orden?",
					body = "Quedan " .. (o.qty - o.done) .. " unidad(es) sin fabricar. "
						.. (refund > 0 and ("La unidad en curso se interrumpe y se reintegra exactamente lo cobrado al empezarla: " .. Util.money(refund) .. " y sus materiales, que vuelven al depósito (ya estaban contados en su capacidad).") or "No hay unidades en curso.")
						.. " Las terminadas siguen en el almacén.",
					okLabel = "Cancelar orden",
					danger = true,
					onOk = function()
						App.request("cancelOrder", { orderId = o.id })
					end,
				})
			end, { small = true, icon = "x" }),
		}, 6, { wrap = true }),
	}, { gap = 8, pad = { 10, 12 }, name = "Orden_" .. o.id })
	attachDrag(handle, card, o.id)
	return card
end

local function stationsCard(g: any): Frame
	local rows: { Instance? } = { Ui.row({ Ui.lbl("Estaciones de montaje"), Ui.spacer(), Ui.inline("Velocidad ×" .. Util.num(g.derived.lineSpeed, 2), { size = Ui.S.xs, color = T.mut }) }, 8) }
	local maxLv = Rules.maxStationLevel(g)
	for _, s in Catalog.STATIONS do
		local st = g.stations[s[1]]
		local staff = Rules.assignedCount(g, s[1])
		local cost = Rules.maintCost(st)
		local up = Rules.upgradeCost(st)
		local bar = Ui.bar(st.condition, st.broken and T.re or (st.condition < 40 and T.ye or T.gr))
		local repair, upgrade
		repair = Ui.button(st.broken and ("Reparar · " .. Util.money(cost)) or ("Mantener · " .. Util.money(cost)), st.broken and "p" or "default", function()
			App.request("repairStation", { station = s[1] }, { button = repair })
		end, { small = true, disabled = cost <= 0 or g.money < cost, why = cost <= 0 and "Está en perfecto estado" or "Fondos insuficientes", icon = "wrench" })
		upgrade = Ui.button("Mejorar · " .. Util.money(up), "default", function()
			App.request("upgradeStation", { station = s[1] }, { button = upgrade })
		end, { small = true, disabled = st.level >= maxLv or g.money < up, why = st.level >= maxLv and ("Nivel máximo para la sede (" .. maxLv .. ")") or "Fondos insuficientes", icon = "up" })
		table.insert(rows, Ui.col({
			Ui.row({ Ui.inline(s[2], { size = Ui.S.sm, weight = W.bold }), Ui.chip("Nv. " .. st.level, "cn"), st.broken and Ui.chip("Averiada", "cr") or nil, Ui.spacer(), Ui.inline(staff .. "/" .. Catalog.RULES.assignMax.station .. " " .. string.lower(s[3]) .. "(s)", { size = Ui.S.xs, color = T.mut }) }, 6),
			Ui.row({ Ui.grow(bar, { Size = UDim2.new(0, 0, 0, 7) }), Ui.inline(math.floor(st.condition) .. "%", { size = Ui.S.xs, weight = W.bold }) }, 8),
			Ui.row({ repair, upgrade }, 6, { wrap = true }),
		}, 6))
	end
	table.insert(rows, Ui.text("Cada unidad desgasta las estaciones. Por debajo de " .. Catalog.RULES.breakdownAt .. " % se averían y detienen la producción hasta repararlas. Mejorar sube la velocidad (+15 % por nivel promedio).", { size = Ui.S.xs, color = T.mut }))
	return Ui.card(rows, { gap = 10 })
end

function Screen.build(main: Frame, side: Frame)
	local g = App.g
	local canOrder = false
	for _, d in g.designs do
		if not d.template then
			canOrder = true
		end
	end
	local boost, auto
	boost = Ui.button(g.production.boost and "Acelerada ×2 · apagar" or "Acelerar ×2 (+40 % costo)", g.production.boost and "v" or "default", function()
		App.request("toggleBoost", nil, { button = boost })
	end, { small = true, icon = "play" })
	auto = Ui.button(g.production.auto and "Automática: sí" or "Automática: no", g.production.auto and "v" or "default", function()
		App.request("toggleAuto", nil, { button = auto })
	end, { small = true, disabled = not Rules.has(g, "p3"), why = "Requiere investigar «Producción automática»" })
	Ui.row({
		Ui.button("Nueva orden de producción", "p", function()
			App.openDialog("order", {})
		end, { disabled = not canOrder, why = "Primero guardá un diseño en el editor", icon = "plus" }),
		boost,
		auto,
	}, 10, { wrap = true, Parent = main })
	local staffNote = Rules.stationStaff(g) > 0 and "con personal asignado" or "sin personal asignado (50 %)"
	Ui.text("Velocidad de las líneas ×" .. Util.num(g.derived.lineSpeed, 2) .. " · " .. staffNote .. ". La aceleración solo cambia el costo de las unidades que empiezan después.", { size = Ui.S.sm, color = T.mut }).Parent = main
	if not canOrder then
		Ui.note("b", "Para fabricar necesitás un diseño guardado.", Ui.button("Abrir el editor", "default", function()
			App.go("editor")
		end, { small = true })).Parent = main
	end

	local caps = g.derived.caps
	for line = 1, 4 do
		if line > caps.lines then
			local sede = nil
			for _, s in Catalog.SEDES do
				if s.lines >= line then
					sede = s
					break
				end
			end
			Ui.card({ Ui.row({ Ui.icon("lock", 16, T.mut), Ui.inline("Línea " .. line, { size = 15, weight = W.bold, color = T.mut }), Ui.spacer(), Ui.inline("Se habilita con la sede «" .. (sede and sede.name or "—") .. "»", { size = Ui.S.xs, color = T.mut }) }, 8) }, { transparency = 0.4 }).Parent = main
		else
			local list = {}
			for _, o in g.production.orders do
				if o.line == line then
					table.insert(list, o)
				end
			end
			local rows: { Instance? } = {
				Ui.row({ Ui.inline("Línea " .. line, { size = 15, weight = W.bold }), Ui.spacer(), Ui.inline(#list > 0 and (#list .. (#list == 1 and " orden" or " órdenes") .. " · arrastrá la manija o usá las flechas (respeta la prioridad)") or "Línea libre", { size = Ui.S.xs, color = T.mut }) }, 8),
			}
			for i, o in list do
				table.insert(rows, orderRow(g, o, i, #list))
			end
			Ui.card(rows, { gap = 8 }).Parent = main
		end
	end

	-- Historial con repetición: misma versión o última versión guardada.
	local hist: { Instance? } = { Ui.lbl("Órdenes terminadas") }
	if #g.production.history == 0 then
		table.insert(hist, Ui.text("Todavía no terminaste ninguna orden.", { size = Ui.S.sm, color = T.mut }))
	end
	for _, h in g.production.history do
		local exists = false
		if h.design then
			for _, d in g.designs do
				if d.id == h.design.id and not d.template then
					exists = d.version ~= h.design.version and d.version or true
				end
			end
		end
		table.insert(hist, Ui.col({
			Ui.line(h.qty .. " × " .. (h.design and (h.design.name .. " v" .. h.design.version) or "orden antigua") .. "  <font color=\"#7D8493\">línea " .. tostring(h.line or 1) .. "</font>", "Día " .. (h.day + 1), { color = T.mut, weight = W.med }),
			h.design and Ui.row({
				Ui.button("Repetir misma versión", "default", function()
					App.request("repeatOrder", { historyId = h.id, mode = "same" })
				end, { small = true, icon = "copy" }),
				Ui.button(type(exists) == "number" and ("Repetir con v" .. exists) or "Repetir última versión", "default", function()
					App.request("repeatOrder", { historyId = h.id, mode = "latest" })
				end, { small = true, disabled = not exists, why = "El proyecto ya no existe" }),
			}, 6, { wrap = true }) or Ui.text("Sin copia del diseño (versión anterior del juego): no se puede repetir.", { size = Ui.S.xs, color = T.mut }),
		}, 4))
	end
	Ui.card(hist, { gap = 8 }).Parent = main

	Ui.note("b", "Cada orden guarda una copia de la versión del diseño y su costo unitario: aunque después edites o elimines el proyecto, sus unidades se fabrican igual. El dinero y los materiales se cobran al empezar cada unidad y quedan registrados en ella.").Parent = main

	-- Lateral: estaciones, materiales y capacidad
	stationsCard(g).Parent = side
	local matRows: { Instance? } = { Ui.lbl("Materiales") }
	for _, m in Catalog.MATERIALS do
		local id = m[1]
		local packs: { Instance? } = {}
		for _, qty in Catalog.SUPPLIER_PACKS do
			local p = Rules.supplierPrice(g, id, qty)
			local full = g.derived.matsUsed + qty > caps.mats
			local b
			b = Ui.button("+" .. qty .. " · " .. Util.money(p.total), "default", function()
				App.request("buyMaterial", { mat = id, qty = qty }, { button = b, key = id .. qty })
			end, { small = true, disabled = g.money < p.total or full, why = full and ("No hay lugar en el depósito (" .. Screen.matsText(g) .. ")") or ("Fondos insuficientes (" .. Util.money(p.total) .. ")") })
			table.insert(packs, b)
		end
		table.insert(matRows, Ui.col({
			Ui.row({ Ui.grow(Ui.text(m[2] .. "  <font color=\"#7D8493\">" .. Util.money(Rules.supplierPrice(g, id, 1).base) .. " c/u</font>", { size = Ui.S.sm })), Ui.inline(Util.num(g.materials[id] or 0), { size = 15, weight = W.bold }) }, 8),
			Ui.row(packs, 6, { wrap = true }),
		}, 6))
	end
	local matBar = Ui.bar(g.derived.matsUsed / caps.mats * 100)
	table.insert(matRows, Ui.hr())
	table.insert(matRows, Ui.row({ Ui.inline("Depósito", { size = Ui.S.xs, color = T.mut }), Ui.grow(matBar, { Size = UDim2.new(0, 0, 0, 7) }), Ui.inline(g.derived.matsUsed .. "/" .. caps.mats, { size = Ui.S.xs, weight = W.bold }) }, 8))
	table.insert(matRows, Ui.text("El depósito cuenta lo guardado y lo que tienen las unidades en fabricación: si cancelás, vuelve sin pasarse del límite. Los precios incluyen un 5 % de impuesto.", { size = Ui.S.xs, color = T.mut }))
	Ui.card(matRows, { gap = 10 }).Parent = side

	local whBar = Ui.bar(g.derived.warehouseUsed / caps.warehouse * 100, g.derived.warehouseUsed >= caps.warehouse and T.re or nil)
	Ui.card({
		Ui.lbl("Capacidad del almacén"),
		Ui.row({ Ui.grow(whBar, { Size = UDim2.new(0, 0, 0, 7) }), Ui.inline(g.derived.warehouseUsed .. "/" .. caps.warehouse, { size = Ui.S.xs, weight = W.bold }) }, 8),
		Ui.text(Screen.warehouseText(g) .. ". Las del salón usan su propio lugar.", { size = Ui.S.xs, color = T.mut }),
	}, { gap = 8 }).Parent = side
end

return Screen
