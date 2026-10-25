--!strict
-- Mis autos e inventario (SCREENS.autos de la V3): vehículos, diseños y materiales.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local DesignCalc = require(Shared.DesignCalc)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local Sheet = require(script.Parent.ScreenSheet)
local T = Ui.T
local W = Ui.W

local Screen = {
	title = "Mis autos e inventario",
	symbol = "🚗",
	color = Color3.fromHex("#8DB8FF"),
	bg = Color3.fromHex("#14233D"),
}

Screen.STATUS_LABEL = { almacen = "En el almacén", salon = "En el salón", reservado = "Reservada", vendido = "Vendida" }
Screen.STATUS_CHIP = { almacen = "cb", salon = "cg", reservado = "cy", vendido = "cn" }

function Screen.head(g: any): { Instance }
	local caps = g.derived.caps
	return {
		Ui.chip("Almacén " .. g.derived.warehouseUsed .. "/" .. caps.warehouse, g.derived.warehouseUsed >= caps.warehouse and "cr" or "cb"),
		Ui.chip("Salón " .. g.derived.showroomUsed .. "/" .. caps.showroom, "cg"),
	}
end

local function unitActions(g: any, u: any): { Instance? }
	local caps = g.derived.caps
	local out: { Instance? } = {}
	if u.status == "almacen" then
		local full = g.derived.showroomUsed >= caps.showroom
		table.insert(out, Ui.button("Enviar al salón", "p", function()
			App.request("sendToShowroom", { unitId = u.id })
		end, { small = true, disabled = full, why = "Salón lleno (" .. g.derived.showroomUsed .. "/" .. caps.showroom .. ")" }))
	elseif u.status == "salon" then
		local full = g.derived.warehouseUsed + g.derived.inProgress >= caps.warehouse
		table.insert(out, Ui.button("Retirar al almacén", "default", function()
			App.request("returnToWarehouse", { unitId = u.id })
		end, { small = true, disabled = full, why = "Almacén lleno" }))
		table.insert(out, Ui.button("Ver clientes", "default", function()
			App.go("ventas")
		end, { small = true }))
	elseif u.status == "vendido" then
		local sale = nil
		for _, s in g.sales do
			if s.unitId == u.id then
				sale = s
			end
		end
		table.insert(out, Ui.text("Vendida el día " .. ((u.soldDay or 0) + 1) .. " por " .. Util.money(u.soldPrice or 0) .. (sale and (" · margen " .. Util.money(sale.margin) .. " · " .. sale.buyer) or ""), { size = Ui.S.xs, color = T.mut }))
	end
	return out
end
Screen.unitActions = unitActions

local function unitRow(g: any, u: any): Frame
	local margin = u.price - u.cost
	return Ui.card({
		Ui.row({
			Ui.paintChip(u.spec, 44, 28),
			Ui.grow(Ui.col({
				Ui.text(u.name .. "  <font color=\"#7D8493\">v" .. tostring(u.designVersion or 1) .. " · " .. u.serial .. "</font>", { size = 15, weight = W.bold }),
				Ui.text(Catalog.TYPES[u.type] .. " · calidad " .. u.quality .. " · " .. u.stats.hp .. " hp · fabricada el día " .. (u.createdDay + 1), { size = Ui.S.xs, color = T.mut }),
			}, 2)),
			Ui.chip(Screen.STATUS_LABEL[u.status] or u.status, Screen.STATUS_CHIP[u.status]),
		}, 10),
		Ui.row({
			Ui.inline("Costo " .. Util.money(u.cost), { size = Ui.S.sm, color = T.mut }),
			Ui.inline("Precio " .. Util.money(u.price), { size = Ui.S.sm }),
			Ui.inline("Margen " .. Util.money(margin), { size = Ui.S.sm, color = margin >= 0 and T.gr or T.re2, weight = W.bold }),
		}, 16),
		Ui.row(unitActions(g, u), 6, { wrap = true }),
	}, { gap = 8 })
end

local function designRow(g: any, d: any): Frame
	local c = DesignCalc.computeDesign(g, d)
	local made = 0
	for _, u in g.units do
		if u.designId == d.id then
			made += 1
		end
	end
	local base = Catalog.base(d.baseId)
	return Ui.card({
		Ui.row({
			Ui.paintChip(d, 44, 28),
			Ui.grow(Ui.col({
				Ui.text(d.name .. "  <font color=\"#C4BDFF\">v" .. d.version .. "</font>", { size = 15, weight = W.bold }),
				Ui.text(base.name .. " · " .. Util.money(c.unitCost) .. " por unidad · precio recomendado " .. Util.money(c.price) .. " · " .. made .. " fabricadas", { size = Ui.S.xs, color = T.mut }),
			}, 2)),
			Ui.button("Fabricar", "p", function()
				App.openDialog("order", { designId = d.id })
			end, { small = true }),
			Ui.button("Editar", "default", function()
				App.go("editor", { designId = d.id })
			end, { small = true }),
		}, 8),
	}, { gap = 6 })
