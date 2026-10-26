--!strict
-- Estadísticas y finanzas (SCREENS.estadisticas de la V3): 6, 12 o 24 meses de juego a partir de los
-- agregados mensuales (la misma fuente que el HUD y Ventas), gráfico por mes, resultados por modelo y
-- gastos. Base de caja: la fabricación se descuenta al pagarse; el costo de lo vendido es informativo.

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
	if App.ui.statRange ~= 6 and App.ui.statRange ~= 12 and App.ui.statRange ~= 24 then
		App.ui.statRange = 12
	end
	for _, d in { 6, 12, 24 } do
		table.insert(out, Ui.opt(d .. " meses", App.ui.statRange == d, function()
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
	local range = (App.ui.statRange == 6 or App.ui.statRange == 24) and App.ui.statRange or 12
	local f = Rules.finance(g, range)
	if f.demo then
		Ui.note("y", "Este período incluye ventas generadas por la demostración (marcadas como tales en el historial).").Parent = main
	end
	Ui.grid({
		kpi("Ingresos por ventas", Util.money(f.revenue), "Suma de precios de venta.", T.gr),
		kpi("Fabricación pagada", Util.money(-f.manufacturing), "Lo que costaron las unidades fabricadas en el período (se pagan al terminarse).", T.or_),
		kpi("Margen de lo vendido", Util.money(f.margin), (f.revenue > 0 and (Util.round(f.margin / f.revenue * 100) .. " % de los ingresos. ") or "") .. "Precio − costo de cada auto vendido (informativo, no se descuenta dos veces).", f.margin >= 0 and T.gr or T.re2),
		kpi("Resultado operativo", Util.money(f.opProfit), "Ingresos − fabricación pagada − salarios − campaña.", f.opProfit >= 0 and T.gr or T.re2),
		kpi("Autos vendidos", Util.num(f.units), "Unidades."),
		kpi("Autos fabricados", Util.num(f.produced), "Unidades terminadas."),
		kpi("Precio medio", f.units > 0 and Util.money(f.revenue / f.units) or "—", "Por unidad vendida."),
		kpi("Flujo de caja neto", Util.money(f.cash), "Todo el dinero que entró menos todo el que salió.", f.cash >= 0 and T.gr or T.re2),
	}, App.isPhone() and 2 or 4).Parent = main

	-- Gráfico por día (barras hechas con Frames).
	local maxV = 1
	for _, d in f.series do
		maxV = math.max(maxV, d.revenue, math.abs(d.cash))
	end
	local chart = Ui.new("Frame", { Name = "Grafico", Size = UDim2.new(1, 0, 0, 150), List = { dir = "H", gap = 3, v = "B" } })
	for _, d in f.series do
		local col = Ui.new("Frame", { Name = "Mes_" .. d.day, Size = UDim2.new(1 / #f.series, -3, 1, 0), List = { dir = "H", gap = 1, v = "B" } }, {
			Ui.new("Frame", { Size = UDim2.new(0.5, 0, d.revenue / maxV, 0), BackgroundColor3 = T.vi, BackgroundTransparency = 0, Corner = 2 }),
			Ui.new("Frame", { Size = UDim2.new(0.5, -1, math.abs(d.cash) / maxV, 0), BackgroundColor3 = d.cash >= 0 and T.gr or T.re, BackgroundTransparency = 0, Corner = 2 }),
		})
		col.Parent = chart
	end
	Ui.card({
		Ui.row({ Ui.grow(Ui.lbl("Por mes")), legend(T.vi, "Ingresos por ventas"), legend(T.gr, "Caja neta (rojo si es negativa)") }, 10, { wrap = App.isPhone() }),
		chart,
		Ui.row({ Ui.inline(Util.gameDate(math.max(0, f.from)), { size = Ui.S.xs, color = T.mut }), Ui.spacer(), Ui.inline(Util.gameDate(g.time.day) .. " (actual)", { size = Ui.S.xs, color = T.mut }) }, 8),
	}, { gap = 8, name = "PorMes" }).Parent = main

	-- Resultados por modelo: todos los lotes (activos e historial), de por vida.
	local by: { [string]: any } = {}
	local order = {}
	for _, list in { g.lots, g.lotHistory } do
		for _, l in list do
			local key = l.design.lineage or l.designId
			if not by[key] then
				by[key] = { name = l.design.name, n = 0, rev = 0, cost = 0, disc = 0 }
				table.insert(order, key)
			end
			local v = by[key]
			v.n += l.sold
			v.rev += l.revenue
			v.cost += l.costSpent
			v.disc += l.discarded or 0
		end
	end
	table.sort(order, function(a, b)
		return by[a].rev > by[b].rev
	end)
	local modelRows: { Instance? } = { Ui.lbl("Resultados por modelo (todos sus lotes)") }
	for i, key in order do
		local v = by[key]
		local res = v.rev - v.cost
		local row = Ui.row({
			Ui.grow(Ui.text(v.name .. (v.disc > 0 and (" <font color=\"#FF8A91\" size=\"11\">· " .. Util.num(v.disc) .. " descartados</font>") or ""), { size = Ui.S.line })),
			Ui.inline(Util.num(v.n) .. " u.", { size = Ui.S.sm, color = T.mut }),
			Ui.inline(Util.money(v.rev), { size = Ui.S.line, weight = W.bold, width = 120, align = "R" }),
			Ui.text("resultado " .. Util.money(res), { size = Ui.S.line, weight = W.bold, color = res >= 0 and T.gr or T.re2, width = 150, align = "R" }),
		}, 12, { Pad = { 8, 0 }, wrap = App.isPhone() })
		table.insert(modelRows, i < #order and Ui.underline(row) or row)
	end
	if #order == 0 then
		table.insert(modelRows, Ui.text("Todavía no se fabricó ningún lote.", { size = Ui.S.sm, color = T.mut }))
	end
	Ui.card(modelRows, { gap = 4, name = "PorModelo" }).Parent = main

	local gastos: { Instance? } = { Ui.lbl("Gastos del período") }
	for _, r in {
		{ "Fabricación (al terminar cada unidad)", f.manufacturing },
		{ "Salarios", f.opex.salarios },
		{ "Campaña publicitaria", f.opex.promocion },
		{ "Desarrollo de diseños", f.invest.desarrollo },
		{ "Investigación", f.invest.investigacion },
		{ "Mejoras y sede", f.invest.mejoras },
		{ "Contrataciones", f.invest.contratacion },
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
				local t = Ui.inline(Util.gameDate(l.day) .. " · " .. l.note, { size = Ui.S.xs, color = T.mut, truncate = true })
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
