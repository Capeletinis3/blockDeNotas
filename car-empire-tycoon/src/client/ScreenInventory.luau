--!strict
-- Mis autos e inventario (SCREENS.autos de la V3): vehículos (búsqueda, filtros, orden, detalle),
-- diseños y plantillas (fabricar, editar, duplicar, eliminar), piezas sueltas y materiales.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local DesignCalc = require(Shared.DesignCalc)
local Rules = require(Shared.Rules)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local Sheet = require(script.Parent.ScreenSheet)
local Factory = require(script.Parent.ScreenFactory)
local T = Ui.T
local W = Ui.W

local Screen = {
	title = "Mis autos e inventario",
	icon = "car",
	color = Color3.fromHex("#8DB8FF"),
	bg = Color3.fromHex("#14233D"),
}

Screen.STATUS_LABEL = { almacen = "En el almacén", salon = "En el salón", reservado = "Reservada", mercado = "En el mercado", vendido = "Vendida" }
Screen.STATUS_CHIP = { almacen = "cb", salon = "cg", reservado = "cy", mercado = "cv", vendido = "cn" }

function Screen.head(g: any): { Instance }
	local caps = g.derived.caps
	return {
		Ui.chip("Almacén " .. g.derived.warehouseUsed .. "/" .. caps.warehouse, g.derived.warehouseUsed >= caps.warehouse and "cr" or "cb"),
		Ui.chip("Salón " .. g.derived.showroomUsed .. "/" .. caps.showroom, "cg"),
	}
end

-- Acciones disponibles para una unidad según su estado (todas las valida el servidor).
function Screen.unitActions(g: any, u: any, compact: boolean?): { Instance? }
	local caps = g.derived.caps
	local out: { Instance? } = {}
	local whFull = g.derived.warehouseUsed >= caps.warehouse
	local function act(label: string, kind: string, action: string, payload: any, opts: any?)
		local b
		b = Ui.button(label, kind, function()
			App.request(action, payload, { button = b })
		end, opts or { small = true })
		table.insert(out, b)
	end
	if u.status == "almacen" or u.status == "reservado" then
		act("Enviar al salón", "p", "sendToShowroom", { unitId = u.id }, { small = true, disabled = g.derived.showroomUsed >= caps.showroom, why = "Salón lleno (" .. g.derived.showroomUsed .. "/" .. caps.showroom .. ")" })
	end
	if u.status == "almacen" then
		if not compact then
			table.insert(out, Ui.button("Publicar en el mercado", "default", function()
				App.openDialog("publish", { unitId = u.id })
			end, { small = true, icon = "globe" }))
			act("Reservar", "default", "reserve", { unitId = u.id })
		end
		table.insert(out, Ui.button("Mayorista · " .. Util.money(Rules.wholesale(u)), "default", function()
			App.openDialog("wholesale", { unitId = u.id })
		end, { small = true }))
		if not compact then
			table.insert(out, Ui.button("Reciclar", "q", function()
				local back = {}
				for _, k in Util.keys(u.stats.mats) do
					local n = math.floor(u.stats.mats[k] / 2)
					if n > 0 then
						table.insert(back, n .. " de " .. string.lower(Catalog.matLabel(k)))
					end
				end
				App.openDialog("confirm", {
					title = "¿Reciclar " .. u.name .. " (" .. u.serial .. ")?",
					body = "La unidad se desarma y desaparece. Recuperás la mitad de sus materiales: " .. table.concat(back, ", ") .. " (lo que no entre en el depósito se pierde). No se devuelve dinero.",
					okLabel = "Reciclar",
					danger = true,
					onOk = function()
						App.request("recycle", { unitId = u.id })
					end,
				})
			end, { small = true, icon = "trash" }))
		end
	elseif u.status == "reservado" then
		act("Liberar reserva", "default", "unreserve", { unitId = u.id })
	elseif u.status == "salon" then
		act("Retirar al almacén", "default", "returnToWarehouse", { unitId = u.id }, { small = true, disabled = whFull, why = "Almacén lleno (" .. Factory.warehouseText(g) .. ")" })
		if not compact then
			table.insert(out, Ui.button("Precio y clientes", "default", function()
				App.go("ventas")
			end, { small = true, icon = "tag" }))
		end
	elseif u.status == "mercado" then
		act("Retirar del mercado", "default", "marketUnpublish", { unitId = u.id })
	end
	return out
end

