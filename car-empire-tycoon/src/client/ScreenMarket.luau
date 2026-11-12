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
local DesignCalc = require(Shared.DesignCalc)

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

local function typeCard(g: any, typeId: string, b: any): Frame
	local myPct = Util.num((b.myShare or 0) * 100, 1)
	local parts = { { b.myShare or 0, T.vi } }
	local rivalShare = 0
	for _, rv in b.rivals do
		table.insert(parts, { rv.share, hex(rv.r.rival.color) })
		rivalShare += rv.share
	end
	-- Cuota ACTUAL estimada (ofertas vigentes) frente a la HISTÓRICA (promedio mensual guardado en la partida).
	local sum = Rules.shareSummary(g, typeId)
	local yf = Rules.yearFrac(g)
	local before = Rules.baseDemand(typeId, yf - 1) * Rules.typeMarketFactor(g, typeId, yf - 1)
	local change = before > 0 and (b.demand / before - 1) * 100 or nil
	local rows: { Instance? } = {
		Ui.row({
			Ui.grow(Ui.text(Catalog.TYPES[typeId], { size = 16, weight = W.bold })),
			Ui.chip(Util.num(b.demand, 1) .. " autos/min", "cn"),
			Ui.chip("Cuota actual estimada " .. myPct .. " %", (b.myShare or 0) > 0 and "cv" or "cn", { name = "CuotaActual" }),
			Ui.chip("Histórica " .. Util.num(sum.historical * 100, 1) .. " %", "cn", { name = "CuotaHistorica" }),
		}, 8, { wrap = true }),
		shareBar(parts),
		Ui.text("Rivales " .. Util.num(rivalShare * 100, 1) .. " % · resto del mercado " .. Util.num((b.outsideRate / math.max(1e-9, b.demand)) * 100, 1) .. " %" .. (change and (" · demanda " .. (change >= 0 and "+" or "−") .. Util.num(math.abs(change), 1) .. " % frente a hace un año") or "") .. ". La cuota actual es una estimación con las ofertas de hoy; la histórica es el promedio mensual de lo que tuviste.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.3, name = "ResumenCuotas" }),
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

--[[ Mercado internacional: presencia, preferencias por país y evolución de la oportunidad. Todo sale de las
	reglas (Rules.worldDemand, Rules.countryDemand, Rules.expansionRequirements): no hay ventas por país. ]]
local E = Catalog.EXPANSION

-- Evolución de la demanda mundial en años de referencia: { year, base, total } (con los países abiertos hoy).
function Screen.evolution(g: any): { any }
	local now = Rules.year(g)
	local out, seen = {}, {}
	for _, y in { now, now + 5, now + 10, Catalog.CALENDAR.endYear } do
		local yy = math.min(y, Catalog.CALENDAR.endYear)
		if not seen[yy] then
			seen[yy] = true
			local base, total = Rules.worldDemand(g, yy + 0.5)
			table.insert(out, { year = yy, base = base, total = total })
		end
	end
	return out
end

-- Tipo disponible para fabricar (o el motivo del primer chasis de ese tipo).
local function typeAccess(g: any, typeId: string): (boolean, string?)
	local why = nil
	for _, b in Catalog.BASES do
		if b.type == typeId then
			local w = DesignCalc.baseAvailable(g, b)
			if w == nil then
				return true, nil
			end
			why = why or w
		end
	end
	return false, why
end

function Screen.world(g: any, main: Frame)
	local n = Rules.expansion(g)
	local base, total = Rules.worldDemand(g)
	local q = Rules.expansionQuote(g)
	local opened, pending = {}, {}
	for _, c in E.countries do
		table.insert(Rules.countryOpen(g, c.id) and opened or pending, c.name)
	end
	local pres: { Instance? } = {
		Ui.row({ Ui.grow(Ui.lbl("Presencia mundial")), Ui.chip(n .. " de " .. #E.countries .. " países", n > 0 and "cg" or "cn", { name = "PaisesAbiertos" }) }, 8),
		Ui.between("Países abiertos", #opened > 0 and table.concat(opened, ", ") or "ninguno", { size = Ui.S.sm }),
		Ui.between("Países pendientes", #pending > 0 and table.concat(pending, ", ") or "ninguno", { size = Ui.S.sm }),
		Ui.between("Demanda mundial actual", Util.num(total, 1) .. " autos/min", { name = "DemandaMundial" }),
		Ui.between("Aporte de las expansiones", "+" .. Util.num(total - base, 1) .. " autos/min (×" .. Util.num(Rules.marketFactor(g), 2) .. ")", { name = "AporteExpansion" }),
		Ui.between("Capacidad productiva adicional", "+" .. Util.round(E.line * n * 100) .. " % por línea", { name = "CapacidadExtra" }),
	}
	if q then
		table.insert(pres, Ui.between("Próximo costo de expansión", Util.money(q.cost), { name = "ProximoCosto" }))
		local sold = g.counters.unitsSold
		table.insert(pres, Ui.between("Progreso hacia la próxima apertura", Util.num(sold) .. " / " .. Util.num(q.sold) .. " autos vendidos", { size = Ui.S.sm }))
		table.insert(pres, (Ui.bar(math.min(1, sold / math.max(1, q.sold)) * 100, T.bl, 6)))
		if Rules.nextSede(g) ~= nil then
			table.insert(pres, Ui.text("Además hacen falta las oficinas centrales de nivel " .. #Catalog.SEDES .. ".", { size = Ui.S.xs, color = T.ye }))
		end
	else
		table.insert(pres, Ui.note("g", "Presencia en los diez mercados internacionales disponibles."))
	end
	table.insert(pres, Ui.button("Abrir el mapa mundial", "p", function()
		App.go("expansion")
	end, { small = true, icon = "globe", name = "MercadoAbrirMapa" }))
	Ui.card(pres, { gap = 6, name = "PresenciaMundial" }).Parent = main

	-- Preferencias por país: elegir un país actualiza solo las barras.
	local yf = Rules.yearFrac(g)
	local sel = Rules.country(App.ui.mktCountry) and App.ui.mktCountry or E.countries[1].id
	local bars = Ui.col({}, 6, { Name = "BarrasPreferencias" })
	local chips = {}
	local function fill(id: string)
		App.ui.mktCountry = id
		bars:ClearAllChildren()
		local l = Ui.new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6) })
		l.Parent = bars
		local c = Rules.country(id)
		local contrib, sum = Rules.countryDemand(c, yf)
		local maxP = 0
		for _, t in Catalog.TYPE_ORDER do
			maxP = math.max(maxP, c.prefs[t] or 1)
		end
		-- Abierto: demanda ya incorporada al mercado. Cerrado: lo que sumaría si lo abrieras (potencial).
		local isOpen = Rules.countryOpen(g, id)
		Ui.text(c.name .. (isOpen and (" · abierto · demanda incorporada: +" .. Util.num(sum, 1) .. " autos/min este año")
			or (" · sin abrir · demanda potencial: +" .. Util.num(sum, 1) .. " autos/min este año si lo abrís (no está en el mercado todavía)")) .. ". Por tipo:", { size = Ui.S.xs, color = isOpen and T.gr or T.ye, name = "TipoDemanda" }).Parent = bars
		bars:SetAttribute("demanda", isOpen and "incorporada" or "potencial")
		for _, t in Catalog.TYPE_ORDER do
			local p = c.prefs[t] or 1
			local bar = Ui.bar(p / maxP * 100, (contrib[t] or 0) > 0 and (isOpen and T.bl or T.ye) or T.mut, 6)
			Ui.col({
				Ui.row({ Ui.grow(Ui.inline(Catalog.TYPES[t], { size = Ui.S.xs, color = T.tx2 })), Ui.inline("×" .. Util.num(p, 1) .. " · " .. (isOpen and "" or "potencial ") .. Util.num(contrib[t] or 0, 1) .. "/min", { size = Ui.S.xs, weight = W.semi }) }, 6),
				bar,
			}, 3, { Name = "Pref_" .. t }).Parent = bars
		end
		for cid, b in chips do
			local on = cid == id
			b:SetAttribute("selected", on)
			b.BackgroundColor3 = on and T.vi or T.input
			b.BackgroundTransparency = on and 0.8 or 0
			b.TextColor3 = on and T.tx or T.tx2
			local st = b:FindFirstChildOfClass("UIStroke")
			if st then
				st.Color = on and T.vi or T.line
				st.Thickness = on and 2 or 1
			end
		end
	end
	local chipRow = {}
	for _, c in E.countries do
		local b = Ui.opt(c.name, c.id == sel, function()
			fill(c.id)
		end, { name = "PrefPais_" .. c.id, height = 32 })
		chips[c.id] = b
		table.insert(chipRow, b)
	end
	Ui.card({
		Ui.lbl("Preferencias por mercado"),
		Ui.text("Importancia relativa de cada tipo en cada país (parámetros del juego, no estadísticas reales). Reparte el +" .. Util.round(E.demand * 100) .. " % que aporta el país sin sumar volumen; un tipo sin demanda en su época no recibe nada.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.35 }),
		Ui.row(chipRow, 6, { wrap = true, Name = "PaisesPreferencias" }),
		bars,
	}, { gap = 8, name = "PreferenciasMercado" }).Parent = main
	fill(sel)

	-- Evolución comercial: demanda mundial por año y oportunidad por tipo (con lo que ya podés fabricar).
	local evo: { Instance? } = { Ui.lbl("Evolución comercial"), Ui.text("Demanda mundial (autos/min real a 1×) en años de referencia, sin y con los países que tenés abiertos hoy.", { size = Ui.S.xs, color = T.mut }) }
	for _, r in Screen.evolution(g) do
		table.insert(evo, Ui.between(tostring(r.year), Util.num(r.base, 1) .. " → " .. Util.num(r.total, 1), { size = Ui.S.sm, name = "Evolucion_" .. r.year }))
	end
	local later = math.min(Rules.year(g) + 10, Catalog.CALENDAR.endYear) + 0.5
	for _, t in Catalog.TYPE_ORDER do
		local now, soon = Rules.demand(g, t, yf), Rules.demand(g, t, later)
		local ok, why = typeAccess(g, t)
		table.insert(evo, Ui.between(Catalog.TYPES[t] .. (ok and "" or (" · " .. tostring(why))), Util.num(now, 1) .. " → " .. Util.num(soon, 1) .. " en " .. math.floor(later), { size = Ui.S.xs, color = ok and T.tx2 or T.mut, name = "Oportunidad_" .. t }))
	end
	Ui.card(evo, { gap = 6, name = "EvolucionComercial" }).Parent = main
end

function Screen.build(main: Frame, side: Frame)
	local g = App.g
	local tabs, tab = Sheet.tabs("mercado", { { "tipos", "Demanda por tipo" }, { "rivales", "Marcas rivales" }, { "mundo", "Mercado internacional" } }, "tipos")
	tabs.Parent = main
	if tab == "mundo" then
		Screen.world(g, main)
	elseif tab == "tipos" then
		local shown = 0
		for _, typeId in Catalog.TYPE_ORDER do
			local b = Screen.breakdown(g, typeId)
			if b.demand > 0 then
				typeCard(g, typeId, b).Parent = main
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
		-- Clasificación: todas las empresas por ventas por minuto en todos los tipos (incluida la tuya).
		local rows = { { name = g.company.name .. " (vos)", rate = 0, color = T.vi, me = true, models = {} } }
		local byRival = {}
		for _, r in Catalog.RIVALS do
			byRival[r.id] = { name = r.name, rate = 0, color = hex(r.color), r = r, models = {} }
			table.insert(rows, byRival[r.id])
		end
		local totalDemand = 0
		for _, typeId in Catalog.TYPE_ORDER do
			local b = Screen.breakdown(g, typeId)
			totalDemand += b.demand
			rows[1].rate += b.myRate
			for _, rv in b.rivals do
				local row = byRival[rv.r.rival.id]
				row.rate += rv.rate
				table.insert(row.models, { o = rv.r, typeId = typeId, rate = rv.rate, share = rv.share })
			end
		end
		table.sort(rows, function(a: any, b: any): boolean
			return a.rate > b.rate
		end)
		local ranking: { Instance? } = { Ui.lbl("Clasificación estimada de " .. Rules.year(g) .. " (ventas por minuto con las ofertas de hoy)") }
		for i, row in rows do
			local share = totalDemand > 0 and row.rate / totalDemand * 100 or 0
			local bar = Ui.bar(math.min(100, share * 2), row.color)
			table.insert(ranking, Ui.row({
				Ui.inline(i .. ".", { size = Ui.S.sm, weight = W.bold, width = 22 }),
				Ui.inline(row.name, { size = Ui.S.sm, weight = row.me and W.bold or W.med, color = row.me and T.vi2 or T.tx, width = App.isPhone() and 120 or 190, truncate = true }),
				Ui.grow(bar),
				Ui.inline(Util.num(row.rate, 1) .. "/min · " .. Util.num(share, 1) .. " %", { size = Ui.S.xs, color = T.mut, width = 120, align = "R" }),
			}, 8, { Name = row.me and "PosicionPropia" or ("Posicion_" .. row.name) }))
		end
		Ui.card(ranking, { gap = 8, name = "Clasificacion" }).Parent = main
		if g.rivalNews and #g.rivalNews.items > 0 then
			-- Las noticias guardadas antes de las doce marcas (sin `cuts`) se muestran tal cual: son historia.
			local legacy = g.rivalNews.cuts == nil
			Ui.note("b", "<b>Novedades de " .. g.rivalNews.year .. (legacy and " (marcas de la versión anterior)" or "") .. ":</b> " .. table.concat(g.rivalNews.items, " · ") .. ".").Parent = main
		end
		local yf = Rules.yearFrac(g)
		for _, r in Catalog.RIVALS do
			local row = byRival[r.id]
			local models: { Instance? } = {}
			for _, x in row.models do
				local o = x.o
				table.insert(models, Ui.between(
					o.name .. " · " .. Catalog.TYPES[x.typeId] .. " · " .. o.gen .. ".ª gen. (" .. o.launched .. ") · " .. Util.money(o.price) .. (o.cut > 0.01 and (" (−" .. Util.round(o.cut * 100) .. " %)") or "") .. " · atractivo " .. Util.round(o.appeal),
					Util.num(x.rate, 1) .. "/min · " .. Util.num(x.share * 100, 1) .. " %",
					{ size = Ui.S.xs }
				))
			end
			local coming = {}
			for _, line in r.lines or {} do
				if line.since > yf then
					table.insert(coming, line.name .. " · " .. Catalog.TYPES[line.type] .. " (" .. line.since .. ")")
				end
			end
			local share = totalDemand > 0 and row.rate / totalDemand * 100 or 0
			Ui.card({
				Ui.row({
					Ui.new("Frame", { Name = "Color", BackgroundColor3 = hex(r.color), BackgroundTransparency = 0, Size = UDim2.fromOffset(14, 14), Corner = 7 }),
					Ui.grow(Ui.col({
						Ui.text(r.name .. (r.country and (" · " .. r.country) or ""), { size = 16, weight = W.bold, name = "NombreRival" }),
						r.desc and Ui.text(r.desc, { size = Ui.S.xs, color = T.tx2 }) or nil,
						Ui.text("Especialidades: " .. table.concat(r.specialties or {}, ", "), { size = Ui.S.xs, color = T.mut, name = "Especialidades" }),
						Ui.text("Estrategia: " .. r.strategy .. " · alcance ×" .. Util.num(Rules.rivalReach(r, yf), 2) .. " · nueva generación cada " .. r.cycle .. " años", { size = Ui.S.xs, color = T.mut }),
					}, 2)),
					Ui.chip(Util.num(row.rate, 1) .. " ventas/min · " .. Util.num(share, 1) .. " % estimado", row.rate > 0 and "cg" or "cn", { name = "CuotaRival" }),
				}, 10, { wrap = App.isPhone() }),
				#models > 0 and Ui.col(models, 4) or Ui.text("Sin modelos a la venta este año.", { size = Ui.S.xs, color = T.mut }),
				#coming > 0 and Ui.text("Próximamente: " .. table.concat(coming, ", "), { size = Ui.S.xs, color = T.mut }) or nil,
			}, { gap = 8, name = "Rival_" .. r.id }).Parent = main
		end
	end

	-- Columna lateral
	Ui.card({
		Ui.lbl("Cómo se reparte la demanda"),
		Ui.text("Cada tipo tiene una demanda total por minuto que cambia con los años. Se reparte entre tus modelos, las marcas rivales y el resto del mercado con las mismas reglas para todos: <b>atractivo</b> frente al que se espera en la época (cada 12 puntos más, casi el triple de peso), <b>precio</b> respecto del precio justo, <b>alcance</b> comercial y, en tu caso, <b>reputación</b> y campaña. Si les quitás mercado, las marcas agresivas bajan sus precios, las de respuesta «calidad» mejoran sus modelos y las deportivas compiten con prestaciones. Doce marcas se reparten la misma presión competitiva que había antes: más marcas no es más competencia total. Las cuotas que se ven son estimaciones con las ofertas de hoy, no ventas históricas de los rivales.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.45 }),
	}, { gap = 4, name = "Reparto" }).Parent = side
	Ui.card({
		Ui.lbl("Tu empresa"),
		Ui.between("Alcance de la sede", "×" .. Util.num(Rules.sede(g).reach, 1)),
		Rules.expansion(g) > 0 and Ui.between("Mercado mundial (" .. Rules.expansion(g) .. " países)", "×" .. Util.num(Rules.marketFactor(g), 2)) or nil,
		Ui.between("Reputación", Util.num(g.reputation, 1) .. " / 5"),
		Ui.between("Multiplicador comercial", "×" .. Util.num(Rules.playerMult(g), 2)),
		Rules.campaign(g) and Ui.between("Campaña «" .. Rules.campaign(g).name .. "»", "+" .. Util.round(Rules.campaignBoost(g) * 100) .. " %", { color = T.gr }) or nil,
	}, { gap = 6, name = "TuEmpresa" }).Parent = side
end

return Screen
