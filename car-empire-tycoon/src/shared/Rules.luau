--!strict
--[[
	Reglas derivadas de una partida: calendario, capacidades de la sede, tecnologías, producción por lotes,
	mercado (atractivo, rivales y reparto de la demanda), investigación, misiones y finanzas.
	Son funciones puras: el servidor las usa para simular y validar, y el cliente para mostrar exactamente
	las mismas cifras (ventas por minuto, cuota, PI por minuto…). Ninguna modifica la partida.
]]

local Catalog = require(script.Parent.Catalog)
local Util = require(script.Parent.Util)

local Rules = {}

local ECON = Catalog.ECON
local MONTH = Catalog.RULES.dayMinutes -- minutos de juego de un mes
local GAME_MIN_PER_REAL_MIN = Catalog.RULES.minutesPerRealSecond * 60 -- 600

function Rules.has(g: any, researchId: string?): boolean
	if not researchId then
		return true
	end
	return g ~= nil and g.research ~= nil and Util.contains(g.research.done, researchId)
end

-- Calendario ------------------------------------------------------------------------

function Rules.year(g: any): number
	return Catalog.CALENDAR.startYear + math.floor(g.time.day / 12)
end

-- Año con decimales (para curvas de demanda y la expectativa del mercado).
function Rules.yearFrac(g: any): number
	return Catalog.CALENDAR.startYear + (g.time.day + g.time.minute / MONTH) / 12
end

function Rules.absMinute(g: any): number
	return g.time.day * MONTH + g.time.minute
end

-- Minutos de juego → minutos reales a velocidad 1×.
function Rules.realMinutes(gameMinutes: number): number
	return gameMinutes / GAME_MIN_PER_REAL_MIN
end

-- Sede y capacidades ---------------------------------------------------------------------

