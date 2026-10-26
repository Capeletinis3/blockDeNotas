--!strict
--[[
	Mis autos e inventario (SCREENS.autos de la V3): vehículos con búsqueda y filtros, piezas sueltas,
	materiales y diseños/plantillas; al costado, la capacidad (regla única) y el resumen por estado.
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
local hex = Ui.hex

local Screen = {
	title = "Mis autos e inventario",
	icon = "car",
}

Screen.STATUS_LABEL = { almacen = "En el almacén", salon = "En el salón", reservado = "Reservada", mercado = "Publicada en el mercado", vendido = "Vendida" }
Screen.STATUS_CHIP = { almacen = "cb", salon = "cg", reservado = "cy", mercado = "cv", vendido = "cn" }
local RAR = { ["Común"] = "cn", Rara = "cb", ["Épica"] = "cv", Legendaria = "cy" }
Screen.RAR = RAR

function Screen.head(g: any): { Instance }
	local d = g.derived
	return {
		Ui.chip("Almacén " .. d.warehouseUsed .. "/" .. d.caps.warehouse, d.warehouseUsed >= d.caps.warehouse and "cr" or "cb"),
		Ui.chip("Salón " .. d.showroomUsed .. "/" .. d.caps.showroom, "cg"),
	}
end

-- Confirmaciones de la V3 que usan varias pantallas.
function Screen.askWholesale(_g: any, u: any)
	local p = Rules.wholesale(u)
	local fp = Rules.finalPrice(u)
	App.openDialog("confirm", {
		title = "¿Vender " .. u.name .. " al mayorista?",
		body = "Venta inmediata por <b>" .. Util.money(p) .. "</b> (costo " .. Util.money(u.cost) .. " × " .. Util.num(Catalog.RULES.wholesaleFactor, 2) .. "). Margen: <font color=\"#42E58D\"><b>" .. Util.money(p - u.cost) .. "</b></font>. Frente al precio de lista (" .. Util.money(fp) .. ") dejás de ganar " .. Util.money(math.max(0, fp - p)) .. ".",
		okLabel = "Vender · " .. Util.money(p),
		onOk = function()
			local r = App.request("wholesale", { unitId = u.id })
			if r.ok then
				App.closeAllDialogs()
			end
		end,
	})
end

function Screen.askRecycle(_g: any, u: any)
	local back = {}
	for _, k in Util.keys(u.stats.mats) do
		local n = math.floor(u.stats.mats[k] / 2)
		if n > 0 then
			table.insert(back, n .. " de " .. string.lower(Catalog.matLabel(k)))
		end
	end
	App.openDialog("confirm", {
		title = "¿Reciclar " .. u.name .. " (" .. u.serial .. ")?",
		body = "La unidad se desarma y desaparece. Recuperás la mitad de sus materiales: " .. table.concat(back, ", ") .. ". No se devuelve dinero. No se puede deshacer.",
		okLabel = "Reciclar",
		danger = true,
		onOk = function()
			local r = App.request("recycle", { unitId = u.id })
			if r.ok then
				App.closeAllDialogs()
			end
		end,
	})
end

-- Acciones válidas para cada estado (unitActions de la V3). Todas las valida el servidor.
function Screen.unitActions(g: any, u: any): { Instance? }
	local caps = g.derived.caps
	local out: { Instance? } = {}
	local whFull = g.derived.warehouseUsed >= caps.warehouse
	local function act(label: string, kind: string, action: string, opts: any?)
		local b
		local o = opts or {}
		o.small = true
		b = Ui.button(label, kind, function()
			App.request(action, { unitId = u.id }, { button = b })
		end, o)
		table.insert(out, b)
	end
	if u.status == "almacen" then
		act("Enviar al salón", "p", "sendToShowroom", { disabled = g.derived.showroomUsed >= caps.showroom, why = "Salón lleno (" .. g.derived.showroomUsed .. "/" .. caps.showroom .. ")", name = "EnviarSalon" })
		table.insert(out, Ui.button("Publicar en el mercado", "default", function()
			App.openDialog("publish", { unitId = u.id })
		end, { small = true }))
		act("Reservar", "default", "reserve")
		table.insert(out, Ui.button("Vender al mayorista · " .. Util.money(Rules.wholesale(u)), "default", function()
			Screen.askWholesale(g, u)
		end, { small = true, name = "Mayorista" }))
		table.insert(out, Ui.button("Reciclar", "q", function()
			Screen.askRecycle(g, u)
		end, { small = true, icon = "recycle", iconSize = 14 }))
	elseif u.status == "salon" then
		act("Retirar al almacén", "default", "returnToWarehouse", { disabled = whFull, why = "Almacén lleno" })
		table.insert(out, Ui.button("Precio y descuento", "default", function()
			App.closeAllDialogs()
			App.go("ventas")
		end, { small = true }))
		act("Reservar", "default", "reserve", { disabled = whFull, why = "Las reservadas usan lugar del almacén y está lleno" })
	elseif u.status == "reservado" then
		act("Liberar reserva", "default", "unreserve")
		table.insert(out, Ui.inline("Reservada: no se ofrece a clientes ni al mercado.", { size = Ui.S.xs, color = T.mut }))
	elseif u.status == "mercado" then
		table.insert(out, Ui.button("Ver mis publicaciones", "default", function()
			App.ui.tabs.mercado = "mine"
			App.closeAllDialogs()
			App.go("mercado")
		end, { small = true }))
		act("Retirar del mercado", "default", "marketUnpublish")
	elseif u.status == "vendido" then
		local sale = nil
		for _, s in g.sales do
			if s.unitId == u.id then
				sale = s
			end
		end
		table.insert(out, Ui.inline("Vendida el día " .. ((u.soldDay or 0) + 1) .. " por " .. Util.money(u.soldPrice or 0) .. (sale and (" · margen " .. Util.money(sale.margin) .. " · " .. sale.channel) or ""), { size = Ui.S.xs, color = T.mut }))
	end
	return out
end

local function unitRow(g: any, u: any): Frame
	return Ui.card({
		Ui.row({
			Ui.paintChip(u.spec, 44, 28, true),
			Ui.grow(Ui.col({
				Ui.text(u.name .. " <font color=\"#A3AAB8\" size=\"11\">" .. u.serial .. "</font>", { size = 15, weight = W.bold }),
				Ui.text(Catalog.TYPES[u.type] .. " · calidad " .. u.quality .. " · costo " .. Util.money(u.cost) .. " · precio " .. Util.money(Rules.finalPrice(u)) .. (u.discount > 0 and (" (−" .. u.discount .. "%)") or "") .. (u.bought and " · comprado en el mercado" or ""), { size = Ui.S.xs, color = T.mut }),
			}, 2)),
			Ui.chip(Screen.STATUS_LABEL[u.status] or u.status, Screen.STATUS_CHIP[u.status]),
			Ui.button("Detalle", "q", function()
				App.openDialog("unitDetail", { unitId = u.id, wide = true })
			end, { small = true, name = "Detalle" }),
		}, 10, { wrap = App.isPhone() }),
		Ui.row(Screen.unitActions(g, u), 6, { wrap = true }),
	}, { gap = 8, name = "Unidad_" .. u.serial })
end

-- Fila de un diseño o plantilla (designRow de la V3; también la usa «Modelos anteriores»).
function Screen.designRow(g: any, d: any): Frame
	local c = DesignCalc.computeDesign(g, d)
	local b = Catalog.base(d.baseId)
	local made = 0
	for _, u in g.units do
		if u.designId == d.id then
			made += 1
		end
	end
	local actions: { Instance? } = {}
	if d.template then
		table.insert(actions, Ui.button("Usar plantilla", "p", function()
			App.closeAllDialogs()
			App.go("editor", { fromTemplate = d.id })
		end, { small = true }))
	else
		table.insert(actions, Ui.button("Fabricar", "p", function()
			App.ui.orderDraft = nil
			App.openDialog("order", { designId = d.id, wide = true })
		end, { small = true, name = "Fabricar" }))
		table.insert(actions, Ui.button("Editar", "default", function()
			App.closeAllDialogs()
			App.go("editor", { designId = d.id })
		end, { small = true, name = "Editar" }))
	end
	local dup
	dup = Ui.button("Duplicar", "q", function()
		App.request("dupDesign", { designId = d.id }, { button = dup })
	end, { small = true, icon = "copy", iconSize = 14 })
	table.insert(actions, dup)
	table.insert(actions, Ui.button("", "q", function()
		local active = 0
		for _, o in g.production.orders do
			if o.designId == d.id then
				active += 1
			end
		end
		App.openDialog("confirm", {
			title = "¿Eliminar «" .. d.name .. "»?",
			body = (active > 0 and ("Tiene " .. active .. " orden(es) activa(s): seguirán fabricándose con su propia copia de la versión confirmada. ") or "") .. "Las unidades ya fabricadas se conservan. Lo pagado en desarrollo no se devuelve (queda disponible para otros diseños).",
			okLabel = "Eliminar",
			danger = true,
			onOk = function()
				App.request("delDesign", { designId = d.id })
			end,
		})
	end, { small = true, icon = "trash", iconSize = 14, name = "EliminarDiseno" }))
	local row = Ui.card({
		Ui.paintChip(d, 44, 28),
		Ui.grow(Ui.col({
			Ui.row({ Ui.inline(d.name, { size = 15, weight = W.bold }), Ui.chip(d.template and "Plantilla" or ("Diseño v" .. d.version), d.template and "cv" or "cg") }, 6),
			Ui.text(b.name .. " · " .. Catalog.TYPES[b.type] .. " · " .. c.hp .. " hp · " .. Util.money(c.unitCost) .. "/u · precio sugerido " .. Util.money(c.price) .. " · " .. made .. " fabricadas", { size = Ui.S.xs, color = T.mut }),
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

function Screen.build(main: Frame, side: Frame)
	local g = App.g
	local live, partsN = 0, 0
	for _, u in g.units do
		if u.status ~= "vendido" then
			live += 1
		end
	end
	for _, p in g.parts do
		partsN += p.qty
	end
	local tabs, tab = Sheet.tabs("autos", {
		{ "veh", "Vehículos", live > 0 and live or nil },
		{ "parts", "Piezas", partsN > 0 and partsN or nil },
		{ "mats", "Materiales" },
		{ "designs", "Diseños y plantillas", #g.designs > 0 and #g.designs or nil },
	}, "veh")
	tabs.Parent = main
	if tab == "veh" then
		local typeOpts = { { "todos", "Todos" } }
		for _, k in Catalog.TYPE_ORDER do
			table.insert(typeOpts, { k, Catalog.TYPES[k] })
		end
		Ui.row({
			Sheet.search("veh", "Buscar por modelo o número de serie"),
			Sheet.filter("vSt", "Estado", { { "activos", "Sin vender" }, { "almacen", "En el almacén" }, { "salon", "En el salón" }, { "reservado", "Reservadas" }, { "mercado", "En el mercado" }, { "vendido", "Vendidas" }, { "todos", "Todas" } }, "activos"),
			Sheet.filter("vTy", "Tipo", typeOpts, "todos"),
			Sheet.filter("vSo", "Orden", { { "nuevo", "Más recientes" }, { "precio", "Precio" }, { "calidad", "Calidad" } }, "nuevo"),
		}, 10, { wrap = true }).Parent = main
		local st, ty, so = Sheet.value("vSt", "activos"), Sheet.value("vTy", "todos"), Sheet.value("vSo", "nuevo")
		local list = {}
		for _, u in g.units do
			local okSt = st == "todos" or (st == "activos" and u.status ~= "vendido") or u.status == st
			if okSt and (ty == "todos" or u.type == ty) and Sheet.matches("veh", u.name, u.serial) then
				table.insert(list, u)
			end
		end
		table.sort(list, function(a, b)
			if so == "precio" then
				return Rules.finalPrice(a) > Rules.finalPrice(b)
			elseif so == "calidad" then
				return a.quality > b.quality
			end
			if a.createdDay ~= b.createdDay then
				return a.createdDay > b.createdDay
			end
			return a.id > b.id
		end)
		if #list == 0 then
			Ui.empty("car", #g.units > 0 and "Ningún vehículo coincide con la búsqueda." or "Todavía no fabricaste vehículos. Creá una orden en Fábrica.").Parent = main
		end
		for i, u in list do
			if i > 80 then
				Ui.text("Mostrando 80 de " .. #list .. ". Usá la búsqueda o los filtros.", { size = Ui.S.xs, color = T.mut }).Parent = main
				break
			end
			unitRow(g, u).Parent = main
		end
	elseif tab == "parts" then
		Ui.row({ Sheet.search("parts", "Buscar pieza") }, 10, { wrap = true }).Parent = main
		local any = false
		for _, p in g.parts do
			local d = Catalog.part(p.cat, p.id)
			if d and Sheet.matches("parts", d.name, Catalog.catLabel(p.cat)) then
				any = true
				local need = d.need and ({ electrico = "solo eléctricos", combustion = "solo combustión", offroad = "solo SUV/pickup" })[d.need] or nil
				local recycle
				recycle = Ui.button("Reciclar 1", "q", function()
					App.openDialog("confirm", {
						title = "¿Reciclar 1 × " .. d.name .. "?",
						body = "Recuperás " .. math.max(1, Util.round(d.unit / 500)) .. " de acero" .. ((p.cat == "bateria" or p.cat == "motor") and " y 1 de electrónica" or "") .. ". No se puede deshacer.",
						okLabel = "Reciclar",
						onOk = function()
							App.request("recyclePart", { cat = p.cat, id = p.id })
						end,
					})
				end, { small = true, icon = "recycle", iconSize = 14 })
				Ui.card({
					Ui.ico("wrench", T.vi2, T.input, 32, { iconSize = 18 }),
					Ui.grow(Ui.col({
						Ui.row({ Ui.inline(d.name, { size = 15, weight = W.bold }), Ui.chip(d.rarity, RAR[d.rarity] or "cn") }, 6),
						Ui.text(Catalog.catLabel(p.cat) .. " · " .. d.desc .. (need and (" · " .. need) or ""), { size = Ui.S.xs, color = T.mut }),
						Ui.text("Instalarla en un diseño cubre su costo de desarrollo (" .. Util.money(d.proto) .. ") y consume 1 unidad.", { size = Ui.S.xs, color = T.mut }),
					}, 3)),
					Ui.inline("× " .. p.qty, { size = 15, weight = W.bold }),
					Ui.button("Instalar en el proyecto", "p", function()
						App.go("editor", { installPart = { cat = p.cat, id = p.id } })
					end, { small = true }),
					recycle,
				}, { dir = "H", v = "C", gap = 10, wrap = true }).Parent = main
			end
		end
		if not any then
			Ui.empty("wrench", "No tenés piezas sueltas. Podés comprarlas en el Mercado › Piezas.", Ui.button("Ir al mercado", "default", function()
				App.ui.tabs.mercado = "pieza"
				App.go("mercado")
			end, { small = true })).Parent = main
		end
	elseif tab == "mats" then
		local lines: { Instance? } = {}
		for i, m in Catalog.MATERIALS do
			local row = Ui.row({
				Ui.grow(Ui.text(m[2] .. " <font color=\"#A3AAB8\" size=\"11\">· " .. Util.money(m[3]) .. " c/u en el proveedor</font>", { size = 14 })),
				Ui.inline(Util.num(g.materials[m[1]] or 0), { size = 14, weight = W.bold }),
				Ui.button("Comprar 20", "q", function()
					App.screens.fabrica.askBuyMaterial(g, m[1], 20)
				end, { small = true }),
			}, 12, { Pad = { 8, 0 } })
			table.insert(lines, i < #Catalog.MATERIALS and Ui.underline(row) or row)
		end
		Ui.card(lines, { gap = 0, pad = { 4, 14 } }).Parent = main
		local d = g.derived
		Ui.row({ Ui.inline("Depósito de materiales", { size = Ui.S.xs, color = T.mut, width = 140 }), Ui.grow((Ui.bar(d.matsUsed / math.max(1, d.caps.mats) * 100))), Ui.inline(d.matsUsed .. "/" .. d.caps.mats, { size = Ui.S.xs, weight = W.bold }) }, 10).Parent = main
		Ui.button("Ver ofertas de materiales en el mercado", "default", function()
			App.ui.tabs.mercado = "material"
			App.go("mercado")
		end, { small = true }).Parent = main
	else
		Ui.row({
			Sheet.search("des", "Buscar diseño"),
			Ui.button("Nuevo proyecto", "p", function()
				App.go("editor", { new = true })
			end, { small = true, icon = "plus" }),
		}, 10, { wrap = true }).Parent = main
		local any = false
		for _, d in g.designs do
			if Sheet.matches("des", d.name) then
				any = true
				Screen.designRow(g, d).Parent = main
			end
		end
		if not any then
			Ui.empty("pen", "Sin diseños guardados.").Parent = main
		end
	end

	-- Columna lateral
	local d = g.derived
	Ui.card({
		Ui.lbl("Capacidad (regla única)"),
		Ui.row({ Ui.inline("Almacén", { size = Ui.S.xs, color = T.mut, width = 80 }), Ui.grow((Ui.bar(d.warehouseUsed / math.max(1, d.caps.warehouse) * 100, d.warehouseUsed >= d.caps.warehouse and T.re or nil))), Ui.inline(d.warehouseUsed .. "/" .. d.caps.warehouse, { size = Ui.S.xs, weight = W.bold }) }, 10),
		Ui.row({ Ui.inline("Salón", { size = Ui.S.xs, color = T.mut, width = 80 }), Ui.grow((Ui.bar(d.showroomUsed / math.max(1, d.caps.showroom) * 100, T.gr))), Ui.inline(d.showroomUsed .. "/" .. d.caps.showroom, { size = Ui.S.xs, weight = W.bold }) }, 10),
		Ui.text("El almacén cuenta las unidades terminadas <b>en el almacén</b>, <b>reservadas</b> y <b>publicadas en el mercado</b>, más las que se están fabricando. El salón cuenta solo las que están exhibidas. Las vendidas no ocupan lugar. Esta misma regla se usa en Fábrica, Ventas y Mercado.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.4 }),
	}, { gap = 8 }).Parent = side
	local rows: { Instance? } = { Ui.lbl("Resumen") }
	for _, s in { "almacen", "salon", "reservado", "mercado", "vendido" } do
		local n = 0
		for _, u in g.units do
			if u.status == s then
				n += 1
			end
		end
		if s == "vendido" then
			n = g.counters.unitsSold
		end
		table.insert(rows, Ui.between(Screen.STATUS_LABEL[s], tostring(n)))
	end
	Ui.card(rows, { gap = 6 }).Parent = side
	local _ = hex
end

return Screen
