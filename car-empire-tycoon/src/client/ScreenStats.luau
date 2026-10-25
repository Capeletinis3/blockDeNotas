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
		end, { height = 32 }))
	end
	return out
end

local function kpi(label: string, value: string, help: string, color: Color3?): Frame
	return (Ui.kv(label, value, { sub = help, color = color }))
end

function Screen.build(main: Frame, side: Frame)
	local g = App.g
	local f = Rules.finance(g, App.ui.statRange)
	Ui.grid({
		kpi("Ingresos por ventas", Util.money(f.revenue), "Suma de precios de venta."),
		kpi("Costo de lo vendido", Util.money(-f.cogs), "Costo registrado de los autos vendidos.", T.or_),
		kpi("Margen bruto", Util.money(f.margin), (f.revenue > 0 and (Util.round(f.margin / f.revenue * 100) .. " % de los ingresos. ") or "") .. "Ingresos − costo.", f.margin >= 0 and T.gr or T.re2),
		kpi("Resultado operativo", Util.money(f.opProfit), "Margen − salarios, promoción, mantenimiento y comisiones.", f.opProfit >= 0 and T.gr or T.re2),
		kpi("Autos vendidos", tostring(f.units), "Unidades del período."),
		kpi("Precio medio", f.units > 0 and Util.money(f.revenue / f.units) or "—", "Por unidad vendida."),
		kpi("Flujo de caja neto", Util.money(f.cash), "Todo lo que entró menos todo lo que salió.", f.cash >= 0 and T.gr or T.re2),
		kpi("Unidades producidas", tostring(f.produced), "Terminadas en el período."),
	}, App.isPhone() and 2 or 4, 92).Parent = main

	-- Gráfico por día (barras hechas con Frames).
	local maxV = 1
	for _, d in f.series do
		maxV = math.max(maxV, d.revenue, math.abs(d.cash))
	end
	local chart = Ui.new("Frame", { Name = "Grafico", Size = UDim2.new(1, 0, 0, 150), List = { dir = "H", gap = 3, v = "B" } })
	for _, d in f.series do
		local col = Ui.new("Frame", { Size = UDim2.new(1 / #f.series, -3, 1, 0), List = { dir = "H", gap = 1, v = "B" } }, {
			Ui.new("Frame", { Size = UDim2.new(0.5, 0, d.revenue / maxV, 0), BackgroundColor3 = T.vi, BackgroundTransparency = 0, Corner = 2 }),
			Ui.new("Frame", { Size = UDim2.new(0.5, 0, math.abs(d.cash) / maxV, 0), BackgroundColor3 = d.cash >= 0 and T.gr or T.re, BackgroundTransparency = 0, Corner = 2 }),
		})
		col.Parent = chart
	end
	Ui.card({
		Ui.row({ Ui.lbl("Por día de juego"), Ui.spacer(), Ui.inline("<font color=\"#7667FF\">■</font> ingresos  <font color=\"#42E58D\">■</font> caja neta (rojo si es negativa)", { size = Ui.S.xs, color = T.mut }) }, 8),
		chart,
		Ui.row({ Ui.inline("Día " .. (f.from + 1), { size = Ui.S.xs, color = T.mut }), Ui.spacer(), Ui.inline("Día " .. (g.time.day + 1), { size = Ui.S.xs, color = T.mut }) }, 8),
	}, { gap = 8 }).Parent = main

	-- Ventas por modelo (del historial con detalle que se conserva).
	local by: { [string]: any } = {}
	local order = {}
	for _, s in g.sales do
		if s.day >= f.from then
			if not by[s.name] then
				by[s.name] = { n = 0, rev = 0, mg = 0 }
				table.insert(order, s.name)
			end
			by[s.name].n += 1
			by[s.name].rev += s.price
			by[s.name].mg += s.margin
		end
	end
	table.sort(order, function(a, b)
		return by[a].rev > by[b].rev
	end)
	local modelRows: { Instance? } = { Ui.lbl("Ventas por modelo") }
	for _, name in order do
		local v = by[name]
		table.insert(modelRows, Ui.line(name .. "  <font color=\"#7D8493\">" .. v.n .. " u.</font>", Util.money(v.rev) .. " · margen " .. Util.money(v.mg), { color = v.mg >= 0 and T.gr or T.re2 }))
	end
	if #order == 0 then
		table.insert(modelRows, Ui.text("Sin ventas en el período.", { size = Ui.S.sm, color = T.mut }))
	end
	Ui.card(modelRows, { gap = 0 }).Parent = main

	local gastos: { Instance? } = { Ui.lbl("Gastos e inversiones del período") }
	for _, r in {
		{ "Fabricación (al empezar cada unidad)", f.manufacturing },
		{ "Salarios", f.opex.salarios },
		{ "Promoción", f.opex.promocion },
		{ "Mantenimiento y reparaciones", f.opex.mantenimiento },
		{ "Comisiones de venta", f.opex.comisiones },
		{ "Desarrollo de diseños", f.invest.desarrollo },
		{ "Investigación", f.invest.investigacion },
		{ "Mejoras y sede", f.invest.mejoras },
		{ "Contrataciones", f.invest.contratacion },
		{ "Compras (materiales y mercado)", f.purchases },
		{ "Impuestos", f.taxes },
	} do
		table.insert(gastos, Ui.line(r[1], Util.money(-r[2]), { leftColor = T.mut, color = r[2] > 0 and T.or_ or T.mut }))
	end
	Ui.card(gastos, { gap = 0 }).Parent = side
	Ui.card({
		Ui.lbl("Movimientos de caja"),
		Ui.line("Entradas", Util.money(f.inflow), { leftColor = T.mut, color = T.gr }),
		Ui.line("Salidas", Util.money(f.outflow), { leftColor = T.mut, color = T.or_ }),
		Ui.line("Neto", Util.money(f.cash), { color = f.cash >= 0 and T.gr or T.re2 }),
		Ui.text("Estas cifras salen de agregados diarios que se guardan aparte del historial recortado, así que el período siempre está completo (hasta 60 días).", { size = Ui.S.xs, color = T.mut }),
	}, { gap = 2 }).Parent = side
end

return Screen