local function unitRow(g: any, u: any): Frame
	local fp = Rules.finalPrice(u)
	local margin = (u.soldPrice or fp) - u.cost
	local row = Ui.card({
		Ui.row({
			Ui.carThumb(u.spec, 84, 50),
			Ui.grow(Ui.col({
				Ui.text(u.name .. "  <font color=\"#7D8493\">" .. (u.designVersion and ("v" .. u.designVersion .. " · ") or "") .. u.serial .. "</font>", { size = 15, weight = W.bold }),
				Ui.text(Catalog.TYPES[u.type] .. " · calidad " .. u.quality .. " · " .. u.stats.hp .. " hp · " .. (u.bought and "comprada en el mercado" or ("fabricada el día " .. (u.createdDay + 1))), { size = Ui.S.xs, color = T.mut }),
			}, 2)),
			Ui.chip(Screen.STATUS_LABEL[u.status] or u.status, Screen.STATUS_CHIP[u.status]),
		}, 10),
		Ui.row({
			Ui.inline("Costo " .. Util.money(u.cost), { size = Ui.S.sm, color = T.mut }),
			Ui.inline(u.status == "vendido" and ("Vendida en " .. Util.money(u.soldPrice or 0)) or ("Precio final " .. Util.money(fp)), { size = Ui.S.sm }),
			Ui.inline("Margen " .. Util.money(margin), { size = Ui.S.sm, color = margin >= 0 and T.gr or T.re2, weight = W.bold }),
		}, 16, { wrap = true }),
		Ui.row({
			Ui.button("Detalle", "default", function()
				App.openDialog("unitDetail", { unitId = u.id, wide = true })
			end, { small = true, icon = "eye" }),
			table.unpack(Screen.unitActions(g, u)),
		}, 6, { wrap = true }),
	}, { gap = 8, name = "Unidad_" .. u.serial })
	if u.status == "vendido" then
		row.BackgroundTransparency = 0.4
	end
	return row
end

local function designRow(g: any, d: any): Frame
	local c = DesignCalc.computeDesign(g, d)
	local made = 0
	for _, u in g.units do
		if u.designId == d.id then
			made += 1
		end
	end
	local inUse = 0
	for _, o in g.production.orders do
		if o.designId == d.id then
			inUse += 1
		end
	end
	local base = Catalog.base(d.baseId)
	local actions: { Instance? } = {}
	if d.template then
		table.insert(actions, Ui.button("Usar plantilla", "p", function()
			App.go("editor", { fromTemplate = d.id })
		end, { small = true }))
	else
		table.insert(actions, Ui.button("Fabricar", "p", function()
			App.openDialog("order", { designId = d.id })
		end, { small = true, icon = "factory" }))
		table.insert(actions, Ui.button("Editar", "default", function()
			App.go("editor", { designId = d.id })
		end, { small = true, icon = "pen" }))
		local dup
		dup = Ui.button("Duplicar", "q", function()
			App.request("dupDesign", { designId = d.id }, { button = dup })
		end, { small = true, icon = "copy" })
		table.insert(actions, dup)
	end
	table.insert(actions, Ui.button("Eliminar", "q", function()
		App.openDialog("confirm", {
			title = "¿Eliminar «" .. d.name .. "»?",
			body = (inUse > 0 and ("Tiene " .. inUse .. " orden(es) activa(s): seguirán fabricándose con su propia copia de la versión confirmada. ") or "") .. "Las unidades ya fabricadas se conservan con su configuración. Lo pagado en desarrollo no se devuelve (queda disponible para otros diseños).",
			okLabel = "Eliminar",
			danger = true,
			onOk = function()
				App.request("delDesign", { designId = d.id })
			end,
		})
	end, { small = true, icon = "trash" }))
	return Ui.card({
		Ui.row({
			Ui.carThumb(d, 84, 50),
			Ui.grow(Ui.col({
				Ui.text(d.name .. "  " .. (d.template and "<font color=\"#F7C95C\">plantilla</font>" or ("<font color=\"#C4BDFF\">v" .. d.version .. "</font>")), { size = 15, weight = W.bold }),
				Ui.text(base.name .. " · " .. Util.money(c.unitCost) .. "/u · precio recomendado " .. Util.money(c.price) .. " · " .. made .. " fabricadas" .. (inUse > 0 and (" · " .. inUse .. " en producción") or ""), { size = Ui.S.xs, color = T.mut }),
			}, 2)),
		}, 10),
		Ui.row(actions, 6, { wrap = true }),
	}, { gap = 8, name = "Diseno_" .. d.id })
