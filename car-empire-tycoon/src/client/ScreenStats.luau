--!strict
-- Estadísticas y finanzas (SCREENS.estadisticas de la V3): 7, 14 o 30 días a partir de los agregados
-- diarios (la misma fuente que el HUD y Ventas), gráfico por día, ventas por modelo y gastos.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Util = require(Shared.Util)
local Rules = require(Shared.Rules)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local T = Ui.T
local W = Ui.W

local Screen = {
	title = "Estadísticas y finanzas",
	icon = "chart",
	color = Color3.fromHex("#42E58D"),
	bg = Color3.fromHex("#13301F"),
}

function Screen.head(_g: any): { Instance }
	local out = {}
	for _, d in { 7, 14, 30 } do
		table.insert(out, Ui.opt(d .. " días", App.ui.statRange == d, function()
			App.ui.statRange = d
			App.forceRender()
		end, { height = 34, name = "Periodo_" .. d }))
	end
	return out
end

local function kpi(label: string, value: string, help: string, color: Color3?): Frame
	return (Ui.kv(label, value, { sub = help, color = color }))
end

local function legend(color: Color3, text: string): Frame
	return Ui.row({
		Ui.new("Frame", { Size = UDim2.fromOffset(10, 10), BackgroundColor3 = color, BackgroundTransparency = 0, Corner = 2 }),
		Ui.inline(text, { size = Ui.S.xs }),
	}, 6, { Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY })
end

