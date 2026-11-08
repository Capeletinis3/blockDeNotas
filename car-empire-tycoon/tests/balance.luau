--[[
	Bot de balance: juega una partida completa sin interfaz con una estrategia razonable y mide el ritmo:
	primera venta, primera ganancia, ampliaciones, tiempo entre investigaciones, componentes nuevos, dinero
	y ganancia por década, gasto en producción, rentabilidad por tipo de vehículo. Sirve para ajustar
	Catalog.ECON / DEMAND / SEDES / RESEARCH; no es una prueba que falle (tests/run.luau usa sus métricas).

	Estrategia: diseña el mejor auto que permiten su época e investigaciones (prueba cada pieza y se queda
	con la que más ganancia esperada da), cubre los tipos con más demanda según el tamaño de su sede, saca
	una generación nueva cada 6 años, lanza lotes de ≈ 10 minutos de ventas, elige el precio que más
	ganancia esperada deja, mejora estaciones, investiga lo más barato disponible, usa la mejor campaña que
	puede pagar y amplía la sede apenas cumple los requisitos.

	Uso:  lune run tests/balance.luau [dificultad] [minutos reales] [plano]
	      «plano» = estrategia mínima (dos modelos de 1970 sin generaciones nuevas), para comparar.
	      «uno» = un solo tipo de vehículo (con generaciones nuevas). 4.º argumento «sinexp»: sin expansión global.
]]

local process = require("@lune/process")

local Build = require("./build")
Build.prepare()

local Catalog = require("./.build/shared/Catalog")
local Util = require("./.build/shared/Util")
local DesignCalc = require("./.build/shared/DesignCalc")
local Rules = require("./.build/shared/Rules")
local GameState = require("./.build/server/GameState")
local Simulation = require("./.build/server/Simulation")
local Actions = require("./.build/server/Actions")

local Bot = {}

local function seeded(seed: number)
	local state = seed
	return function(): number
		state = (state * 1103515245 + 12345) % 2147483648
		return state / 2147483648
	end
end

local OBJECTIVE = { compacto = "Económico", sedan = "Familiar", clasico = "Lujo", pickup = "Todoterreno", deportivo = "Deportivo", suv = "Familiar", superdeportivo = "Competición", electrico = "Económico" }

-- Ganancia esperada por minuto de un diseño a su precio de referencia (limitada por una línea). Con poco
-- capital se penalizan los autos caros de fabricar: tiene que poder pagar un lote de ~150 unidades.
local function score(g: any, d: any): number
	local c = DesignCalc.computeDesign(g, d)
	local est = Rules.designSalesEstimate(g, c, d, c.price)
	local v = math.min(est.rate, Rules.lineRate(g)) * (c.price - c.unitCost)
	local capital = g.money / math.max(1, c.unitCost * 150)
	return capital < 1 and v * capital * capital or v
end

