--!strict
--[[
	Catálogo de vehículos: los diseños guardados (con su año de modelo y generación, costo, precio de
	referencia y ventas estimadas) con acciones para lanzar un lote, editar, crear una nueva generación,
	duplicar o eliminar; y la historia de cada modelo (todas sus generaciones y lotes, con unidades
	vendidas, ingresos y resultado). Los lotes guardan su propia copia del diseño: editar o eliminar un
	diseño no cambia lo ya fabricado.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local Rules = require(Shared.Rules)
local DesignCalc = require(Shared.DesignCalc)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local Sheet = require(script.Parent.ScreenSheet)
local T = Ui.T
local W = Ui.W

local Screen = {
	title = "Catálogo de vehículos",
	icon = "car",
}

function Screen.head(g: any): { Instance }
	local n = 0
	for _, d in g.designs do
		if not d.template then
			n += 1
		end
	end
	return { Ui.chip(n .. (n == 1 and " diseño" or " diseños"), "cb"), Ui.chip(Util.num(g.counters.unitsSold) .. " vendidos en total", "cg") }
end

--[[ Historia de cada modelo y generación: el resumen permanente (lotes terminados, g.modelHistory) más los
	lotes que siguen activos. Devuelve una lista de { key, lineage, gen, name, modelYear, type, spec, stats,
	lots, produced, sold, discarded, revenue, cost, bestLotSold, bestLotProfit, bestMonth, active }. ]]
function Screen.generations(g: any): { any }
	local out, byKey = {}, {}
	for _, e in g.modelHistory or {} do
		local x = table.clone(e)
		x.active = 0
		byKey[e.key] = x
		table.insert(out, x)
	end
	for _, l in g.lots do
		local key = tostring(l.design.lineage or l.designId) .. "#" .. tostring(l.design.gen or 1)
		local x = byKey[key]
		if not x then
			x = { key = key, lineage = l.design.lineage or l.designId, gen = l.design.gen or 1, name = l.design.name, modelYear = l.design.modelYear, type = l.design.type, spec = l.design.spec, stats = l.design.calc, lots = 0, produced = 0, sold = 0, discarded = 0, revenue = 0, cost = 0, bestLotSold = 0, bestLotProfit = 0, bestMonth = 0, active = 0 }
			byKey[key] = x
			table.insert(out, x)
		end
		x.lots += 1
		x.active += 1
		x.produced += l.produced
		x.sold += l.sold
		x.discarded += l.discarded
		x.revenue += l.revenue
		x.cost += l.costSpent
		x.bestLotSold = math.max(x.bestLotSold, l.sold)
		x.bestMonth = math.max(x.bestMonth, l.bestMonth or 0, l.monthSold or 0)
	end
	return out
end

-- Totales de un diseño (todas las generaciones de su familia que comparten id o la suya propia).
function Screen.totals(g: any, design: any): any
	local key = tostring(design.lineage or design.id) .. "#" .. tostring(design.gen or 1)
	for _, x in Screen.generations(g) do
		if x.key == key then
			return x
		end
	end
	return { lots = 0, produced = 0, sold = 0, revenue = 0, cost = 0, discarded = 0, active = 0 }
end

function Screen.designRow(g: any, d: any): Frame
	local c = DesignCalc.computeDesign(g, d)
	local b = Catalog.base(d.baseId)
	local tot = Screen.totals(g, d)
	local actions: { Instance? } = {}
	if d.template then
		table.insert(actions, Ui.button("Usar plantilla", "p", function()
			App.closeAllDialogs()
			App.go("editor", { fromTemplate = d.id })
		end, { small = true }))
	else
		table.insert(actions, Ui.button("Lanzar lote", "p", function()
			App.closeAllDialogs()
			App.openDialog("lot", { designId = d.id, wide = true })
		end, { small = true, name = "LanzarLote" }))
		table.insert(actions, Ui.button("Editar", "default", function()
			App.closeAllDialogs()
			App.go("editor", { designId = d.id })
		end, { small = true, name = "Editar" }))
		table.insert(actions, Ui.button("Nueva generación", "default", function()
			App.closeAllDialogs()
			App.go("editor", { newGenOf = d.id })
		end, { small = true, name = "NuevaGeneracion", disabled = not Rules.canNewGeneration(g, d), why = "Una nueva generación necesita al menos un año desde la anterior (" .. tostring(d.modelYear) .. ")." }))
	end
	local dup
	dup = Ui.button("Duplicar", "q", function()
		App.request("dupDesign", { designId = d.id }, { button = dup })
	end, { small = true, icon = "copy", iconSize = 14 })
	table.insert(actions, dup)
	table.insert(actions, Ui.button("", "q", function()
		App.openDialog("confirm", {
			title = "¿Eliminar «" .. d.name .. "»?",
			body = (tot.active > 0 and ("Tiene " .. tot.active .. " lote(s) a la venta: siguen fabricándose y vendiéndose con su propia copia del diseño. ") or "") .. "El historial de ventas se conserva. Lo pagado en desarrollo no se devuelve (queda disponible para otros diseños).",
			okLabel = "Eliminar",
			danger = true,
			onOk = function()
				App.request("delDesign", { designId = d.id })
			end,
		})
	end, { small = true, icon = "trash", iconSize = 14, name = "EliminarDiseno" }))
	local est = (not d.template) and Rules.designSalesEstimate(g, c, d, c.price) or nil
	local row = Ui.card({
		Ui.paintChip(d, 44, 28),
		Ui.grow(Ui.col({
			Ui.row({ Ui.inline(d.name, { size = 15, weight = W.bold }), Ui.chip(d.template and "Plantilla" or (d.generation or ""), d.template and "cv" or "cb"), (not d.template and (d.version or 1) > 1) and Ui.chip("v" .. d.version, "cn") or nil }, 6, { wrap = true }),
			Ui.text(b.name .. " · " .. Catalog.TYPES[b.type] .. " · " .. c.hp .. " hp · costo " .. Util.money(c.unitCost) .. "/u · precio de referencia " .. Util.money(c.price) .. (est and (" · ≈ " .. Util.num(est.rate, 1) .. " ventas/min") or "") .. " · " .. Util.num(tot.sold) .. " vendidos", { size = Ui.S.xs, color = T.mut }),
		}, 2)),
	}, { dir = "H", v = "C", gap = 10, wrap = true, name = "Diseno_" .. tostring(d.id) })
	-- Los botones se crearon antes que la tarjeta: van al final de la fila (después del nombre).
	for i, a in actions do
		if a then
			(a :: any).LayoutOrder = 1e6 + i
			a.Parent = row
		end
	end
	return row
end

-- Historia de un modelo: todas sus generaciones con configuración, estadísticas, totales y récords.
local function familyCard(entries: { any }): Frame
	table.sort(entries, function(a: any, b: any): boolean
		return (a.gen or 1) < (b.gen or 1)
	end)
	local tot = { sold = 0, revenue = 0, cost = 0, discarded = 0, produced = 0 }
	for _, x in entries do
		for k in tot do
			tot[k] += x[k] or 0
		end
	end
	local last = entries[#entries]
	local profit = tot.revenue - tot.cost
	local rows: { Instance? } = {
		Ui.row({
			Ui.paintChip(last.spec or { paint = { primary = "#888888" } }, 34, 22),
			Ui.grow(Ui.col({
				Ui.text(last.name, { size = 16, weight = W.bold }),
				Ui.text((Catalog.TYPES[last.type] or "") .. " · " .. #entries .. (#entries == 1 and " generación" or " generaciones"), { size = Ui.S.xs, color = T.mut }),
			}, 2)),
			Ui.col({
				Ui.inline(Util.num(tot.sold) .. " vendidos", { size = Ui.S.sm, weight = W.bold }),
				Ui.inline("beneficio " .. Util.money(profit), { size = Ui.S.xs, color = profit >= 0 and T.gr or T.re2 }),
			}, 2, { Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY, h = "R" }),
		}, 10, { wrap = App.isPhone() }),
	}
	for _, x in entries do
		local sp = x.spec or {}
		local parts = sp.parts or {}
		local function pn(cat: string): string
			local p = Catalog.part(cat, parts[cat])
			return p and p.name or "—"
		end
		local st = x.stats or {}
		local res = x.revenue - x.cost
		table.insert(rows, Ui.card({
			Ui.row({
				Ui.chip(x.gen .. ".ª gen. · " .. tostring(x.modelYear or ""), "cb"),
				x.active > 0 and Ui.chip("En venta", "cg") or Ui.chip("Fuera de venta", "cn"),
				Ui.grow(Ui.text(pn("motor") .. " · " .. pn("transmision") .. " · " .. pn("seguridad"), { size = Ui.S.xs, color = T.tx2 })),
			}, 8, { wrap = true }),
			st.hp and Ui.text(string.format("%d hp · 0–100 en %s s · consumo %s · seguridad %d · fiabilidad %d · calidad %d · costo %s/u", st.hp or 0, Util.num(st.accel or 0, 1), Util.num(st.consumption or 0, 1), st.safety or 0, st.durability or 0, st.quality or 0, Util.money(st.unitCost or 0)), { size = Ui.S.xs, color = T.mut }) or nil,
			Ui.text(string.format("%s lotes · %s fabricados · %s vendidos · %s descartados · ingresos %s · gastos %s · beneficio %s", Util.num(x.lots), Util.num(x.produced), Util.num(x.sold), Util.num(x.discarded), Util.money(x.revenue), Util.money(x.cost), Util.money(res)), { size = Ui.S.xs, color = res >= 0 and T.gr or T.re2 }),
			Ui.text("Récords: mejor lote " .. Util.num(x.bestLotSold) .. " vendidos" .. ((x.bestLotProfit or 0) > 0 and (" · lote más rentable " .. Util.money(x.bestLotProfit)) or "") .. " · mejor mes " .. Util.num(x.bestMonth or 0) .. " ventas", { size = Ui.S.xs, color = T.ye }),
		}, { gap = 4, pad = { 8, 10 }, bg = T.p2, name = "Generacion_" .. x.key }))
	end
	return Ui.card(rows, { gap = 8, name = "Familia_" .. tostring(last.lineage) })
end

-- Récords de la empresa (de todo el historial permanente y los lotes activos).
local function recordsCard(gens: { any }): Frame?
	if #gens == 0 then
		return nil
	end
	local best, profit, month = gens[1], gens[1], gens[1]
	for _, x in gens do
		if x.sold > best.sold then
			best = x
		end
		if x.revenue - x.cost > profit.revenue - profit.cost then
			profit = x
		end
		if (x.bestMonth or 0) > (month.bestMonth or 0) then
			month = x
		end
	end
	return Ui.card({
		Ui.lbl("Récords de la empresa"),
		Ui.between("Más vendido", best.name .. " " .. best.gen .. ".ª gen. · " .. Util.num(best.sold)),
		Ui.between("Más rentable", profit.name .. " " .. profit.gen .. ".ª gen. · " .. Util.money(profit.revenue - profit.cost), { color = T.gr }),
		Ui.between("Mejor mes de un modelo", month.name .. " · " .. Util.num(month.bestMonth or 0) .. " ventas"),
	}, { gap = 6, name = "Records" })
end

function Screen.build(main: Frame, side: Frame)
	local g = App.g
	local tabs, tab = Sheet.tabs("autos", { { "disenos", "Diseños", #g.designs }, { "historia", "Historia de modelos" } }, "disenos")
	tabs.Parent = main
	if tab == "disenos" then
		Ui.row({
			Ui.button("Nuevo diseño", "p", function()
				App.go("editor", { fresh = true })
			end, { small = true, icon = "plus", name = "NuevoDiseno" }),
			Sheet.search("autos", "Buscar diseño"),
		}, 10, { wrap = true }).Parent = main
		local shown = 0
		for _, d in g.designs do
			if Sheet.matches("autos", d.name, d.generation) then
				Screen.designRow(g, d).Parent = main
				shown += 1
			end
		end
		if #g.designs == 0 then
			Ui.empty("pen", "Todavía no guardaste diseños. Abrí Diseño, elegí una base y guardalo en Revisión.", Ui.button("Abrir el editor", "p", function()
				App.go("editor")
			end, { small = true })).Parent = main
		elseif shown == 0 then
			Ui.empty("search", "Ningún diseño coincide con la búsqueda.").Parent = main
		end
	else
		local gens = Screen.generations(g)
		local fam: { [string]: { any } } = {}
		local order = {}
		for _, x in gens do
			local key = tostring(x.lineage)
			if not fam[key] then
				fam[key] = {}
				table.insert(order, key)
			end
			table.insert(fam[key], x)
		end
		if #order == 0 then
			Ui.empty("car", "Todavía no fabricaste ningún modelo. La historia guarda cada generación con su configuración, sus ventas y sus récords.").Parent = main
		end
		local rec = recordsCard(gens)
		if rec then
			rec.Parent = main
		end
		for _, key in order do
			familyCard(fam[key]).Parent = main
		end
		Ui.text("La historia de cada modelo se conserva siempre (aunque elimines el diseño). El detalle lote por lote queda para los últimos " .. Catalog.RULES.maxLotHistory .. " lotes en Ventas.", { size = Ui.S.xs, color = T.mut }).Parent = main
	end

	-- Columna lateral
	Ui.card({
		Ui.lbl("Generaciones"),
		Ui.text("Con los años el mercado espera más de cada auto (en " .. Rules.year(g) .. ", atractivo " .. Util.round(Rules.eraBaseline(Rules.yearFrac(g))) .. "). Una <b>nueva generación</b> conserva el nombre y la historia del modelo, toma el año actual y puede usar las tecnologías nuevas. La anterior sigue en el catálogo.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.45 }),
	}, { gap = 4, name = "Generaciones" }).Parent = side
	Ui.card({
		Ui.lbl("Diseños y lotes"),
		Ui.text("Cada lote guarda una copia del diseño con su costo y precio de referencia. Editar el diseño cambia los lotes futuros, nunca los ya lanzados.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.45 }),
		Ui.between("Diseños guardados", tostring(#g.designs) .. "/" .. Catalog.RULES.maxDesigns),
	}, { gap = 6 }).Parent = side
end

return Screen
