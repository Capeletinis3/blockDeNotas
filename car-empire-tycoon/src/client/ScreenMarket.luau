--!strict
--[[
	Mercado y competidores: para cada tipo de vehículo que existe en el año actual, la demanda total
	(autos por minuto), cuánto se lleva tu empresa y cuánto cada marca rival ficticia, con su modelo,
	segmento, precio y atractivo. Es el mismo cálculo que reparte las ventas en el servidor
	(Rules.market), así que lo que se ve acá explica por qué un modelo vende rápido o lento.
	No es un mercado de compraventa: no hay subastas ni comercio entre jugadores.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local Rules = require(Shared.Rules)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local Sheet = require(script.Parent.ScreenSheet)
local T = Ui.T
local W = Ui.W
local hex = Ui.hex

local Screen = {
	title = "Mercado y competidores",
	icon = "globe",
}

function Screen.head(g: any): { Instance }
	return { Ui.chip("Año " .. Rules.year(g), "cb"), Ui.chip("Atractivo esperado " .. Util.round(Rules.eraBaseline(Rules.yearFrac(g))), "cn") }
end

-- Reparto de un tipo: { demand, mine = { lotes con su ritmo }, myRate, rivals = { r, rate, share }, outsideRate }
function Screen.breakdown(g: any, typeId: string): any
	local m = Rules.market(g, typeId)
	local out = { demand = m.demand, mine = {}, myRate = 0, rivals = {}, outsideRate = 0 }
	if m.demand <= 0 then
		return out
	end
	for _, l in g.lots do
		local w = m.lots[l.id]
		if w then
			local rate = m.demand * w / m.total
			out.myRate += rate
			table.insert(out.mine, { lot = l, rate = rate, share = w / m.total })
		end
	end
	for _, r in m.rivals do
		table.insert(out.rivals, { r = r, rate = m.demand * r.weight / m.total, share = r.weight / m.total })
	end
	table.sort(out.rivals, function(a: any, b: any): boolean
		return a.rate > b.rate
	end)
	out.outsideRate = m.demand * m.outside / m.total
	out.myShare = out.myRate / m.demand
	return out
end

local function shareBar(parts: { any }): Frame
	local f = Ui.new("Frame", { Name = "Reparto", Size = UDim2.new(1, 0, 0, 10), BackgroundColor3 = T.p3, BackgroundTransparency = 0, Corner = 5, ClipsDescendants = true })
	local x = 0
	for _, p in parts do
		if p[1] > 0 then
			Ui.new("Frame", { Name = "Parte", BackgroundColor3 = p[2], BackgroundTransparency = 0, Position = UDim2.fromScale(x, 0), Size = UDim2.fromScale(p[1], 1), Parent = f })
			x += p[1]
		end
	end
	return f
end

local function typeCard(typeId: string, b: any): Frame
	local myPct = Util.num((b.myShare or 0) * 100, 1)
	local parts = { { b.myShare or 0, T.vi } }
	for _, rv in b.rivals do
		table.insert(parts, { rv.share, hex(rv.r.rival.color) })
	end
	local rows: { Instance? } = {
		Ui.row({
			Ui.grow(Ui.text(Catalog.TYPES[typeId], { size = 16, weight = W.bold })),
			Ui.chip(Util.num(b.demand, 1) .. " autos/min", "cn"),
			Ui.chip("Tu cuota " .. myPct .. " %", (b.myShare or 0) > 0 and "cv" or "cn"),
		}, 8, { wrap = true }),
		shareBar(parts),
	}
	for _, x in b.mine do
		table.insert(rows, Ui.between("● " .. x.lot.design.name .. " · " .. Util.money(x.lot.price) .. " · atractivo " .. Util.round(x.lot.appeal), Util.num(x.rate, 1) .. "/min · " .. Util.num(x.share * 100, 1) .. " %", { size = Ui.S.xs, color = T.vi2, leftColor = T.vi2 }))
	end
	if #b.mine == 0 then
		table.insert(rows, Ui.text("No tenés modelos de este tipo a la venta.", { size = Ui.S.xs, color = T.mut }))
	end
	for _, rv in b.rivals do
		local r = rv.r
		table.insert(rows, Ui.between(r.rival.name .. " " .. r.name .. " · " .. r.segment .. " · " .. Util.money(r.price) .. " · atractivo " .. Util.round(r.appeal), Util.num(rv.rate, 1) .. "/min · " .. Util.num(rv.share * 100, 1) .. " %", { size = Ui.S.xs, leftColor = hex(r.rival.color) }))
	end
	table.insert(rows, Ui.between("Otras marcas chicas", Util.num(b.outsideRate, 1) .. "/min", { size = Ui.S.xs, color = T.mut, leftColor = T.mut }))
	return Ui.card(rows, { gap = 6, name = "Tipo_" .. typeId })
end

function Screen.build(main: Frame, side: Frame)
	local g = App.g
	local tabs, tab = Sheet.tabs("mercado", { { "tipos", "Demanda por tipo" }, { "rivales", "Marcas rivales" } }, "tipos")
	tabs.Parent = main
	if tab == "tipos" then
		local shown = 0
		for _, typeId in Catalog.TYPE_ORDER do
			local b = Screen.breakdown(g, typeId)
			if b.demand > 0 then
				typeCard(typeId, b).Parent = main
				shown += 1
			end
		end
		local soon = {}
		for _, typeId in Catalog.TYPE_ORDER do
			if Rules.demand(g, typeId) <= 0 then
				table.insert(soon, Catalog.TYPES[typeId])
			end
		end
		if #soon > 0 then
			Ui.note("b", "Todavía no hay demanda de: " .. table.concat(soon, ", ") .. ". Aparecen con los años.").Parent = main
		end
	else
		local yf = Rules.yearFrac(g)
		for _, r in Catalog.RIVALS do
			local models: { Instance? } = {}
			local total = 0
			for _, typeId in Catalog.TYPE_ORDER do
				for _, o in Rules.rivalOffers(typeId, yf) do
					if o.rival.id == r.id then
						local b = Screen.breakdown(g, typeId)
						local rate = 0
						for _, rv in b.rivals do
							if rv.r.rival.id == r.id then
								rate = rv.rate
							end
						end
						total += rate
						table.insert(models, Ui.between(o.name .. " · " .. Catalog.TYPES[typeId] .. " · " .. o.segment .. " · " .. Util.money(o.price), Util.num(rate, 1) .. "/min", { size = Ui.S.xs }))
					end
				end
			end
			local coming = {}
			for typeId, since in r.types do
				if since > yf then
					table.insert(coming, Catalog.TYPES[typeId] .. " (" .. since .. ")")
				end
			end
			Ui.card({
				Ui.row({
					Ui.new("Frame", { Name = "Color", BackgroundColor3 = hex(r.color), BackgroundTransparency = 0, Size = UDim2.fromOffset(14, 14), Corner = 7 }),
					Ui.grow(Ui.text(r.name, { size = 16, weight = W.bold })),
					Ui.chip(Util.num(total, 1) .. " ventas/min", total > 0 and "cg" or "cn"),
				}, 10),
				#models > 0 and Ui.col(models, 4) or Ui.text("Sin modelos a la venta este año.", { size = Ui.S.xs, color = T.mut }),
				#coming > 0 and Ui.text("Próximamente: " .. table.concat(coming, ", "), { size = Ui.S.xs, color = T.mut }) or nil,
			}, { gap = 8, name = "Rival_" .. r.id }).Parent = main
		end
		local mine = 0
		for _, typeId in Catalog.TYPE_ORDER do
			mine += Screen.breakdown(g, typeId).myRate
		end
		Ui.card({
			Ui.row({
				Ui.logo(g.company, 22),
				Ui.grow(Ui.text(g.company.name .. " (vos)", { size = 16, weight = W.bold })),
				Ui.chip(Util.num(mine, 1) .. " ventas/min", "cv"),
			}, 10),
		}, { gap = 8, name = "MiEmpresa" }).Parent = main
	end

	-- Columna lateral
	Ui.card({
		Ui.lbl("Cómo se reparte la demanda"),
		Ui.text("Cada tipo tiene una demanda total por minuto que cambia con los años. Se reparte entre tus modelos, las marcas rivales y el resto del mercado según el <b>atractivo</b> de cada auto frente al que se espera en la época (cada 12 puntos más, casi el triple de peso), el <b>precio</b> respecto del de referencia, tu <b>reputación</b> y el <b>alcance</b> de tu sede.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.45 }),
	}, { gap = 4, name = "Reparto" }).Parent = side
	Ui.card({
		Ui.lbl("Tu empresa"),
		Ui.between("Alcance de la sede", "×" .. Util.num(Rules.sede(g).reach, 1)),
		Ui.between("Reputación", Util.num(g.reputation, 1) .. " / 5"),
		Ui.between("Multiplicador comercial", "×" .. Util.num(Rules.playerMult(g), 2)),
		g.promo and Ui.between("Campaña", "+" .. Util.round(Catalog.ECON.campaignBoost * 100) .. " %", { color = T.gr }) or nil,
	}, { gap = 6, name = "TuEmpresa" }).Parent = side
end

return Screen