-- Mejor diseño posible con la época y las investigaciones actuales (búsqueda pieza por pieza).
function Bot.bestDesign(g: any, baseId: string, name: string, money: number): any
	local base = Catalog.base(baseId)
	local d = DesignCalc.newDraft(g, baseId)
	d.name = name
	d.objective = OBJECTIVE[base.type] or "Familiar"
	local function devCost(x: any): number
		local n = 0
		for _, it in DesignCalc.devItems(g, x) do
			if not it.paid then
				n += it.cost
			end
		end
		return n
	end
	for _ = 1, 2 do
		for _, c in Catalog.CATS do
			local best, bestScore = d.parts[c[1]], score(g, d)
			for _, p in Catalog.partsOf(c[1]) do
				if DesignCalc.partBlock(g, d, p) == nil then
					local old = d.parts[c[1]]
					d.parts[c[1]] = p.id
					local sc = score(g, d)
					if sc > bestScore * 1.01 and devCost(d) <= money * 0.08 then
						best, bestScore = p.id, sc
					end
					d.parts[c[1]] = old
				end
			end
			d.parts[c[1]] = best
		end
		local bq, bs = d.quality, score(g, d)
		for q = 0, 5 do
			d.quality = q
			local sc = score(g, d)
			if sc > bs then
				bq, bs = q, sc
			end
		end
		d.quality = bq
	end
	-- Motor: el nivel más alto investigado y la variante que más suma; equipamiento que mejora el puntaje.
	d.motorLevel = DesignCalc.maxEngineLevel(g, d)
	local bv, bvs = d.motorVariant, score(g, d)
	for _, v in Catalog.ENGINE_VARIANTS do
		if DesignCalc.variantBlock(g, d, v) == nil then
			d.motorVariant = v.id
			local sc = score(g, d)
			if sc > bvs then
				bv, bvs = v.id, sc
			end
		end
	end
	d.motorVariant = bv
	d.equipment = {}
	for _, eq in Catalog.EQUIPMENT do
		if DesignCalc.equipmentBlock(g, eq) == nil then
			local before = score(g, d)
			table.insert(d.equipment, eq.id)
			if score(g, d) <= before * 1.005 then
				table.remove(d.equipment)
			end
		end
	end
	return d
end

-- Precio que maximiza la ganancia esperada por minuto (con el tope de producción de una línea).
function Bot.bestPrice(g: any, d: any): number
	local c = DesignCalc.computeDesign(g, d)
	local bestP, bestV = c.price, -math.huge
	for _, k in { 0.85, 0.95, 1, 1.1, 1.2, 1.35, 1.5, 1.75, 2, 2.4 } do
		local p = Util.round(c.price * k / 10) * 10
		local est = Rules.designSalesEstimate(g, c, d, p)
		local v = math.min(est.rate, Rules.lineRate(g)) * (p - c.unitCost)
		if v > bestV then
			bestP, bestV = p, v
		end
	end
	return bestP
end