end

function Screen.build(main: Frame, side: Frame)
	local g = App.g
	local active, sold = 0, 0
	for _, u in g.units do
		if u.status ~= "vendido" then
			active += 1
		else
			sold += 1
		end
	end
	local partsN = 0
	for _, p in g.parts do
		partsN += p.qty
	end
	local tabs, tab = Sheet.tabs("autos", { { "veh", "Vehículos", active }, { "designs", "Diseños y plantillas", #g.designs }, { "parts", "Piezas", partsN }, { "mats", "Materiales" } }, "veh")
	tabs.Parent = main
	if tab == "veh" then
		local designOpts = { { "todos", "Todos" } }
		local seen = {}
		for _, u in g.units do
			local k = u.designId or ("mk:" .. u.name)
			if not seen[k] then
				seen[k] = true
				table.insert(designOpts, { k, u.name })
			end
		end
		local typeOpts = { { "todos", "Todos" } }
		for _, k in Util.keys(Catalog.TYPES) do
			table.insert(typeOpts, { k, Catalog.TYPES[k] })
		end
		Ui.row({
			Sheet.search("veh", "Buscar modelo o número de serie"),
			Sheet.filter("vSt", "Estado", { { "activos", "Disponibles" }, { "almacen", "Almacén" }, { "salon", "Salón" }, { "reservado", "Reservadas" }, { "mercado", "Mercado" }, { "vendido", "Vendidas" }, { "todos", "Todas" } }, "activos"),
			Sheet.filter("vTy", "Tipo", typeOpts, "todos"),
			Sheet.filter("vDe", "Diseño", designOpts, "todos"),
			Sheet.filter("vSo", "Orden", { { "nuevo", "Más nuevas" }, { "precio", "Precio" }, { "calidad", "Calidad" }, { "margen", "Margen" } }, "nuevo"),
		}, 8, { wrap = true }).Parent = main
		local st = App.ui.filters.vSt or "activos"
		local ty = App.ui.filters.vTy or "todos"
		local de = App.ui.filters.vDe or "todos"
		local so = App.ui.filters.vSo or "nuevo"
		local list = {}
		for _, u in g.units do
			local okSt = st == "todos" or (st == "activos" and u.status ~= "vendido") or u.status == st
			local okTy = ty == "todos" or u.type == ty
			local okDe = de == "todos" or (u.designId or ("mk:" .. u.name)) == de
			if okSt and okTy and okDe and Sheet.matches("veh", u.name, u.serial) then
				table.insert(list, u)
			end
		end
		table.sort(list, function(a, b)
			if so == "precio" then
				return Rules.finalPrice(a) > Rules.finalPrice(b)
			elseif so == "calidad" then
				return a.quality > b.quality
			elseif so == "margen" then
				return (Rules.finalPrice(a) - a.cost) > (Rules.finalPrice(b) - b.cost)
			end
			if a.createdDay ~= b.createdDay then
				return a.createdDay > b.createdDay
			end
			return a.serial > b.serial
		end)
		if #list == 0 then
			Ui.note("b", #g.units == 0 and "Todavía no tenés unidades. Creá una orden en la Fábrica." or "No hay unidades con esos filtros.", #g.units == 0 and Ui.button("Ir a la fábrica", "default", function()
				App.go("fabrica")
			end, { small = true }) or nil).Parent = main
		end
		local shownSold = false
		for i, u in list do
			if i > 60 then
				Ui.text("Mostrando 60 de " .. #list .. ". Usá la búsqueda o los filtros.", { size = Ui.S.xs, color = T.mut }).Parent = main
				break
			end
			if u.status == "vendido" and not shownSold and st ~= "vendido" then
				Ui.lbl("Vendidas recientemente").Parent = main
				shownSold = true
			end
			unitRow(g, u).Parent = main
		end
	elseif tab == "designs" then
		Ui.row({
			Sheet.search("des", "Buscar diseño"),
			Ui.button("Nuevo proyecto", "p", function()
				App.go("editor", { new = true })
			end, { small = true, icon = "plus" }),
		}, 8, { wrap = true }).Parent = main
		local any = false
		for _, d in g.designs do
			if Sheet.matches("des", d.name) then
				designRow(g, d).Parent = main
				any = true
			end
		end
		if not any then
			Ui.note("b", #g.designs == 0 and "Sin diseños guardados. Abrí el escritorio de diseño." or "Ningún diseño coincide con la búsqueda.").Parent = main
		end
	elseif tab == "parts" then
		if #g.parts == 0 then
			Ui.note("b", "No tenés piezas sueltas. Se compran en el Mercado y, al instalarlas en un diseño, cubren su costo de desarrollo.").Parent = main
		end
		for _, p in g.parts do
			local d = Catalog.part(p.cat, p.id)
			Ui.card({
				Ui.row({
					Ui.ico("wrench", T.vi2, T.input, 36),
					Ui.grow(Ui.col({ Ui.text(d.name .. " × " .. p.qty, { size = 14, weight = W.bold }), Ui.text(Catalog.catLabel(p.cat) .. " · cubre un desarrollo de " .. Util.money(d.proto) .. " · " .. d.desc, { size = Ui.S.xs, color = T.mut }) }, 2)),
					Ui.button("Usar en el editor", "default", function()
						App.go("editor", { installPart = { cat = p.cat, id = p.id } })
					end, { small = true }),
				}, 10),
			}).Parent = main
		end
	else
		local rows: { Instance? } = {}
		for _, m in Catalog.MATERIALS do
			table.insert(rows, Ui.line(m[2] .. "  <font color=\"#7D8493\">· " .. Util.money(Rules.supplierPrice(g, m[1], 1).base) .. " c/u en el proveedor</font>", Util.num(g.materials[m[1]] or 0)))
		end
		Ui.card(rows, { gap = 0, pad = { 4, 14 } }).Parent = main
		Ui.text("Depósito: " .. Factory.matsText(g), { size = Ui.S.sm, color = T.mut }).Parent = main
		Ui.row({ Ui.button("Comprar en la fábrica", "default", function()
			App.go("fabrica")
		end, { small = true }), Ui.button("Ofertas del mercado", "default", function()
			App.ui.tabs.mercado = "material"
			App.go("mercado")
		end, { small = true }) }, 8).Parent = main
	end

	-- Lateral
	local caps = g.derived.caps
	local wh = Ui.bar(g.derived.warehouseUsed / caps.warehouse * 100, g.derived.warehouseUsed >= caps.warehouse and T.re or nil)
	local sh = Ui.bar(g.derived.showroomUsed / caps.showroom * 100, T.gr)
	Ui.card({
		Ui.lbl("Capacidad (regla única)"),
		Ui.row({ Ui.inline("Almacén", { size = Ui.S.xs, color = T.mut }), Ui.grow(wh, { Size = UDim2.new(0, 0, 0, 7) }), Ui.inline(g.derived.warehouseUsed .. "/" .. caps.warehouse, { size = Ui.S.xs, weight = W.bold }) }, 8),
		Ui.row({ Ui.inline("Salón", { size = Ui.S.xs, color = T.mut }), Ui.grow(sh, { Size = UDim2.new(0, 0, 0, 7) }), Ui.inline(g.derived.showroomUsed .. "/" .. caps.showroom, { size = Ui.S.xs, weight = W.bold }) }, 8),
		Ui.text("Almacén: " .. Factory.warehouseText(g) .. ". Cuenta las unidades en el almacén, reservadas o publicadas en el mercado y las que se están fabricando. El salón cuenta solo las exhibidas. Las vendidas no ocupan lugar.", { size = Ui.S.xs, color = T.mut }),
	}, { gap = 8 }).Parent = side
	local summary: { Instance? } = { Ui.lbl("Resumen") }
	for _, st in { "almacen", "reservado", "salon", "mercado" } do
		local n = 0
		for _, u in g.units do
			if u.status == st then
				n += 1
			end
		end
		table.insert(summary, Ui.line(Screen.STATUS_LABEL[st], tostring(n), { leftColor = T.mut }))
	end
	table.insert(summary, Ui.hr())
	-- Totales históricos: salen de los contadores, no de las listas recortadas.
	table.insert(summary, Ui.line("Fabricadas (total)", tostring(g.counters.unitsProduced), { leftColor = T.mut }))
	table.insert(summary, Ui.line("Vendidas (total)", tostring(g.counters.unitsSold), { leftColor = T.mut }))
	table.insert(summary, Ui.line("Ingresos totales", Util.money(g.counters.revenueTotal or 0), { leftColor = T.mut }))
	table.insert(summary, Ui.line("Margen total", Util.money(g.counters.marginTotal or 0), { leftColor = T.mut, color = (g.counters.marginTotal or 0) >= 0 and T.gr or T.re2 }))
	Ui.card(summary, { gap = 0 }).Parent = side
	local _ = sold
end

return Screen