end

function Screen.build(main: Frame, side: Frame)
	local g = App.g
	local active = 0
	for _, u in g.units do
		if u.status ~= "vendido" then
			active += 1
		end
	end
	local tabs, tab = Sheet.tabs("autos", { { "veh", "Vehículos", active }, { "designs", "Diseños", #g.designs }, { "mats", "Materiales" } }, "veh")
	tabs.Parent = main
	if tab == "veh" then
		local list = {}
		for i = #g.units, 1, -1 do
			local u = g.units[i]
			if u.status ~= "vendido" then
				table.insert(list, u)
			end
		end
		local sold = {}
		for i = #g.units, 1, -1 do
			if g.units[i].status == "vendido" then
				table.insert(sold, g.units[i])
			end
		end
		if #list == 0 then
			Ui.note("b", #g.units == 0 and "Todavía no fabricaste unidades. Creá una orden en la Fábrica." or "No hay unidades sin vender.", Ui.button("Ir a la fábrica", "default", function()
				App.go("fabrica")
			end, { small = true })).Parent = main
		end
		for _, u in list do
			unitRow(g, u).Parent = main
		end
		if #sold > 0 then
			Ui.lbl("Vendidas recientemente").Parent = main
			for _, u in sold do
				unitRow(g, u).Parent = main
			end
		end
	elseif tab == "designs" then
		Ui.row({ Ui.button("+ Nuevo proyecto", "p", function()
			App.go("editor", { new = true })
		end, { small = true }) }).Parent = main
		if #g.designs == 0 then
			Ui.note("b", "Sin diseños guardados. Abrí el escritorio de diseño.").Parent = main
		end
		for _, d in g.designs do
			designRow(g, d).Parent = main
		end
	else
		local rows: { Instance? } = {}
		for _, m in Catalog.MATERIALS do
			table.insert(rows, Ui.line(m[2] .. "  <font color=\"#7D8493\">· " .. Util.money(m[3]) .. " c/u en el proveedor</font>", Util.num(g.materials[m[1]] or 0)))
		end
		Ui.card(rows, { gap = 0, pad = { 4, 14 } }).Parent = main
		Ui.row({ Ui.button("Comprar en la fábrica", "default", function()
			App.go("fabrica")
		end, { small = true }) }).Parent = main
	end

	-- Lateral
	local caps = g.derived.caps
	local wh = Ui.bar(g.derived.warehouseUsed / caps.warehouse * 100, g.derived.warehouseUsed >= caps.warehouse and T.re or nil)
	local sh = Ui.bar(g.derived.showroomUsed / caps.showroom * 100, T.gr)
	Ui.card({
		Ui.lbl("Capacidad (regla única)"),
		Ui.row({ Ui.inline("Almacén", { size = Ui.S.xs, color = T.mut, width = 70 }), Ui.grow(wh, { Size = UDim2.new(0, 0, 0, 7) }), Ui.inline(g.derived.warehouseUsed .. "/" .. caps.warehouse, { size = Ui.S.xs, weight = W.bold }) }, 8),
		Ui.row({ Ui.inline("Salón", { size = Ui.S.xs, color = T.mut }), Ui.grow(sh, { Size = UDim2.new(0, 0, 0, 7) }), Ui.inline(g.derived.showroomUsed .. "/" .. caps.showroom, { size = Ui.S.xs, weight = W.bold }) }, 8),
		Ui.text("El almacén cuenta las unidades terminadas en el almacén más las que se están fabricando. El salón cuenta solo las exhibidas. Las vendidas no ocupan lugar.", { size = Ui.S.xs, color = T.mut }),
	}, { gap = 8 }).Parent = side
	local summary: { Instance? } = { Ui.lbl("Resumen") }
	for _, st in { "almacen", "salon", "vendido" } do
		local n = 0
		for _, u in g.units do
			if u.status == st then
				n += 1
			end
		end
		table.insert(summary, Ui.line(Screen.STATUS_LABEL[st], tostring(n), { leftColor = T.mut }))
	end
	table.insert(summary, Ui.line("Ventas totales", tostring(g.counters.unitsSold), { leftColor = T.mut }))
	Ui.card(summary, { gap = 0 }).Parent = side
end

return Screen
