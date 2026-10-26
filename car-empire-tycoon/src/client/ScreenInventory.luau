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

-- Totales de todos los lotes (activos e historial) de un diseño o de una familia.
function Screen.totals(g: any, match: (any) -> boolean): any
	local t = { lots = 0, produced = 0, sold = 0, revenue = 0, cost = 0, discarded = 0, active = 0 }
	for _, list in { g.lots, g.lotHistory } do
		for _, l in list do
			if match(l) then
				t.lots += 1
				t.produced += l.produced
				t.sold += l.sold
				t.revenue += l.revenue
				t.cost += l.costSpent
				t.discarded += l.discarded or 0
				if l.saleState == "en venta" then
					t.active += 1
				end
			end
		end
	end
	return t
end

function Screen.designRow(g: any, d: any): Frame
	local c = DesignCalc.computeDesign(g, d)
	local b = Catalog.base(d.baseId)
	local tot = Screen.totals(g, function(l: any): boolean
		return l.designId == d.id
	end)
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
		end, { small = true, name = "NuevaGeneracion", disabled = (d.modelYear or 0) >= Rules.year(g), why = "Una nueva generación necesita un año de modelo posterior (" .. tostring(d.modelYear) .. ")." }))
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

-- Historia de un modelo: todas las generaciones (familia) con sus lotes.
local function familyCard(g: any, lineage: string, entries: { any }): Frame
	table.sort(entries, function(a: any, b: any): boolean
		if a.design.gen ~= b.design.gen then
			return (a.design.gen or 1) < (b.design.gen or 1)
		end
		return (a.createdDay or 0) < (b.createdDay or 0)
	end)
	local tot = Screen.totals(g, function(l: any): boolean
		return (l.design.lineage or l.designId) == lineage
	end)
	local profit = tot.revenue - tot.cost
	local rows: { Instance? } = {
		Ui.row({
			Ui.paintChip(entries[#entries].design.spec, 34, 22),
			Ui.grow(Ui.text(entries[#entries].design.name, { size = 15, weight = W.bold })),
			Ui.chip(tot.lots .. (tot.lots == 1 and " lote" or " lotes"), "cn"),
		}, 10),
		Ui.row({
			Ui.inline(Util.num(tot.sold) .. " vendidos", { size = Ui.S.xs, color = T.mut }),
			Ui.inline("ingresos " .. Util.money(tot.revenue), { size = Ui.S.xs, color = T.gr }),
			Ui.inline("resultado " .. Util.money(profit), { size = Ui.S.xs, color = profit >= 0 and T.gr or T.re2 }),
			tot.discarded > 0 and Ui.inline(Util.num(tot.discarded) .. " descartados", { size = Ui.S.xs, color = T.re2 }) or nil,
		}, 12, { wrap = true }),
	}
	for _, l in entries do
		local st = l.saleState == "en venta" and "En venta" or (l.saleState == "agotado" and "Agotado" or "Retirado")
		table.insert(rows, Ui.between((l.design.spec.generation or "") .. " · " .. Util.gameDate(l.createdDay) .. " · " .. Util.num(l.sold) .. "/" .. Util.num(l.produced), st .. " · " .. Util.money(l.revenue - l.costSpent), { size = Ui.S.xs, color = l.revenue - l.costSpent >= 0 and T.gr or T.re2 }))
	end
	return Ui.card(rows, { gap = 6, name = "Familia_" .. lineage })
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
		local fam: { [string]: { any } } = {}
		local order = {}
		for _, list in { g.lots, g.lotHistory } do
			for _, l in list do
				local key = l.design.lineage or l.designId
				if not fam[key] then
					fam[key] = {}
					table.insert(order, key)
				end
				table.insert(fam[key], l)
			end
		end
		if #order == 0 then
			Ui.empty("car", "Todavía no fabricaste ningún modelo. La historia muestra cada generación con sus lotes y resultados.").Parent = main
		end
		for _, key in order do
			familyCard(g, key, fam[key]).Parent = main
		end
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