-- Juega `minutes` minutos reales. Devuelve el registro de métricas y el estado final.
function Bot.play(_label: string, minutes: number, opts: any?): any
	local o = opts or {}
	local verbose = o.verbose
	local flat = o.flat
	local single = o.single -- un solo tipo de vehículo (el de más demanda), con generaciones nuevas
	local ctx = { events = {}, today = "2026-10-25", yesterday = "2026-10-24", rng = seeded(7) }
	ctx.notify = function() end
	local g = GameState.newGame({ name = "Bot Motors", color = "#7667FF", logo = "pico", now = 1 })
	local m0 = g.money
	local log = {
		milestones = {}, research = {}, unlocks = {}, minMoney = g.money, decades = {}, byType = {}, spent = { produccion = 0, investigacion = 0, mejoras = 0, desarrollo = 0, campanas = 0 },
		designs = 0, generations = 0,
	}
	local t = 0
	local function mark(key: string, text: string?)
		if not log.milestones[key] then
			log.milestones[key] = t / 60
			if verbose then
				print(string.format("  %6.1f min  %-8s %s  %s", t / 60, Util.gameDate(g.time.day), key, text or ""))
			end
		end
	end
	local function claim()
		for _, m in Catalog.MISSIONS do
			if Rules.missionState(g, m) == "lista" then
				if Actions.claimMission(g, ctx, { id = m.id }).ok then
					mark("mision " .. m.id, m.title)
				end
			end
		end
	end
	local function lotOf(designId: string): any
		for _, l in g.lots do
			if l.designId == designId then
				return l
			end
		end
		return nil
	end
	-- Tipos que cubre según la sede: los de más demanda con alguna base disponible.
	local function wantedTypes(): { string }
		local list = {}
		for _, typeId in Catalog.TYPE_ORDER do
			local dem = Rules.demand(g, typeId)
			local ok = false
			for _, b in Catalog.BASES do
				if b.type == typeId and DesignCalc.baseAvailable(g, b) == nil then
					ok = true
				end
			end
			if dem > 0 and ok then
				table.insert(list, { typeId, dem })
			end
		end
		table.sort(list, function(a, b)
			return a[2] > b[2]
		end)
		local out = {}
		-- Como en el tutorial: un solo modelo hasta vender los primeros autos.
		local n = (g.counters.unitsSold < 25 or single) and 1 or (flat and 2 or math.min(#list, 1 + g.sede))
		for i = 1, n do
			if list[i] then
				table.insert(out, list[i][1])
			end
		end
		return out
	end
	local function bestBase(typeId: string): string?
		local pick, py = nil, -1
		for _, b in Catalog.BASES do
			if b.type == typeId and DesignCalc.baseAvailable(g, b) == nil and (b.year or 1970) > py then
				pick, py = b.id, b.year or 1970
			end
		end
		return pick
	end
	local current: { [string]: any } = {} -- tipo → diseño vigente
	local serial = 0
	local function save(d: any, newGenOf: string?): any
		local r = Actions.saveDesign(g, ctx, { draft = Util.deepCopy(d), newGenOf = newGenOf })
		if r.ok then
			log.designs += 1
			for _, x in g.designs do
				if x.id == r.designId then
					return x
				end
			end
		end
		return nil
	end
	local function manageDesigns()
		for _, typeId in wantedTypes() do
			local cur = current[typeId]
			local baseId = bestBase(typeId)
			if baseId then
				if not cur then
					local d = Bot.bestDesign(g, baseId, Catalog.TYPES[typeId] .. " Bot", g.money)
					local x = save(d)
					if x then
						current[typeId] = x
						mark("diseño " .. typeId, x.name .. " " .. x.generation)
					end
				elseif (not flat and Rules.year(g) >= (cur.modelYear or 1970) + 6) or (cur.lotLaunched and not lotOf(cur.id)) then
					local old = cur
					-- Un lote por modelo: para volver a fabricar, nueva generación (si ya se puede) o modelo nuevo.
					if not flat and Rules.canNewGeneration(g, cur) then
						local d = Bot.bestDesign(g, baseId, cur.name, g.money)
						local x = save(d, cur.id)
						if x then
							log.generations += 1
							current[typeId] = x
							if verbose then
								print(string.format("  %6.1f min  %-8s nueva generación %s %s", t / 60, Util.gameDate(g.time.day), x.name, x.generation))
							end
						end
					elseif cur.lotLaunched and not lotOf(cur.id) then
						serial += 1
						local d = flat and Util.deepCopy(cur) or Bot.bestDesign(g, baseId, cur.name, g.money)
						d.id, d.lineage, d.gen, d.lotLaunched, d.template = nil, nil, 1, nil, nil
						d.name = Util.truncateChars(Catalog.TYPES[typeId], 14) .. " Bot " .. serial
						local x = save(d)
						if x then
							current[typeId] = x
						end
					end
					-- El modelo anterior ya vendió su lote: se borra (su historia queda en el historial).
					if current[typeId] ~= old and old.lotLaunched and not lotOf(old.id) then
						Actions.delDesign(g, ctx, { designId = old.id })
					end
				end
			end
		end
	end
	local function launch()
		-- Lotes terminados con reseñas: salen a la venta al mejor precio estimado.
		for _, l in g.lots do
			if l.saleState == "por lanzar" then
				local p = Bot.bestPrice(g, l.design.spec)
				local lo, hi = Rules.priceRange(l.unitCost, l.refPrice)
				Actions.launchSale(g, ctx, { lotId = l.id, price = math.clamp(p, lo, hi) })
			end
		end
		for _, x in current do
			if not x.lotLaunched and not lotOf(x.id) and #g.lots < Catalog.RULES.maxActiveLots then
				local c = DesignCalc.computeDesign(g, x)
				local price = Bot.bestPrice(g, x)
				local est = Rules.designSalesEstimate(g, c, x, price)
				local share = #g.lots == 0 and 0.8 or 0.5
				-- Un lote por modelo: lotes de ≈ 20 minutos de ventas (la ingeniería se paga por modelo).
				local qty = math.floor(math.min(math.min(est.rate, Rules.lineRate(g) * 1.5) * 20, g.money * share / c.unitCost))
				if qty >= 10 then
					local r = Actions.createLot(g, ctx, { designId = x.id, qty = qty, price = price })
					if r.ok then
						mark("lote " .. x.name, Util.num(qty) .. " u a " .. Util.money(price))
					end
				end
			end
		end
	end
	-- Investigación: varias a la vez (hasta el máximo), siempre la más barata en PI que se pueda pagar sin
	-- comprometer la fabricación; primero las que no son adelantadas.
	local function research()
		while #g.research.projects < Catalog.RESEARCH_RULES.maxParallel do
			local best, bestPi, bestAhead = nil, math.huge, math.huge
			for _, key in Catalog.RESEARCH_ORDER do
				for _, n in Catalog.RESEARCH[key].nodes do
					if Rules.researchState(g, n) == "disponible" and #g.lots > 0 then
						local pi, cost, _, info = Rules.researchCost(g, n)
						if pi <= g.rp and g.money >= cost * 3 and (info.ahead < bestAhead or (info.ahead == bestAhead and pi < bestPi)) then
							best, bestPi, bestAhead = n, pi, info.ahead
						end
					end
				end
			end
			if not best then
				return
			end
			local r = Actions.startResearch(g, ctx, { id = best.id })
			if not r.ok then
				return
			end
			local proj = g.research.projects[#g.research.projects]
			table.insert(log.research, { start = t / 60, id = best.id, name = best.name, rp = proj.paidPi, cost = proj.paidMoney, days = proj.days, tier = best.complexity, year = Rules.year(g), nodeYear = best.year })
		end
	end
	local function upgrade()
		for _, s in Catalog.STATIONS do
			local st = g.stations[s[1]]
			if st.level < Rules.maxStationLevel(g) and g.money > Rules.upgradeCost(st) * 5 then
				Actions.upgradeStation(g, ctx, { station = s[1] })
			end
		end
	end
	-- Campaña corporativa de 60 días si la ganancia extra estimada (margen de los últimos 3 meses) supera el costo.
	local function campaign()
		if flat or Rules.campaign(g) or Rules.modelsOnSale(g) == 0 then
			return
		end
		local monthly = Rules.finance(g, 3).margin / 3
		local best, bestV
		for _, m in { 0.5, 1, 2, 4 } do
			local plan = Rules.campaignPlan(g, { kind = "corporativa", budget = Util.round(Catalog.MARKETING.budgetRef * Rules.marketingEra(g) * m), days = 60 })
			if plan then
				local v = monthly * 2 * plan.boost * 0.5 - plan.cost
				if v > 0 and (not bestV or v > bestV) then
					best, bestV = plan, v
				end
			end
		end
		if best and g.money > best.cost * 3 then
			Actions.startCampaign(g, ctx, { kind = "corporativa", budget = best.budget, days = 60 })
		end
	end
	local lastYear = Rules.year(g)
	local yearStart = { money = g.money, revenue = 0 }
	local doneBefore = 0
	local partsSeen = {}
	local function trackUnlocks()
		for _, c in Catalog.CATS do
			for _, p in Catalog.partsOf(c[1]) do
				local key = c[1] .. ":" .. p.id
				if not partsSeen[key] then
					local ok = false
					for _, b in Catalog.BASES do
						local probe = { baseId = b.id }
						if DesignCalc.baseAvailable(g, b) == nil and DesignCalc.partBlock(g, probe, p) == nil then
							ok = true
						end
					end
					if ok then
						partsSeen[key] = true
						table.insert(log.unlocks, { min = t / 60, year = Rules.year(g), name = p.name })
					end
				end
			end
		end
	end
	trackUnlocks()
	local unlockBase = #log.unlocks
	while t < minutes * 60 do
		local money0, prod0 = g.money, g.counters.unitsProduced
		Simulation.simulate(g, ctx, 10)
		t += 1
		local _ = money0 + prod0
		if g.money < log.minMoney then
			log.minMoney = g.money
		end
		assert(g.money >= 0, "dinero negativo")
		if #g.research.done > doneBefore then
			for i = doneBefore + 1, #g.research.done do
				for _, r in log.research do
					if r.id == g.research.done[i] and not r.finish then
						r.finish = t / 60
					end
				end
			end
			doneBefore = #g.research.done
			trackUnlocks()
		end
		if g.counters.unitsSold > 0 then
			mark("primera venta")
		end
		if g.sede > (log.lastSede or 1) then
			log.lastSede = g.sede
			mark("sede " .. g.sede, Rules.sede(g).name)
		end
		if g.money > m0 and log.milestones["primera venta"] then
			mark("primera ganancia", "el dinero supera el capital inicial")
		end
		if t % 10 == 0 then
			claim()
			manageDesigns()
			launch()
			research()
			upgrade()
			campaign()
			-- Instalaciones: oficinas apenas cumple los requisitos; línea 2, fábrica y centro cuando sobra dinero.
			local function tryBuild(kind: string, margin: number)
				local nx = Rules.nextFacility(g, kind)
				if not nx or g.money < nx.cost * margin then
					return
				end
				for _, c in Rules.facilityChecks(g, kind) do
					if not c[1] then
						return
					end
				end
				Actions.upgradeFacility(g, ctx, { kind = kind })
			end
			tryBuild("offices", 1)
			tryBuild("line2", 1.5)
			tryBuild("factory", flat and 3 or 1.3)
			tryBuild("research", flat and 4 or 1.6)
			local nx = Rules.nextExpansion(g)
			if nx and not o.noExpansion and g.counters.unitsSold >= nx.sold and g.money >= nx.cost * 1.2 and Actions.expandGlobal(g, ctx, {}).ok then
				mark("region " .. g.expansion, nx.name)
			end
		end
		if Rules.year(g) ~= lastYear then
			local f = Rules.finance(g, 12)
			local dec = math.floor(lastYear / 10) * 10
			local dd = log.decades[dec] or { revenue = 0, manufacturing = 0, net = 0, research = 0, upgrades = 0, endMoney = 0, sold = 0 }
			dd.revenue += f.revenue
			dd.manufacturing += f.manufacturing
			dd.net += f.cash
			dd.research += f.invest.investigacion
			dd.upgrades += f.invest.mejoras
			dd.sold += f.units
			dd.endMoney = g.money
			dd.sede = g.sede
			dd.techs = #g.research.done
			dd.regions = g.expansion
			log.decades[dec] = dd
			log.spent.produccion += f.manufacturing
			log.spent.investigacion += f.invest.investigacion
			log.spent.mejoras += f.invest.mejoras
			log.spent.desarrollo += f.invest.desarrollo
			log.spent.campanas += f.opex.promocion
			lastYear = Rules.year(g)
			yearStart.money = g.money
			if verbose and lastYear % 5 == 0 then
				print(string.format("  %6.1f min  %d · %s · vendidos %s · sede %d · %d tecnologías · %.0f PI/min · fábrica %.0f/min", t / 60, lastYear, Util.money(g.money), Util.num(g.counters.unitsSold), g.sede, #g.research.done, Rules.piPerMinute(g), Rules.caps(g).capacity))
			end
		end
	end
	-- Rentabilidad por tipo (todos los lotes, activos e historial permanente).
	for _, e in g.modelHistory do
		local bt = log.byType[e.type] or { sold = 0, revenue = 0, cost = 0 }
		bt.sold += e.sold
		bt.revenue += e.revenue
		bt.cost += e.cost
		log.byType[e.type] = bt
	end
	for _, l in g.lots do
		local bt = log.byType[l.design.type] or { sold = 0, revenue = 0, cost = 0 }
		bt.sold += l.sold
		bt.revenue += l.revenue
		bt.cost += l.costSpent
		log.byType[l.design.type] = bt
	end
	log.newUnlocks = #log.unlocks - unlockBase
	log.g = g
	return log
end

-- Intervalos entre investigaciones terminadas (minutos reales) y duración por nivel de importancia.
function Bot.researchSummary(log: any): any
	local finishes = {}
	local byTier = {}
	local lag, lagN = 0, 0
	for _, r in log.research do
		if r.finish then
			table.insert(finishes, r.finish)
			local bt = byTier[r.tier] or { n = 0, total = 0, max = 0 }
			bt.n += 1
			bt.total += r.finish - r.start
			bt.max = math.max(bt.max, r.finish - r.start)
			byTier[r.tier] = bt
			if r.year and r.nodeYear then
				lag += r.year - r.nodeYear
				lagN += 1
			end
		end
	end
	table.sort(finishes)
	local gaps = 0
	for i = 2, #finishes do
		gaps += finishes[i] - finishes[i - 1]
	end
	return { done = #finishes, avgGap = #finishes > 1 and gaps / (#finishes - 1) or 0, byTier = byTier, avgLag = lagN > 0 and lag / lagN or 0 }
end

if not _G.BALANCE_AS_MODULE then
	local args = process.args
	local dif = args[1] or "normal"
	local minutes = tonumber(args[2]) or 120
	local flat = args[3] == "plano"
	local single = args[3] == "uno"
	print("Bot de balance · dificultad " .. dif .. " · " .. minutes .. " minutos reales" .. (flat and " · estrategia plana" or ""))
	local log = Bot.play(dif, minutes, { verbose = true, flat = flat, single = single, noExpansion = args[4] == "sinexp" })
	local rs = Bot.researchSummary(log)
	print(string.format("\nInvestigaciones terminadas: %d · una cada %.1f min en promedio · se investigan %.1f años después de aparecer", rs.done, rs.avgGap, rs.avgLag))
	for k = 1, 5 do
		local bt = rs.byTier[k]
		if bt then
			print(string.format("  %-22s %2d · desde que empieza: media %.1f min · máxima %.1f min", Catalog.RESEARCH_RULES.complexityLabel[k], bt.n, bt.total / bt.n, bt.max))
		end
	end
	print("\nPor década (ingresos · fabricación · flujo neto · dinero al cerrar · sede · tecnologías):")
	for dec = 1970, 2030, 10 do
		local d = log.decades[dec]
		if d then
			print(string.format("  %ds  %15s  %15s  %15s  %15s  sede %d  %d tec.  %d reg.", dec, Util.money(d.revenue), Util.money(d.manufacturing), Util.money(d.net), Util.money(d.endMoney), d.sede, d.techs, d.regions or 0))
		end
	end
	print("\nRentabilidad por tipo (vendidos · ingresos · margen):")
	for typeId, bt in log.byType do
		print(string.format("  %-15s %10s  %15s  %5.1f %%", typeId, Util.num(bt.sold), Util.money(bt.revenue), bt.revenue > 0 and (bt.revenue - bt.cost) / bt.revenue * 100 or 0))
	end
	print(string.format("\nGasto total: producción %s · investigación %s · mejoras y sede %s · desarrollo %s · campañas %s", Util.money(log.spent.produccion), Util.money(log.spent.investigacion), Util.money(log.spent.mejoras), Util.money(log.spent.desarrollo), Util.money(log.spent.campanas)))
	print(string.format("Componentes nuevos desbloqueados: %d · diseños %d · generaciones nuevas %d · dinero mínimo %s", log.newUnlocks, log.designs, log.generations, Util.money(log.minMoney)))
	Build.clean()
end

return Bot