function Screen.build(main: Frame, side: Frame)
	local g = App.g
	local f = Rules.finance(g, App.ui.statRange)
	if f.demo then
		Ui.note("y", "Este período incluye ventas generadas por la demostración (marcadas como tales en el historial).").Parent = main
	end
	Ui.grid({
		kpi("Ingresos por ventas", Util.money(f.revenue), "Suma de precios de venta. Más es mejor."),
		kpi("Costo de lo vendido", Util.money(-f.cogs), "Costo de fabricación de los autos vendidos.", T.or_),
		kpi("Margen bruto", Util.money(f.margin), (f.revenue > 0 and (Util.round(f.margin / f.revenue * 100) .. "% de los ingresos. ") or "") .. "Ingresos − costo de lo vendido.", f.margin >= 0 and T.gr or T.re2),
		kpi("Resultado operativo", Util.money(f.opProfit), "Margen − comisiones − salarios − promoción − mantenimiento.", f.opProfit >= 0 and T.gr or T.re2),
		kpi("Autos vendidos", tostring(f.units), "Unidades."),
		kpi("Precio medio", f.units > 0 and Util.money(f.revenue / f.units) or "—", "Por unidad vendida."),
		kpi("Flujo de caja neto", Util.money(f.cash), "Todo el dinero que entró menos todo el que salió.", f.cash >= 0 and T.gr or T.re2),
		kpi("Cuota de mercado est.", Util.num(f.share, 1) .. "%", "Estimación simulada. Más es mejor."),
	}, App.isPhone() and 2 or 4).Parent = main

	-- Gráfico por día (barras hechas con Frames).
	local maxV = 1
	for _, d in f.series do
		maxV = math.max(maxV, d.revenue, math.abs(d.cash))
	end
	local chart = Ui.new("Frame", { Name = "Grafico", Size = UDim2.new(1, 0, 0, 150), List = { dir = "H", gap = 3, v = "B" } })
	for _, d in f.series do
		local col = Ui.new("Frame", { Name = "Dia_" .. (d.day + 1), Size = UDim2.new(1 / #f.series, -3, 1, 0), List = { dir = "H", gap = 1, v = "B" } }, {
			Ui.new("Frame", { Size = UDim2.new(0.5, 0, d.revenue / maxV, 0), BackgroundColor3 = T.vi, BackgroundTransparency = 0, Corner = 2 }),
			Ui.new("Frame", { Size = UDim2.new(0.5, -1, math.abs(d.cash) / maxV, 0), BackgroundColor3 = d.cash >= 0 and T.gr or T.re, BackgroundTransparency = 0, Corner = 2 }),
		})
		col.Parent = chart
	end
	Ui.card({
		Ui.row({ Ui.grow(Ui.lbl("Por día de juego")), legend(T.vi, "Ingresos por ventas"), legend(T.gr, "Caja neta (rojo si es negativa)") }, 10, { wrap = App.isPhone() }),
		chart,
		Ui.row({ Ui.inline("Día " .. (f.from + 1), { size = Ui.S.xs, color = T.mut }), Ui.spacer(), Ui.inline("Día " .. (g.time.day + 1) .. " (hoy)", { size = Ui.S.xs, color = T.mut }) }, 8),
	}, { gap = 8, name = "PorDia" }).Parent = main

	-- Ventas por modelo (del historial con detalle que se conserva).
	local by: { [string]: any } = {}
	local order = {}
	for _, sale in g.sales do
		if sale.day >= f.from then
			if not by[sale.name] then
				by[sale.name] = { n = 0, rev = 0, mg = 0 }
				table.insert(order, sale.name)
			end
			by[sale.name].n += 1
			by[sale.name].rev += sale.price
			by[sale.name].mg += sale.margin
		end
	end
	table.sort(order, function(a, b)
		return by[a].rev > by[b].rev
	end)
	local modelRows: { Instance? } = { Ui.lbl("Ventas por modelo") }
	for i, name in order do
		local v = by[name]
		local row = Ui.row({
			Ui.grow(Ui.text(name, { size = Ui.S.line })),
			Ui.inline(v.n .. " u.", { size = Ui.S.sm, color = T.mut }),
			Ui.inline(Util.money(v.rev), { size = Ui.S.line, weight = W.bold, width = 120, align = "R" }),
			Ui.text("margen medio " .. Util.money(v.mg / v.n), { size = Ui.S.line, weight = W.bold, color = v.mg >= 0 and T.gr or T.re2, width = 130, align = "R" }),
		}, 12, { Pad = { 8, 0 } })
		table.insert(modelRows, i < #order and Ui.underline(row) or row)
	end
	if #order == 0 then
		table.insert(modelRows, Ui.text("Sin ventas en el período.", { size = Ui.S.sm, color = T.mut }))
	end
	Ui.card(modelRows, { gap = 4, name = "PorModelo" }).Parent = main

	local gastos: { Instance? } = { Ui.lbl("Gastos del período") }
	for _, r in {
		{ "Fabricación (al empezar cada unidad)", f.manufacturing },
		{ "Salarios", f.opex.salarios },
		{ "Promoción", f.opex.promocion },
		{ "Mantenimiento", f.opex.mantenimiento },
		{ "Comisiones de venta", f.fees },
		{ "Desarrollo de diseños", f.invest.desarrollo },
		{ "Investigación", f.invest.investigacion },
		{ "Mejoras y sede", f.invest.mejoras },
		{ "Contrataciones", f.invest.contratacion },
		{ "Compras (mercado y materiales)", f.purchases },
		{ "Impuestos de compras", f.taxes },
	} do
		table.insert(gastos, Ui.between(r[1], Util.money(-r[2]), { color = r[2] > 0 and T.or_ or T.tx }))
	end
	Ui.card(gastos, { gap = 4, name = "Gastos" }).Parent = side

	local moves: { Instance? } = { Ui.lbl("Últimos movimientos") }
	local list = {}
	for _, l in g.ledger do
		if l.day >= f.from then
			table.insert(list, l)
		end
	end
	for i = #list, math.max(1, #list - 24), -1 do
		local l = list[i]
		table.insert(moves, Ui.row({
			Ui.grow((function()
				local t = Ui.inline("Día " .. (l.day + 1) .. " · " .. l.note, { size = Ui.S.xs, color = T.mut, truncate = true })
				t.Size = UDim2.new(1, 0, 0, 0)
				t.AutomaticSize = Enum.AutomaticSize.Y
				return t
			end)()),
			Ui.inline(Util.money(l.amount), { size = Ui.S.xs, weight = W.bold, color = l.amount >= 0 and T.gr or T.or_ }),
		}, 8))
	end
	if #list == 0 then
		table.insert(moves, Ui.text("Sin movimientos.", { size = Ui.S.sm, color = T.mut }))
	end
	Ui.card(moves, { gap = 4, name = "Movimientos" }).Parent = side
end

return Screen
