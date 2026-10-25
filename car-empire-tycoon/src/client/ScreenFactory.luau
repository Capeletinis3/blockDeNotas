--!strict
-- Fábrica (SCREENS.fabrica de la V3): cola de la línea, unidad en curso, materiales y capacidad.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local T = Ui.T
local W = Ui.W

local Screen = {
	title = "Fábrica",
	symbol = "🏭",
	color = Color3.fromHex("#FFB36B"),
	bg = Color3.fromHex("#33241A"),
}

local STATUS_CHIP = { ["en producción"] = "cg", detenida = "cr", pausada = "cy", ["en cola"] = "cn" }

function Screen.head(g: any): { Instance }
	local caps = g.derived.caps
	local full = g.derived.warehouseUsed >= caps.warehouse
	return {
		Ui.chip(caps.lines .. (caps.lines == 1 and " línea" or " líneas"), "cn"),
		Ui.chip("Almacén " .. g.derived.warehouseUsed .. "/" .. caps.warehouse, full and "cr" or "cb"),
	}
end

local function supplierPrice(mat: string, qty: number): any
	local m = Catalog.material(mat)
	local base = Util.round(m[3] * qty)
	local tax = Util.round(base * Catalog.RULES.taxRate)
	return { base = base, tax = tax, total = base + tax }
end
Screen.supplierPrice = supplierPrice

-- Compra los paquetes necesarios para cubrir lo que falta (cada compra la valida el servidor).
local function buyMissing(missing: { any })
	for _, m in missing do
		local need = m[2]
		while need > 0 do
			local pack = need <= 10 and 10 or 50
			local r = App.request("buyMaterial", { mat = m[1], qty = pack })
			if not r.ok then
				return
			end
			need -= pack
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

local function orderRow(_g: any, o: any): Frame
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
		curText = Ui.text("Unidad en curso: cobrado " .. Util.money(o.cur.charged) .. " · materiales " .. table.concat(mats, ", "), { size = Ui.S.xs, color = T.mut })
	end

	local stopped = nil
	if st == "detenida" then
		local fix = nil
		if o.missing then
			local total = 0
			for _, m in o.missing do
				local need = m[2]
				while need > 0 do
					local pack = need <= 10 and 10 or 50
					total += supplierPrice(m[1], pack).total
					need -= pack
				end
			end
			fix = Ui.button("Comprar faltantes · " .. Util.money(total), "p", function()
				buyMissing(o.missing)
			end, { small = true })
		elseif string.find(o.reason, "^Almacén") then
			fix = Ui.button("Liberar lugar", "default", function()
				App.go("autos")
			end, { small = true })
		elseif string.find(o.reason, "^Fondos") then
			fix = Ui.button("Ver ventas", "default", function()
				App.go("ventas")
			end, { small = true })
		end
		stopped = Ui.note("r", o.reason, fix)
	end

	return Ui.card({
		Ui.row({
			Ui.paintChip(sn.spec, 26, 18),
			Ui.inline(sn.name .. " v" .. sn.version, { size = 15, weight = W.bold }),
			Ui.chip(st, STATUS_CHIP[st] or "cn"),
			Ui.chip(o.done .. " de " .. o.qty, "cn"),
			Ui.spacer(),
			Ui.inline(Util.money(sn.calc.unitCost) .. " por unidad (fijado)", { size = Ui.S.xs, color = T.mut }),
		}, 8, { wrap = true }),
		Ui.row({ Ui.grow(bar, { Size = UDim2.new(0, 0, 0, 7) }), pctLabel }, 10),
		etaLabel,
		curText,
		stopped,
		Ui.row({
			Ui.button(o.paused and "▶ Reanudar" or "❚❚ Pausar", "default", function()
				App.request("togglePause", { orderId = o.id })
			end, { small = true }),
			Ui.spacer(),
			Ui.button("✕ Cancelar", "d", function()
				local refund = o.unitStarted and o.cur and o.cur.charged or 0
				App.openDialog("confirm", {
					title = "¿Cancelar la orden?",
					body = "Quedan " .. (o.qty - o.done) .. " unidad(es) sin fabricar. "
						.. (refund > 0 and ("La unidad en curso se interrumpe y se reintegra exactamente lo cobrado al empezarla: " .. Util.money(refund) .. " y sus materiales.") or "No hay unidades en curso.")
						.. " Las terminadas siguen en el almacén.",
					okLabel = "Cancelar orden",
					danger = true,
					onOk = function()
						App.request("cancelOrder", { orderId = o.id })
					end,
				})
			end, { small = true }),
		}, 6),
	}, { gap = 8, pad = { 10, 12 } })
end