function Rules.sede(g: any): any
	return Catalog.SEDES[Util.clamp(g.sede or 1, 1, #Catalog.SEDES)]
end

-- Suma de los efectos de las tecnologías investigadas (Catalog.RESEARCH … fx).
function Rules.tech(g: any, key: string): number
	local n = 0
	if g and g.research then
		for _, id in g.research.done do
			local node = Catalog.researchNode(id)
			if node and node.fx and node.fx[key] then
				n += node.fx[key]
			end
		end
	end
	return n
end

-- Aporte de un puesto: habilidad × afinidad (la mitad si no es el rol ideal).
function Rules.staffBonus(g: any, area: string): number
	local st = Catalog.station(area) or Catalog.department(area)
	local want = st and st[3] or nil
	local total = 0
	for _, e in g.employees or {} do
		if e.assign == area then
			total += (e.skill / 100) * (e.role == want and 1 or 0.5)
		end
	end
	return total
end

function Rules.assignedCount(g: any, area: string, exceptId: string?): number
	local n = 0
	for _, e in g.employees or {} do
		if e.assign == area and e.id ~= exceptId then
			n += 1
		end
	end
	return n
end

function Rules.salaries(g: any): number
	local n = 0
	for _, e in g.employees or {} do
		n += e.salary
	end
	return n
end

function Rules.maxStationLevel(g: any): number
	return math.min(6, (g.sede or 1) + 1)
end

function Rules.upgradeCost(s: any): number
	return Util.round(5000 * math.pow(2.2, s.level - 1) / 100) * 100
end

-- Multiplicador de la fábrica: mejoras de estaciones, tecnología y personal asignado a las estaciones.
function Rules.factoryMult(g: any): number
	local levels = 0
	local staff = 0
	for _, st in Catalog.STATIONS do
		levels += (g.stations[st[1]].level - 1)
		staff += Rules.staffBonus(g, st[1])
	end
	return (1 + Catalog.STATION_SPEED * levels) * (1 + Rules.tech(g, "prodSpeed") / 100) * (1 + math.min(0.3, staff * 0.05))
end

-- Autos por minuto real que fabrica cada línea a 1×.
function Rules.lineRate(g: any): number
	return Rules.sede(g).perLine * Rules.factoryMult(g)
end

function Rules.caps(g: any): any
	local s = Rules.sede(g)
	return {
		lines = s.lines,
		perLine = Rules.lineRate(g),
		capacity = Rules.lineRate(g) * s.lines,
		reach = s.reach,
		staff = s.staff,
		pi = s.pi,
	}
end

-- Puntos de investigación por minuto real: la sede es la fuente principal; el laboratorio suma hasta 30 %.
function Rules.piPerMinute(g: any): number
	local base = Rules.sede(g).pi
	local lab = math.min(base * 0.3, Rules.staffBonus(g, "laboratorio") * math.max(1, base * 0.15))
	return base + lab
end

-- Tope del banco de PI sin proyecto activo: unos minutos de generación (Catalog.RULES.piBankMinutes).
function Rules.piCap(g: any): number
	return Rules.piPerMinute(g) * Catalog.RULES.piBankMinutes
end

function Rules.xpForLevel(l: number): number
	return Util.round(400 * math.pow(l, 1.35))
end

-- Lotes ----------------------------------------------------------------------------------

function Rules.lotAvailable(lot: any): number
	return math.max(0, lot.produced - lot.sold - lot.discarded)
end

function Rules.lotPending(lot: any): number
	if lot.prodState == "cancelado" then
		return 0
	end
	return math.max(0, lot.qty - lot.produced)
end

function Rules.lotProducing(lot: any): boolean
	return lot.prodState ~= "completado" and lot.prodState ~= "cancelado"
end

-- Lotes que ocupan una línea en este momento: los primeros N con producción pendiente y sin pausa manual.
function Rules.producingLots(g: any): { any }
	local out = {}
	local lines = Rules.sede(g).lines
	for _, lot in g.lots do
		if Rules.lotProducing(lot) and lot.prodState ~= "pausado" and #out < lines then
			table.insert(out, lot)
		end
	end
	return out
end

-- Mercado ----------------------------------------------------------------------------------

-- Atractivo medio que el mercado espera ese año (sube con el tiempo: un modelo viejo pierde terreno).
function Rules.eraBaseline(yearFrac: number): number
	local b = ECON.eraBaseline
	return b[1970] + (b[2030] - b[1970]) * Util.clamp((yearFrac - 1970) / 60, 0, 1.5)
end

-- Índices 0–100 de un auto, a partir de sus estadísticas calculadas.
function Rules.indices(calc: any): any
	local eco
	if calc.ev then
		eco = Util.clamp(110 - (calc.consumption - 10) * 3, 0, 100)
	else
		eco = Util.clamp(100 - (calc.consumption - 5) * 7, 0, 100)
	end
	return {
		power = Util.clamp(100 * (1 - (calc.accel - 4) / 12), 0, 100),
		eco = eco,
		comfort = calc.comfort,
		safety = calc.safety or 40,
		dur = calc.durability,
		hand = calc.handling,
		quality = calc.quality,
	}
end

-- Atractivo (0–100) de un auto para sus compradores: 40 % calidad + 60 % lo que pide su objetivo.
function Rules.appeal(calc: any, spec: any): (number, any)
	local idx = Rules.indices(calc)
	local w = Catalog.OBJECTIVE_WEIGHTS[spec.objective] or Catalog.OBJECTIVE_WEIGHTS["Familiar"]
	local obj = 0
	for k, v in w do
		obj += (idx[k] or 50) * v
	end
	local base = Catalog.base(spec.baseId)
	-- Un todoterreno tiene que serlo: sin plataforma todoterreno el objetivo pierde sentido.
	if spec.objective == "Todoterreno" and base and not Util.contains(base.tags, "offroad") then
		obj -= 15
	end
	local a = 0.4 * idx.quality + 0.6 * obj
	return a, { quality = idx.quality, objective = obj, indices = idx }
end

-- Demanda total del tipo este año (autos/min real), con la dificultad.
function Rules.demand(g: any, type: string, yearFrac: number?): number
	local curve = Catalog.DEMAND[type]
	if not curve then
		return 0
	end
	local dif = Catalog.DIFFICULTIES[g.company.difficulty] or Catalog.DIFFICULTIES.normal
	return Catalog.interp(curve, yearFrac or Rules.yearFrac(g)) * dif.demand
end

-- Modelos rivales que se venden este año en ese tipo: { rival, name, appeal, weight }.
function Rules.rivalOffers(type: string, yearFrac: number): { any }
	local out = {}
	local baseline = Rules.eraBaseline(yearFrac)
	for i, r in Catalog.RIVALS do
		local since = r.types[type]
		if since and yearFrac >= since then
			-- Nueva generación cada 6 años; el atractivo oscila un poco con el ciclo del modelo.
			local age = yearFrac - since
			local gen = math.floor(age / 6) + 1
			local cycle = (age % 6) / 6
			local offset = Catalog.interp(r.offset, yearFrac) + 2 - cycle * 4 + math.sin(i * 1.7 + gen) * 1.5
			local appeal = baseline + offset
			local seg = offset >= 3.5 and "Premium" or (offset >= 0 and "Masivo" or "Económico")
			table.insert(out, {
				rival = r,
				name = r.models[type] .. (gen > 1 and (" '" .. string.sub(tostring(math.floor(since + (gen - 1) * 6)), 3)) or ""),
				since = since,
				gen = gen,
				segment = seg,
				-- Precio de lista: el típico del tipo, más caro cuanto mejor posicionado y más moderno.
				price = math.floor((Catalog.RIVAL_PRICE[type] or 4000) * (1 + offset * 0.03) * (1 + (yearFrac - 1970) * 0.006) / 10 + 0.5) * 10,
				appeal = appeal,
				weight = math.exp((appeal - baseline) / ECON.appealScale),
			})
		end
	end
	return out
end

-- Multiplicador comercial de la empresa: alcance de la sede × reputación × tecnologías × campaña × personal.
function Rules.playerMult(g: any): number
	local s = Rules.sede(g)
	local rep = 0.6 + g.reputation * 0.14
	local tech = 1 + Rules.tech(g, "demand") / 100
	local campaign = g.promo and (1 + ECON.campaignBoost) or 1
	local staff = 1 + math.min(0.25, (Rules.staffBonus(g, "ventas") + Rules.staffBonus(g, "marketing")) * 0.05)
	return s.reach * rep * tech * campaign * staff
end

-- Factor de precio: vender por encima del precio de referencia baja las ventas (y al revés).
function Rules.priceFactor(price: number, ref: number): number
	return Util.clamp(math.pow(ref / math.max(1, price), ECON.priceElasticity), 0.02, 3)
end

-- Precio permitido para un lote: desde la mitad del costo hasta 3 veces el precio de referencia, de a $10.
function Rules.priceRange(unitCost: number, refPrice: number): (number, number)
	return math.max(10, Util.round(unitCost * ECON.priceMin / 10) * 10), Util.round(refPrice * ECON.priceMax / 10) * 10
end

-- Peso de un lote del jugador en el reparto de la demanda de su tipo.
function Rules.lotWeight(g: any, lot: any, yearFrac: number): number
	local baseline = Rules.eraBaseline(yearFrac)
	local seg = Catalog.SEGMENTS[lot.design.spec.segment] or Catalog.SEGMENTS.Masivo
	return math.exp((lot.appeal - baseline) / ECON.appealScale) * Rules.priceFactor(lot.price, lot.refPrice) * Rules.playerMult(g) * seg.pop
end

--[[ Reparto de la demanda de un tipo entre: el resto del mercado (peso fijo), los modelos rivales y los
	lotes del jugador en venta con stock. Devuelve { demand, total, outside, rivals = {…}, lots = { [id] = peso } }. ]]
function Rules.market(g: any, type: string): any
	local yf = Rules.yearFrac(g)
	local m = { demand = Rules.demand(g, type, yf), outside = ECON.outsideWeight, rivals = Rules.rivalOffers(type, yf), lots = {} }
	local total = m.outside
	for _, r in m.rivals do
		total += r.weight
	end
	for _, lot in g.lots do
		if lot.saleState == "en venta" and lot.design.type == type and Rules.lotAvailable(lot) > 0 then
			local w = Rules.lotWeight(g, lot, yf)
			m.lots[lot.id] = w
			total += w
		end
	end
	m.total = total
	return m
end

-- Ventas esperadas por minuto real a 1× de un lote (0 si no tiene stock o no está en venta).
-- `market` se puede pasar para no recalcularlo por cada lote del mismo tipo.
function Rules.lotSalesRate(g: any, lot: any, market: any?): number
	if lot.saleState ~= "en venta" then
		return 0
	end
	local m = market or Rules.market(g, lot.design.type)
	local w = m.lots[lot.id]
	if not w then
		return 0
	end
	return m.demand * w / m.total
end

-- Ventas posibles si el lote tuviera stock (para mostrar el potencial mientras se fabrica la primera unidad).
function Rules.lotPotentialRate(g: any, lot: any): number
	local m = Rules.market(g, lot.design.type)
	if m.lots[lot.id] then
		return m.demand * m.lots[lot.id] / m.total
	end
	local w = Rules.lotWeight(g, lot, Rules.yearFrac(g))
	return m.demand * w / (m.total + w)
end

-- Estimación para un diseño que todavía no se fabricó (diálogo de lote y editor).
function Rules.designSalesEstimate(g: any, calc: any, spec: any, price: number?): any
	local base = Catalog.base(spec.baseId)
	local fake = { id = "_", saleState = "en venta", produced = 1, sold = 0, discarded = 0, price = price or calc.price, refPrice = calc.price, appeal = (Rules.appeal(calc, spec)), design = { type = base.type, spec = spec } }
	local m = Rules.market(g, base.type)
	local w = Rules.lotWeight(g, fake, Rules.yearFrac(g))
	return { rate = m.demand * w / (m.total + w), share = w / (m.total + w), demand = m.demand, appeal = fake.appeal, baseline = Rules.eraBaseline(Rules.yearFrac(g)) }
end

-- Investigación ---------------------------------------------------------------------------

function Rules.researchMissing(g: any, n: any): { string }
	local m = {}
	if Rules.year(g) < n.year then
		table.insert(m, "Disponible desde " .. n.year)
	end
	for _, r in n.req do
		if not Rules.has(g, r) then
			table.insert(m, "Investigar «" .. Catalog.researchNode(r).name .. "»")
		end
	end
	return m
end

function Rules.researchState(g: any, n: any): string
	if Rules.has(g, n.id) then
		return "hecha"
	end
	if g.research.active and g.research.active.id == n.id then
		return "activa"
	end
	return #Rules.researchMissing(g, n) > 0 and "bloqueada" or "disponible"
end

-- Segundos reales que faltan (a 1×) para terminar la investigación activa con el banco y la generación actual.
function Rules.researchEta(g: any): number?
	local a = g.research.active
	if not a then
		return nil
	end
	local n = Catalog.researchNode(a.id)
	local left = math.max(0, n.rp - a.progress - g.rp)
	return left / math.max(0.01, Rules.piPerMinute(g)) * 60
end

-- Estadísticas por mes --------------------------------------------------------------------

function Rules.dayKey(day: number): string
	return tostring(math.floor(day))
end

function Rules.dayStats(g: any, day: number): any
	return g.stats.days[Rules.dayKey(day)]
end

local EMPTY = { revenue = 0, cogs = 0, units = 0, margin = 0, produced = 0, flow = {} }

--[[ Finanzas de los últimos `months` meses, con base en caja (nada se cuenta dos veces):
	revenue = ingresos por ventas · manufacturing = dinero gastado en fabricar (incluye stock sin vender)
	cogs/margin = costo de fabricación de lo VENDIDO y margen bruto (indicador por unidad, no se resta otra vez)
	net = resultado neto = todo lo que entró − todo lo que salió. ]]
function Rules.finance(g: any, months: number): any
	local from = g.time.day - months + 1
	local f = { days = months, from = from, revenue = 0, cogs = 0, units = 0, margin = 0, cash = 0, inflow = 0, outflow = 0, produced = 0, byType = {}, series = {} }
	for d = from, g.time.day do
		local ds = g.stats.days[Rules.dayKey(d)] or EMPTY
		f.revenue += ds.revenue
		f.cogs += ds.cogs
		f.units += ds.units
		f.margin += ds.margin
		f.produced += ds.produced or 0
		local dayCash = 0
		for kind, amount in ds.flow do
			f.byType[kind] = (f.byType[kind] or 0) + amount
			dayCash += amount
			if amount >= 0 then
				f.inflow += amount
			else
				f.outflow += amount
			end
		end
		f.cash += dayCash
		table.insert(f.series, { day = d, revenue = ds.revenue, cash = dayCash, units = ds.units })
	end
	local function spent(kinds: { string }): number
		local n = 0
		for _, k in kinds do
			n -= math.min(0, f.byType[k] or 0)
		end
		return n
	end
	f.manufacturing = spent({ "fabricacion" })
	f.opex = { salarios = spent({ "salarios" }), promocion = spent({ "promocion" }) }
	f.invest = { desarrollo = spent({ "desarrollo" }), investigacion = spent({ "investigacion" }), mejoras = spent({ "mejora", "sede" }), contratacion = spent({ "contratacion" }) }
	f.net = f.cash
	f.opProfit = f.revenue - f.manufacturing - f.opex.salarios - f.opex.promocion
	f.demo = g.demo ~= nil and g.demo ~= "tutorial"
	return f
end

-- Totales del año calendario en curso (misiones anuales).
function Rules.yearStats(g: any): any
	local first = g.time.day - (g.time.day % 12)
	local t = { units = 0, produced = 0, margin = 0, revenue = 0 }
	for d = first, g.time.day do
		local ds = g.stats.days[Rules.dayKey(d)]
		if ds then
			t.units += ds.units
			t.produced += ds.produced or 0
			t.margin += ds.margin
			t.revenue += ds.revenue
		end
	end
	return t
end

-- Misiones ----------------------------------------------------------------------------

function Rules.missionGoal(g: any, m: any): number
	if m.goalScale == "reach" then
		return Util.round(m.goal * Rules.sede(g).reach)
	end
	return m.goal
end

function Rules.missionReward(g: any, m: any): any
	if m.goalScale == "reach" then
		local k = Rules.sede(g).reach
		return { money = m.reward.money and Util.round(m.reward.money * k / 100) * 100 or nil, pi = m.reward.pi and Util.round(m.reward.pi * k) or nil, xp = m.reward.xp }
	end
	return m.reward
end

function Rules.missionValue(g: any, m: any): number
	if m.counter == "soldYear" or m.counter == "producedYear" or m.counter == "marginYear" then
		local y = Rules.yearStats(g)
		return (m.counter == "soldYear" and y.units) or (m.counter == "producedYear" and y.produced) or math.max(0, y.margin)
	elseif m.counter == "sedeLevel" then
		return g.sede
	end
	return g.counters[m.counter] or 0
end

function Rules.missionKey(g: any, m: any): string
	return m.kind == "anual" and (m.id .. "@" .. Rules.year(g)) or m.id
end

function Rules.missionState(g: any, m: any): string
	if g.claimed[Rules.missionKey(g, m)] then
		return "reclamada"
	end
	return Rules.missionValue(g, m) >= Rules.missionGoal(g, m) and "lista" or "progreso"
end

function Rules.currentTutorial(g: any): any
	for _, m in Catalog.MISSIONS do
		if m.kind == "tutorial" and Rules.missionState(g, m) ~= "reclamada" then
			return m
		end
	end
	return nil
end

function Rules.readyMissions(g: any): number
	local n = 0
	for _, m in Catalog.MISSIONS do
		if Rules.missionState(g, m) == "lista" then
			n += 1
		end
	end
	return n
end

function Rules.rewardText(r: any): string
	local parts = {}
	if r.money then
		table.insert(parts, "+" .. Util.money(r.money))
	end
	if r.pi then
		table.insert(parts, "+" .. r.pi .. " PI")
	end
	if r.xp then
		table.insert(parts, "+" .. r.xp .. " XP")
	end
	return table.concat(parts, " · ")
end

-- Ampliación de sede ---------------------------------------------------------------------

function Rules.nextSede(g: any): any
	return Catalog.SEDES[(g.sede or 1) + 1]
end

function Rules.expandChecks(g: any): { any }
	local next = Rules.nextSede(g)
	if not next then
		return {}
	end
	return {
		{ g.counters.unitsSold >= next.req.sold, "Autos vendidos: " .. Util.num(g.counters.unitsSold) .. "/" .. Util.num(next.req.sold) },
		{ g.reputation >= next.req.rep, "Reputación: " .. Util.num(g.reputation, 1) .. "/" .. Util.num(next.req.rep, 1) },
		{ g.money >= next.cost, "Dinero: " .. Util.money(g.money) .. " / " .. Util.money(next.cost) },
	}
end

return Rules