function Screen.build(main: Frame, side: Frame)
	local g = App.g
	local hasDesigns = #g.designs > 0
	Ui.row({
		Ui.button("+ Nueva orden de producción", "p", function()
			App.openDialog("order", {})
		end, { disabled = not hasDesigns, why = "Primero guardá un diseño en el editor" }),
		Ui.text("Velocidad de la línea ×" .. Util.num(g.derived.lineSpeed, 2) .. " · sin personal asignado (50 %). El personal llega en una etapa posterior.", { size = Ui.S.sm, color = T.mut, width = 420 }),
	}, 12, { wrap = true, Parent = main })
	if not hasDesigns then
		Ui.note("b", "Para fabricar necesitás un diseño guardado.", Ui.button("Abrir el editor", "default", function()
			App.go("editor")
		end, { small = true })).Parent = main
	end

	local rows: { Instance? } = {
		Ui.row({ Ui.inline("Línea 1", { size = 15, weight = W.bold }), Ui.spacer(), Ui.inline(#g.production.orders > 0 and (#g.production.orders .. (#g.production.orders == 1 and " orden" or " órdenes") .. " · se fabrican en orden de llegada") or "Línea libre", { size = Ui.S.xs, color = T.mut }) }, 8),
	}
	for _, o in g.production.orders do
		table.insert(rows, orderRow(g, o))
	end
	if #g.production.orders == 0 then
		table.insert(rows, Ui.text("No hay órdenes. Creá una para fabricar unidades de un diseño guardado.", { size = Ui.S.sm, color = T.mut }))
	end
	Ui.card(rows, { gap = 8, Parent = nil }).Parent = main

	local hist: { Instance? } = { Ui.lbl("Órdenes terminadas") }
	if #g.production.history == 0 then
		table.insert(hist, Ui.text("Todavía no terminaste ninguna orden.", { size = Ui.S.sm, color = T.mut }))
	end
	for _, h in g.production.history do
		table.insert(hist, Ui.line(h.qty .. " × " .. h.name .. " v" .. h.version, "Día " .. (h.day + 1), { color = T.mut, weight = W.med }))
	end
	Ui.card(hist, { gap = 4 }).Parent = main

	Ui.note("b", "Cada orden guarda una copia de la versión del diseño y su costo unitario: aunque después edites el proyecto, sus unidades se fabrican igual. El dinero y los materiales se cobran al empezar cada unidad.").Parent = main

	-- Lateral: materiales y capacidad
	local matRows: { Instance? } = { Ui.lbl("Materiales") }
	for _, m in Catalog.MATERIALS do
		local id = m[1]
		local packs: { Instance? } = {}
		for _, qty in Catalog.SUPPLIER_PACKS do
			local p = supplierPrice(id, qty)
			table.insert(packs, Ui.button("+" .. qty .. " · " .. Util.money(p.total), "default", function()
				App.request("buyMaterial", { mat = id, qty = qty })
			end, { small = true, disabled = g.money < p.total, why = "Fondos insuficientes (" .. Util.money(p.total) .. ")" }))
		end
		table.insert(matRows, Ui.col({
			Ui.row({ Ui.grow(Ui.text(m[2] .. "  <font color=\"#7D8493\">" .. Util.money(m[3]) .. " c/u</font>", { size = Ui.S.sm })), Ui.inline(Util.num(g.materials[id] or 0), { size = 15, weight = W.bold }) }, 8),
			Ui.row(packs, 6),
		}, 6))
	end
	local caps = g.derived.caps
	local matBar = Ui.bar(g.derived.matsUsed / caps.mats * 100)
	table.insert(matRows, Ui.hr())
	table.insert(matRows, Ui.row({ Ui.inline("Depósito", { size = Ui.S.xs, color = T.mut }), Ui.grow(matBar, { Size = UDim2.new(0, 0, 0, 7) }), Ui.inline(g.derived.matsUsed .. "/" .. caps.mats, { size = Ui.S.xs, weight = W.bold }) }, 8))
	table.insert(matRows, Ui.text("Los precios del proveedor incluyen un 5 % de impuesto.", { size = Ui.S.xs, color = T.mut }))
	Ui.card(matRows, { gap = 10 }).Parent = side

	local whBar = Ui.bar((g.derived.warehouseUsed + g.derived.inProgress) / caps.warehouse * 100, g.derived.warehouseUsed >= caps.warehouse and T.re or nil)
	Ui.card({
		Ui.lbl("Capacidad"),
		Ui.row({ Ui.inline("Almacén", { size = Ui.S.xs, color = T.mut }), Ui.grow(whBar, { Size = UDim2.new(0, 0, 0, 7) }), Ui.inline((g.derived.warehouseUsed + g.derived.inProgress) .. "/" .. caps.warehouse, { size = Ui.S.xs, weight = W.bold }) }, 8),
		Ui.text("El almacén cuenta las unidades terminadas que esperan y las que se están fabricando. Las del salón usan su propio lugar.", { size = Ui.S.xs, color = T.mut }),
	}, { gap = 8 }).Parent = side
end

return Screen
