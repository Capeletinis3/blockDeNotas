--!strict
--[[
	Reglas derivadas de una partida: calendario, capacidades de la sede, tecnologías, producción por lotes,
	mercado (atractivo, rivales y reparto de la demanda), investigación, misiones y finanzas.
	Son funciones puras: el servidor las usa para simular y validar, y el cliente para mostrar exactamente
	las mismas cifras (ventas por minuto, cuota, PI por minuto…). Ninguna modifica la partida.
]]

local Catalog = require(script.Parent.Catalog)
local Util = require(script.Parent.Util)
local Staff = require(script.Parent.Staff)

local Rules = {}

local ECON = Catalog.ECON
local DAY = Catalog.RULES.gameDayMinutes -- minutos de juego de un día
local GAME_MIN_PER_REAL_MIN = Catalog.RULES.minutesPerRealSecond * 60 -- 600

function Rules.has(g: any, researchId: string?): boolean
	if not researchId then
		return true
	end
	return g ~= nil and g.research ~= nil and Util.contains(g.research.done, researchId)
end

Util.setCalendar(Catalog.CALENDAR.startYear, Catalog.CALENDAR.endYear, DAY)

-- Calendario ------------------------------------------------------------------------

-- Año histórico visible (tecnologías, demanda, rivales, año de modelo). Se detiene en el último año con
-- contenido (Catalog.CALENDAR.endYear); después el juego sigue en años comerciales extra.
function Rules.year(g: any): number
	return math.min(Catalog.CALENDAR.endYear, Catalog.CALENDAR.startYear + math.floor(g.time.day / 12))
end

-- Año con decimales (para curvas de demanda y la expectativa del mercado), con el mismo tope.
function Rules.yearFrac(g: any): number
	return math.min(Catalog.CALENDAR.endYear + 0.99, Catalog.CALENDAR.startYear + (g.time.day + g.time.minute / Rules.monthMinutes(g.time.day)) / 12)
end

-- Año comercial interno (sin tope): numera los años para las misiones anuales también después de endYear.
function Rules.periodYear(g: any): number
	return Catalog.CALENDAR.startYear + math.floor(g.time.day / 12)
end

-- ¿Se puede lanzar una nueva generación de este diseño? Hace falta un año de modelo posterior o, después del
-- último año histórico (cuando el año visible ya no cambia), que haya pasado al menos un año comercial.
function Rules.canNewGeneration(g: any, parent: any): boolean
	if (parent.modelYear or Rules.year(g)) < Rules.year(g) then
		return true
	end
	return Rules.extraYears(g) > 0 and g.time.day - (parent.createdDay or 0) >= 12
end

-- Años comerciales extra jugados después del último año histórico.
function Rules.extraYears(g: any): number
	return math.max(0, Rules.periodYear(g) - Catalog.CALENDAR.endYear)
end

-- Minutos de juego que dura el mes `month` (sus días reales × minutos por día).
function Rules.monthMinutes(month: number): number
	return Util.daysInMonth(month) * DAY
end

-- Días transcurridos desde el 1/1 del año inicial hasta el comienzo del mes `month`.
function Rules.daysBeforeMonth(month: number): number
	local years = month // 12
	local y0 = Catalog.CALENDAR.startYear
	local leaps = 0
	for y = y0, y0 + years - 1 do
		if Util.isLeapYear(y) then
			leaps += 1
		end
	end
	local days = years * 365 + leaps
	for m = years * 12, month - 1 do
		days += Util.daysInMonth(m)
	end
	return days
end

-- Día absoluto de la partida (0 = 01/01/1970) y fecha visible.
function Rules.absDay(g: any): number
	return Rules.daysBeforeMonth(g.time.day) + g.time.minute // DAY
end
function Rules.date(g: any): string
	return Util.fullDate(g.time.day, g.time.minute)
end

function Rules.absMinute(g: any): number
	return Rules.daysBeforeMonth(g.time.day) * DAY + g.time.minute
end

-- Minutos de juego → minutos reales a velocidad 1×.
function Rules.realMinutes(gameMinutes: number): number
	return gameMinutes / GAME_MIN_PER_REAL_MIN
end

-- Deuda total de la empresa (suma de los saldos de sus préstamos).
function Rules.debt(g: any): number
	local n = 0
	for _, l in g.loans or {} do
		n += l.balance or 0
	end
	return n
end

-- Sede y capacidades ---------------------------------------------------------------------

-- ¿La empresa tiene la línea de producción n? La 1 viene siempre; la 2 se compra con dinero del juego (por
-- empresa: g.facilities.lines["2"]) y la 3 es de la CUENTA (compra con Robux): el servidor la refleja en cada
-- empresa como g.facilities.accountLine3 (GameState.applyAccount). lines["3"] solo existe en partidas migradas
-- que ya tenían 3 líneas antes de que la línea 3 fuera de Robux.
function Rules.ownsLine(g: any, n: number): boolean
	if n == 1 then
		return true
	end
	local f = g.facilities
	if type(f) ~= "table" then
		return false
	end
	if n == 3 and f.accountLine3 == true then
		return true
	end
	return type(f.lines) == "table" and f.lines[tostring(n)] == true
end

function Rules.sede(g: any): any
	return Catalog.SEDES[Util.clamp(g.sede or 1, 1, #Catalog.SEDES)]
end

-- Suma de los efectos de las tecnologías investigadas (Catalog.RESEARCH … fx).
-- Suma de los efectos de las tecnologías investigadas y de la fábrica (FACILITIES.factory.levels[n].fx).
function Rules.tech(g: any, key: string): number
	local n = 0
	local f = g and g.facilities
	local lvl = type(f) == "table" and tonumber(f.factory) or 1
	local def = Catalog.FACILITIES.factory.levels[math.clamp(lvl, 1, 5)]
	if def and def.fx and def.fx[key] then
		n += def.fx[key]
	end
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

-- Bonificación de personal de una habilidad (Catalog.STAFF.skills), ya con su tope.
function Rules.staff(g: any, skillId: string): number
	return Staff.bonus(g, skillId)
end

function Rules.salaries(g: any): number
	return Staff.salaries(g)
end

-- Nivel de las oficinas centrales (g.sede: límite de empleados, alcance y niveles de capacitación).
function Rules.officeLevel(g: any): number
	return g.sede or 1
end

-- Instalaciones -----------------------------------------------------------------------------

-- Nivel actual de una instalación ("offices" | "factory" | "research").
function Rules.facilityLevel(g: any, kind: string): number
	if kind == "offices" then
		return g.sede or 1
	end
	local f = g.facilities
	return (type(f) == "table" and tonumber(f[kind])) or 1
end

-- Datos del nivel n (o del actual) de una instalación.
function Rules.facilityDef(kind: string, n: number): any
	if kind == "offices" then
		return Catalog.SEDES[n]
	end
	local F = Catalog.FACILITIES[kind]
	return F and F.levels and F.levels[n] or nil
end

function Rules.factory(g: any): any
	return Rules.facilityDef("factory", Util.clamp(Rules.facilityLevel(g, "factory"), 1, 5))
end

function Rules.researchCenter(g: any): any
	return Rules.facilityDef("research", Util.clamp(Rules.facilityLevel(g, "research"), 1, 5))
end

-- Líneas de producción que tiene la empresa (1 + la 2 comprada + la 3 de Robux).
function Rules.lineCount(g: any): number
	local n = 1
	for i = 2, Catalog.FACILITIES.maxLines do
		if Rules.ownsLine(g, i) then
			n += 1
		end
	end
	return n
end

-- Obra en curso de una instalación (o nil).
function Rules.build(g: any, kind: string): any
	for _, b in (type(g.facilities) == "table" and g.facilities.builds) or {} do
		if b.kind == kind then
			return b
		end
	end
	return nil
end

-- Costo con la gestión del personal de Administración (expansiones más baratas).
function Rules.expansionCost(g: any, cost: number): number
	return Util.round(cost * (1 - Rules.staff(g, "gestion")) / 100) * 100
end

-- Próxima mejora de una instalación: { kind, level, name, cost, days, def } o nil si no hay más.
function Rules.nextFacility(g: any, kind: string): any
	if kind == "line2" then
		if Rules.ownsLine(g, 2) then
			return nil
		end
		local L = Catalog.FACILITIES.line2
		return { kind = kind, level = 2, name = L.name, cost = Rules.expansionCost(g, L.cost), days = L.days }
	end
	local n = Rules.facilityLevel(g, kind) + 1
	local def = Rules.facilityDef(kind, n)
	if not def then
		return nil
	end
	return { kind = kind, level = n, name = kind == "offices" and (def.office .. " · " .. def.name) or def.name, cost = Rules.expansionCost(g, def.cost), days = def.days, def = def }
end

-- Requisitos de la próxima mejora: { { cumplido, texto } }.
function Rules.facilityChecks(g: any, kind: string): { any }
	local nx = Rules.nextFacility(g, kind)
	if not nx then
		return {}
	end
	local out = {}
	if kind == "offices" then
		table.insert(out, { g.counters.unitsSold >= nx.def.req.sold, "Autos vendidos: " .. Util.num(g.counters.unitsSold) .. "/" .. Util.num(nx.def.req.sold) })
		table.insert(out, { g.reputation >= nx.def.req.rep, "Reputación: " .. Util.num(g.reputation, 1) .. "/" .. Util.num(nx.def.req.rep, 1) })
	elseif kind ~= "line2" then
		table.insert(out, { nx.level <= Rules.officeLevel(g), "Oficinas centrales de nivel " .. nx.level })
	end
	table.insert(out, { Rules.build(g, kind) == nil, "Sin otra obra en curso en esta instalación" })
	table.insert(out, { g.money >= nx.cost, "Dinero: " .. Util.money(g.money) .. " / " .. Util.money(nx.cost) })
	return out
end

-- Días de obra que avanza cada día de juego (organización del personal de Administración).
function Rules.buildSpeed(g: any): number
	return 1 + Rules.staff(g, "organizacion")
end

-- Lo invertido en instalaciones (base del mantenimiento mensual).
function Rules.facilitiesValue(g: any): number
	local v = 0
	for _, kind in Catalog.FACILITIES.order do
		for n = 2, Rules.facilityLevel(g, kind) do
			local def = Rules.facilityDef(kind, n)
			v += def and def.cost or 0
		end
	end
	if Rules.ownsLine(g, 2) then
		v += Catalog.FACILITIES.line2.cost
	end
	return v
end

-- Mantenimiento mensual: un porcentaje de lo invertido en obras (g.facilities.invested); la eficiencia
-- financiera del personal de Administración lo reduce.
function Rules.maintenance(g: any): number
	local f = g.facilities
	local invested = (type(f) == "table" and tonumber(f.invested)) or 0
	return Util.round(invested * Catalog.FACILITIES.maintenanceRate * (1 - Rules.staff(g, "finanzas")))
end

-- Costo por unidad de un lote nuevo: el del diseño menos la eficiencia de Producción.
function Rules.lotUnitCost(g: any, unitCost: number): number
	return math.max(1, Util.round(unitCost * (1 - Rules.staff(g, "eficiencia"))))
end

-- Nivel máximo de las estaciones: 2 por nivel de sede (hasta 10 con el Imperio automotriz).
function Rules.maxStationLevel(g: any): number
	return math.min(10, Rules.facilityLevel(g, "factory") * 2)
end

function Rules.upgradeCost(s: any): number
	return Util.round(5000 * math.pow(2.6, s.level - 1) / 100) * 100
end

-- Multiplicador de la fábrica: mejoras de estaciones, tecnología y velocidad del personal de Producción
-- (se aplica enseguida también a los lotes en curso).
function Rules.factoryMult(g: any): number
	local levels = 0
	for _, st in Catalog.STATIONS do
		levels += (g.stations[st[1]].level - 1)
	end
	return (1 + Catalog.STATION_SPEED * levels) * (1 + Rules.tech(g, "prodSpeed") / 100) * (1 + Rules.staff(g, "velocidad"))
end

-- Expansión global (después de la sede máxima) ---------------------------------------------

function Rules.expansion(g: any): number
	return tonumber(g.expansion) or 0
end

-- Tamaño del mercado mundial al que llegás: +15 % de demanda por región abierta.
function Rules.marketFactor(g: any): number
	return 1 + Catalog.EXPANSION.demand * Rules.expansion(g)
end

-- Alcance comercial de la sede.
function Rules.reach(g: any): number
	return Rules.sede(g).reach
end

-- País del catálogo por id (o nil).
function Rules.country(id: any): any
	for _, c in Catalog.EXPANSION.countries do
		if c.id == id then
			return c
		end
	end
	return nil
end

-- Países abiertos (ids, en el orden en que se abrieron). g.countries guarda los elegidos; si una partida
-- vieja solo tiene la cantidad (g.expansion), se completan con los primeros del catálogo.
function Rules.openedCountries(g: any): { string }
	local out, seen = {}, {}
	for _, id in (type(g.countries) == "table" and g.countries) or {} do
		if Rules.country(id) and not seen[id] and #out < Rules.expansion(g) then
			table.insert(out, id)
			seen[id] = true
		end
	end
	for _, c in Catalog.EXPANSION.countries do
		if #out >= Rules.expansion(g) then
			break
		end
		if not seen[c.id] then
			table.insert(out, c.id)
			seen[c.id] = true
		end
	end
	return out
end

function Rules.countryOpen(g: any, id: string): boolean
	return table.find(Rules.openedCountries(g), id) ~= nil
end

-- Próxima apertura (el jugador elige el país): { level, name, cost, sold } o nil (sin Imperio o con todos
-- abiertos). El costo y las ventas pedidas dependen de cuántos países van, no de cuál se elige.
function Rules.nextExpansion(g: any): any
	local E = Catalog.EXPANSION
	local n = Rules.expansion(g) + 1
	if Rules.nextSede(g) ~= nil or n > #E.countries then
		return nil
	end
	return { level = n, name = "un país a elección", cost = Rules.expansionCost(g, Util.round(E.cost * math.pow(E.growth, n - 1) / 1000000) * 1000000), sold = E.soldBase + E.soldStep * (n - 1) }
end

function Rules.expansionChecks(g: any): { any }
	local nx = Rules.nextExpansion(g)
	if not nx then
		return {}
	end
	return {
		{ g.counters.unitsSold >= nx.sold, "Autos vendidos: " .. Util.num(g.counters.unitsSold) .. "/" .. Util.num(nx.sold) },
		{ g.money >= nx.cost, "Dinero: " .. Util.money(g.money) .. " / " .. Util.money(nx.cost) },
	}
end

-- Autos por minuto real que fabrica cada línea a 1×.
function Rules.lineRate(g: any): number
	return Rules.factory(g).perLine * Rules.factoryMult(g) * (1 + Catalog.EXPANSION.line * Rules.expansion(g))
end

function Rules.caps(g: any): any
	local s = Rules.sede(g)
	local lines = Rules.lineCount(g)
	return {
		lines = lines,
		perLine = Rules.lineRate(g),
		capacity = Rules.lineRate(g) * lines,
		reach = Rules.reach(g),
		staff = s.staff,
		pi = Rules.researchCenter(g).pi,
	}
end

--[[ Puntos de investigación (PI), por minuto real a 1× (2× y 3× multiplican el tiempo simulado):
	- Centro de investigación: lo que genera la sede (su nivel crecerá con las mejoras del centro).
	- Líneas de fabricación: cada línea que está fabricando suma RESEARCH_RULES.linePi, sin importar el auto.
	El personal no suma PI por minuto (ver Rules.researchModifiers). ]]
function Rules.piCenter(g: any): number
	return Rules.researchCenter(g).pi
end

function Rules.activeLines(g: any): number
	local n = 0
	for _, lot in Rules.producingLots(g) do
		if lot.prodState == "produciendo" then
			n += 1
		end
	end
	return n
end

function Rules.piLines(g: any): number
	return Rules.activeLines(g) * Catalog.RESEARCH_RULES.linePi
end

function Rules.piPerMinute(g: any): number
	return Rules.piCenter(g) + Rules.piLines(g)
end

-- Sin tope de acumulación de PI (se conserva por compatibilidad con pantallas y pruebas anteriores).
function Rules.piCap(_g: any): number
	return math.huge
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

--[[ Líneas de producción: cada lote con fabricación pendiente ocupa UNA línea (lot.line) hasta completarse.
	No hay cola manual, pausa ni cancelación: la línea termina el lote. ]]
function Rules.lineLot(g: any, n: number): any
	for _, lot in g.lots do
		if lot.line == n and Rules.lotProducing(lot) then
			return lot
		end
	end
	return nil
end

-- Primera línea propia y libre (o nil si todas están ocupadas).
function Rules.freeLine(g: any): number?
	for n = 1, Catalog.FACILITIES.maxLines do
		if Rules.ownsLine(g, n) and not Rules.lineLot(g, n) then
			return n
		end
	end
	return nil
end

-- Lotes de partidas anteriores sin línea (había una cola): toman las líneas que se liberan, en orden.
function Rules.assignLines(g: any)
	for _, lot in g.lots do
		if Rules.lotProducing(lot) and lot.line == nil then
			local n = Rules.freeLine(g)
			if not n then
				return
			end
			lot.line = n
		end
	end
end

-- Lotes que se fabrican en este momento (los que tienen una línea propia asignada), por número de línea.
function Rules.producingLots(g: any): { any }
	local out = {}
	for n = 1, Catalog.FACILITIES.maxLines do
		local lot = Rules.lineLot(g, n)
		if lot and Rules.ownsLine(g, n) then
			table.insert(out, lot)
		end
	end
	return out
end

-- Avance general del lote (0–1). Con la fabricación avanzada (futura) se podrá desglosar en fases.
function Rules.lotProgress(lot: any): number
	if lot.qty <= 0 then
		return 1
	end
	return Util.clamp((lot.produced + (lot.prodProgress or 0)) / lot.qty, 0, 1)
end

-- Días de juego que faltan para terminar el lote con la velocidad de línea actual (fábrica, estaciones,
-- tecnología, personal y expansión). Se recalcula solo si cambian las bonificaciones; el avance no se pierde.
function Rules.lotDaysLeft(g: any, lot: any): number
	local left = math.max(0, lot.qty - lot.produced - (lot.prodProgress or 0))
	return Rules.daysFor(g, left)
end

-- Días de juego para fabricar `units` unidades en una línea (1 día = realSecondsPerDay s reales a 1×).
function Rules.daysFor(g: any, units: number): number
	local rate = Rules.lineRate(g) -- autos por minuto real a 1×
	if rate <= 0 then
		return math.huge
	end
	return units / rate * 60 / Catalog.CALENDAR.realSecondsPerDay
end

-- Bonificaciones de fabricación vigentes (para mostrarlas; los cálculos usan Rules.lineRate y lotUnitCost).
function Rules.productionBonuses(g: any): { any }
	local out = {}
	local levels = 0
	for _, st in Catalog.STATIONS do
		levels += (g.stations[st[1]].level - 1)
	end
	if levels > 0 then
		table.insert(out, { "Estaciones mejoradas", "+" .. Util.round(Catalog.STATION_SPEED * levels * 100) .. " % de velocidad" })
	end
	local tech = Rules.tech(g, "prodSpeed")
	if tech > 0 then
		table.insert(out, { "Tecnología de producción", "+" .. Util.round(tech) .. " % de velocidad" })
	end
	local vel = Rules.staff(g, "velocidad")
	if vel > 0 then
		table.insert(out, { "Personal de Producción (velocidad)", "+" .. Util.round(vel * 100) .. " % de velocidad" })
	end
	local exp = Catalog.EXPANSION.line * Rules.expansion(g)
	if exp > 0 then
		table.insert(out, { "Expansión internacional", "+" .. Util.round(exp * 100) .. " % de velocidad" })
	end
	local eff = Rules.staff(g, "eficiencia")
	if eff > 0 then
		table.insert(out, { "Personal de Producción (eficiencia)", "−" .. Util.round(eff * 100) .. " % de costo por unidad" })
	end
	local q = Rules.staff(g, "calidad")
	if q > 0 then
		table.insert(out, { "Personal de Producción (calidad)", "+" .. Util.num(q, 1) .. " de calidad al terminar" })
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
	-- Prestaciones: aceleración (70 %) y velocidad máxima (30 %). Seguridad: protección (85 %) y frenado (15 %).
	local accelIdx = Util.clamp(100 * (1 - (calc.accel - 4) / 12), 0, 100)
	local topIdx = Util.clamp(((calc.top or 150) - 120) / 2.2, 0, 100)
	local brakeIdx = Util.clamp(100 - ((calc.stop or 45) - 30) * 3, 0, 100)
	return {
		power = accelIdx * 0.7 + topIdx * 0.3,
		eco = eco,
		comfort = calc.comfort,
		safety = (calc.safety or 40) * 0.85 + brakeIdx * 0.15,
		dur = calc.durability,
		hand = calc.handling,
		quality = calc.quality,
	}
end

-- Reseñas de los críticos ---------------------------------------------------------------------

-- Multiplicador de demanda por las reseñas (1 sin reseñas: lotes de versiones anteriores).
function Rules.reviewFactor(lot: any): number
	local rv = lot.review
	if type(rv) ~= "table" or type(rv.avg) ~= "number" then
		return 1
	end
	return Util.clamp(math.pow(rv.avg / 6, ECON.reviewElasticity), 0.3, 2)
end

-- Variación propia de cada crítico para cada modelo (−0,3 a +0,3), fija: depende solo del modelo y del crítico.
local function criticOffset(key: string): number
	local h = 7
	for i = 1, #key do
		h = (h * 31 + string.byte(key, i)) % 1000003
	end
	return ((h % 7) - 3) / 10
end

local REVIEW_TEXT = {
	familia = {
		"Un acierto para las familias: %s está entre lo mejor de %d.",
		"Cumple como auto familiar, aunque %s podría estar mejor.",
		"Cuesta recomendarlo para la familia: %s queda muy atrás.",
	},
	pista = {
		"Pura emoción: %s deja atrás a la competencia de %d.",
		"Correcto en la ruta, pero %s no entusiasma.",
		"Sin chispa: %s decepciona a cualquier conductor.",
	},
	bolsillo = {
		"Una compra inteligente: %s cuida el bolsillo como pocos en %d.",
		"Razonable, aunque %s pesa en el presupuesto.",
		"Difícil de justificar: %s no convence.",
	},
	tendencias = {
		"Bien terminado y moderno: %s marca tendencia en %d.",
		"Prolijo, aunque %s ya se ve de otra época.",
		"Se nota anticuado: %s no está a la altura.",
	},
}

--[[ Reseñas de un auto terminado: { avg, scores = { { critic, name, outlet, score, text }… }, year }.
	Dependen de las estadísticas reales del diseño (calc), su nivel tecnológico frente al año y la calidad;
	no hay azar. Se calculan una vez (Simulation.reviewLot) y se guardan en el lote y en el historial. ]]
function Rules.criticReviews(g: any, design: any): any
	local calc, spec = design.calc, design.spec
	local yf = Rules.yearFrac(g)
	local year = Rules.year(g)
	local idx = Rules.indices(calc)
	-- Diferencia de cada aspecto con lo que se espera de un auto de la época (positivo = mejor).
	local dev = {}
	for k, curve in Catalog.CRITIC_EXPECT do
		dev[k] = (idx[k] or 50) - Catalog.interp(curve, yf)
	end
	-- Tecnología: cuántos años atrás quedó cada pieza frente a la más nueva que la empresa YA podía usar en esa
	-- categoría (existente en el año, investigada y compatible con la base). Elegir lo último suma; quedarse con
	-- piezas viejas teniendo mejores, resta.
	local base = Catalog.base(spec.baseId)
	local lag, n = 0, 0
	for cat, id in spec.parts or {} do
		local p = Catalog.part(cat, id)
		if p then
			local top = p.year or year
			for _, x in Catalog.partsOf(cat) do
				local usable = (x.year or 1970) <= year and (x.research == nil or Rules.has(g, x.research))
					and (x.need == nil or (base ~= nil and Util.contains(base.tags, x.need)))
				if usable and x.year > top then
					top = x.year
				end
			end
			lag += math.min(15, top - (p.year or year))
			n += 1
		end
	end
	dev.tech = 6 - 1.5 * (n > 0 and lag / n or 0)
	-- Relación entre lo que ofrece y lo que cuesta fabricarlo, frente al precio habitual del tipo.
	local fair = Rules.fairPrice(design.type, yf, 0)
	dev.value = -(calc.unitCost / math.max(1, fair) - 0.65) * 50 + (dev.quality or 0) * 0.3
	local scores = {}
	local sum = 0
	for _, c in Catalog.CRITICS do
		local raw, best, worst, bv, wv = 0, nil, nil, -math.huge, math.huge
		for k, w in c.weights do
			local v = dev[k] or 0
			raw += v * w
			if v > bv then
				best, bv = k, v
			end
			if v < wv then
				worst, wv = k, v
			end
		end
		local score = Util.clamp(6 + raw / ECON.reviewScale + criticOffset(tostring(design.id) .. ":" .. c.id), 1, 10)
		score = math.floor(score * 10 + 0.5) / 10
		local t = REVIEW_TEXT[c.id] or REVIEW_TEXT.familia
		local text
		if score >= 7.5 then
			text = string.format(t[1], Catalog.CRITIC_ASPECTS[best :: string], year)
		elseif score >= 5 then
			text = string.format(t[2], Catalog.CRITIC_ASPECTS[worst :: string])
		else
			text = string.format(t[3], Catalog.CRITIC_ASPECTS[worst :: string])
		end
		table.insert(scores, { critic = c.id, name = c.name, outlet = c.outlet, score = score, text = text })
		sum += score
	end
	return { avg = math.floor(sum / #scores * 10 + 0.5) / 10, scores = scores, year = year }
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

-- Demanda total del tipo este año (autos/min real). Igual para todas las empresas.
function Rules.demand(g: any, type: string, yearFrac: number?): number
	local curve = Catalog.DEMAND[type]
	if not curve then
		return 0
	end
	return Catalog.interp(curve, yearFrac or Rules.yearFrac(g)) * Rules.marketFactor(g)
end

-- Precio justo de un auto de ese tipo, ese año y ese atractivo (referencia de los rivales).
function Rules.fairPrice(type: string, yearFrac: number, appealOverBaseline: number): number
	return (Catalog.RIVAL_PRICE[type] or 4000) * (1 + appealOverBaseline * 0.03) * (1 + (yearFrac - 1970) * 0.006)
end

--[[ Modelos rivales que se venden este año en ese tipo: { rival, name, gen, since, appeal, price, fair,
	segment, reach, weight, launched }. Con `g` los rivales reaccionan a la cuota que tu empresa tuvo el
	último tiempo en ese tipo (g.marketShare) bajando precios según su estrategia. El peso en el reparto se
	calcula con las mismas reglas que tus lotes: atractivo, precio frente a su precio justo y alcance. ]]
function Rules.rivalOffers(type: string, yearFrac: number, g: any?): { any }
	local out = {}
	local baseline = Rules.eraBaseline(yearFrac)
	local share = g and g.marketShare and g.marketShare[type] or 0
	for i, r in Catalog.RIVALS do
		local since = r.types[type]
		if since and yearFrac >= since then
			-- Generación nueva cada `cycle` años: sale mejor que el promedio y envejece hasta la próxima.
			local cycle = r.cycle or 6
			local age = yearFrac - since
			local gen = math.floor(age / cycle) + 1
			local phase = (age % cycle) / cycle
			local offset = Catalog.interp(r.offset, yearFrac) + 2 - phase * 4 + math.sin(i * 1.7 + gen) * 1.2
			local appeal = baseline + offset
			local fair = Rules.fairPrice(type, yearFrac, offset)
			local cut = math.min(0.25, (r.react or 0) * math.max(0, share - 0.15))
			local price = math.floor(fair * (r.price or 1) * (1 - cut) / 10 + 0.5) * 10
			local reach = Catalog.interp(r.reach or { { 1970, 1 } }, yearFrac)
			local seg = (r.price or 1) >= 1.1 and "Premium" or ((r.price or 1) <= 0.9 and "Económico" or "Masivo")
			table.insert(out, {
				rival = r,
				name = r.models[type] .. (gen > 1 and (" '" .. string.sub(tostring(math.floor(since + (gen - 1) * cycle)), 3)) or ""),
				since = since,
				gen = gen,
				launched = math.floor(since + (gen - 1) * cycle),
				segment = seg,
				price = price,
				fair = fair,
				cut = cut,
				appeal = appeal,
				reach = reach,
				weight = math.exp((appeal - baseline) / ECON.appealScale) * Rules.priceFactor(price, fair, type) * reach,
			})
		end
	end
	return out
end

-- Marketing --------------------------------------------------------------------------------

-- Campaña activa (g.campaign) o nil.
function Rules.campaign(g: any): any
	return type(g.campaign) == "table" and g.campaign or nil
end

function Rules.marketingEra(g: any): number
	return Catalog.interp(Catalog.MARKETING.era, Rules.year(g))
end

-- Modelos con lote en venta (la campaña corporativa cuesta más cuantos más haya).
function Rules.modelsOnSale(g: any): number
	local seen, n = {}, 0
	for _, l in g.lots do
		if l.saleState == "en venta" and not seen[l.designId] then
			seen[l.designId] = true
			n += 1
		end
	end
	return n
end

--[[ Plan de una campaña: lo muestra la interfaz y lo cobra el servidor (mismo cálculo).
	req = { kind, designId?, budget (mensual), days }. Devuelve { cost, boost, days, kind, designId, name } o
	(nil, motivo). boost = efecto base; la creatividad del personal de Marketing lo multiplica en vivo. ]]
function Rules.campaignPlan(g: any, req: any): (any?, string?)
	local MK = Catalog.MARKETING
	if type(req) ~= "table" then
		return nil, "Datos de la campaña inválidos."
	end
	local kind = MK.kinds[req.kind]
	if not kind then
		return nil, "Elegí el tipo de campaña."
	end
	local era = Rules.marketingEra(g)
	local lo, hi = Util.round(MK.budgetMin * era), Util.round(MK.budgetMax * era)
	local budget, days = req.budget, req.days
	if not Util.isFiniteNumber(budget) or budget < lo or budget > hi then
		return nil, "El presupuesto mensual tiene que estar entre " .. Util.money(lo) .. " y " .. Util.money(hi) .. "."
	end
	if not Util.isFiniteNumber(days) or days ~= math.floor(days) or days < MK.daysMin or days > MK.daysMax then
		return nil, "La duración tiene que estar entre " .. MK.daysMin .. " y " .. MK.daysMax .. " días."
	end
	local name
	if req.kind == "modelo" then
		for _, l in g.lots do
			if l.designId == req.designId and l.saleState ~= "agotado" and l.saleState ~= "retirado" then
				name = l.design.name
			end
		end
		if not name then
			return nil, "Elegí un modelo que esté en fabricación o a la venta."
		end
	else
		name = g.company.name
	end
	local cost = budget * days / 30
	if req.kind == "corporativa" then
		cost *= (1 + kind.sizeCost * (Rules.officeLevel(g) - 1) + kind.perModelCost * Rules.modelsOnSale(g)) * Rules.marketFactor(g)
	end
	cost = Util.round(cost * (1 - Rules.staff(g, "analisis")) / 10) * 10
	local boost = kind.maxBoost * (1 - math.exp(-budget / (MK.budgetRef * era)))
	return { cost = cost, boost = boost, days = days, kind = req.kind, designId = req.kind == "modelo" and req.designId or nil, name = name, budget = budget, min = lo, max = hi }, nil
end

-- Efecto actual de la campaña (con la creatividad del personal de Marketing, en vivo).
function Rules.campaignBoost(g: any): number
	local c = Rules.campaign(g)
	return c and c.boost * (1 + Rules.staff(g, "mk_creatividad")) or 0
end

-- Multiplicador de demanda de un lote por la campaña activa (modelo: solo ese; corporativa: todos).
function Rules.campaignMult(g: any, lot: any): number
	local c = Rules.campaign(g)
	if not c or (c.kind == "modelo" and c.designId ~= lot.designId) then
		return 1
	end
	return 1 + Rules.campaignBoost(g)
end

-- Días de campaña que avanza cada día de juego (comunicación: la campaña dura más).
function Rules.campaignSpeed(g: any): number
	return 1 / (1 + Rules.staff(g, "comunicacion"))
end

-- Multiplicador comercial de la empresa: alcance × reputación × tecnologías (la campaña va por lote).
function Rules.playerMult(g: any): number
	local rep = 0.6 + g.reputation * 0.14
	local tech = 1 + Rules.tech(g, "demand") / 100
	return Rules.reach(g) * rep * tech
end

-- Factor de precio: vender por encima del precio de referencia baja las ventas (y al revés). Cada tipo
-- tiene su sensibilidad (ECON.typeElasticity).
function Rules.priceFactor(price: number, ref: number, type: string?): number
	local e = type and ECON.typeElasticity[type] or ECON.priceElasticity
	return Util.clamp(math.pow(ref / math.max(1, price), e), 0.02, 3)
end

-- Precio de venta: libre (por encima o por debajo del costo). Solo se exige un número entero de dólares,
-- positivo, finito y por debajo del tope técnico. Se conserva la firma (mínimo, máximo) por compatibilidad.
function Rules.priceRange(_unitCost: number?, _refPrice: number?): (number, number)
	return 1, ECON.priceCap
end

-- Precio válido redondeado al dólar, o nil (el cliente no envía precios inválidos; el servidor lo vuelve a revisar).
function Rules.validPrice(p: any): number?
	if not Util.isFiniteNumber(p) then
		return nil
	end
	local r = Util.round(p)
	if r < 1 or r > ECON.priceCap then
		return nil
	end
	return r
end

-- Peso de un lote del jugador en el reparto de la demanda de su tipo.
function Rules.lotWeight(g: any, lot: any, yearFrac: number): number
	local baseline = Rules.eraBaseline(yearFrac)
	local seg = Catalog.SEGMENTS[lot.design.spec.segment] or Catalog.SEGMENTS.Masivo
	return math.exp((lot.appeal - baseline) / ECON.appealScale) * Rules.priceFactor(lot.price, lot.refPrice, lot.design.type) * Rules.playerMult(g) * seg.pop * Rules.reviewFactor(lot) * Rules.campaignMult(g, lot)
end

--[[ Reparto de la demanda de un tipo entre: el resto del mercado (peso fijo), los modelos rivales y los
	lotes del jugador en venta con stock. Devuelve { demand, total, outside, rivals = {…}, lots = { [id] = peso } }. ]]
function Rules.market(g: any, type: string): any
	local yf = Rules.yearFrac(g)
	local m = { demand = Rules.demand(g, type, yf), outside = ECON.outsideWeight, rivals = Rules.rivalOffers(type, yf, g), lots = {} }
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

--[[ Demanda estimada en cinco niveles (Catalog.DEMAND_LEVELS): peso comercial del lote con el precio indicado
	(el mismo de Rules.lotWeight: atractivo, precio frente a su referencia, reseñas, reputación, alcance,
	segmento y campaña) frente al peso promedio de los modelos rivales de su tipo este año. No da una cifra de
	ventas: la venta real la decide la simulación. Devuelve { level (1–5), label, ratio }. ]]
function Rules.demandInfo(g: any, lot: any, price: number?): any
	local yf = Rules.yearFrac(g)
	local saved = lot.price
	if price then
		lot.price = price
	end
	local w = Rules.lotWeight(g, lot, yf)
	lot.price = saved
	local sum, n = 0, 0
	for _, r in Rules.rivalOffers(lot.design.type, yf, g) do
		sum += r.weight
		n += 1
	end
	local ratio = w / (n > 0 and sum / n or 1)
	local level = 1
	for i, t in Catalog.DEMAND_LEVELS.thresholds do
		if ratio >= t then
			level = i + 1
		end
	end
	return { level = level, label = Catalog.DEMAND_LEVELS.labels[level], ratio = ratio }
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

--[[ Personal de Investigación: conocimiento reduce los PI, precisión el dinero (se aplican al empezar) y
	creatividad acelera el avance de los proyectos en curso (Rules.researchSpeed, en vivo). Nunca suman PI/min. ]]
function Rules.researchModifiers(g: any): any
	return { pi = 1 - Rules.staff(g, "conocimiento"), days = 1, money = 1 - Rules.staff(g, "precision") }
end

-- Días de proyecto que avanza cada día de juego (creatividad del personal de Investigación).
function Rules.researchSpeed(g: any): number
	return 1 / (1 - Rules.staff(g, "creatividad"))
end

-- Años de adelanto de una tecnología respecto del año actual (0 si ya apareció).
function Rules.researchAhead(g: any, n: any): number
	return math.max(0, n.year - Rules.year(g))
end

function Rules.researchMissing(g: any, n: any): { string }
	local m = {}
	local R = Catalog.RESEARCH_RULES
	if Rules.year(g) + R.aheadMaxYears < n.year then
		table.insert(m, "Se puede adelantar desde " .. (n.year - R.aheadMaxYears) .. " (aparece en " .. n.year .. ")")
	end
	for _, r in n.req do
		if not Rules.has(g, r) then
			table.insert(m, "Investigar «" .. Catalog.researchNode(r).name .. "»")
		end
	end
	return m
end

-- Proyecto en curso de una tecnología (o nil).
function Rules.researchProject(g: any, id: string): any
	for _, p in g.research.projects or {} do
		if p.id == id then
			return p
		end
	end
	return nil
end

function Rules.researchState(g: any, n: any): string
	if Rules.has(g, n.id) then
		return "hecha"
	end
	if Rules.researchProject(g, n.id) then
		return "activa"
	end
	return #Rules.researchMissing(g, n) > 0 and "bloqueada" or "disponible"
end

--[[ Costo de investigar `n` hoy: (PI, dinero, días, detalle). Parte del costo base por complejidad; las
	tecnologías viejas son más baratas (difusión) y las adelantadas pagan el recargo por año de adelanto
	(RESEARCH_RULES.aheadPi/aheadMoney/aheadDays). Es el mismo cálculo que muestra la tarjeta y que cobra el
	servidor. detalle = { ahead, diffusion } ]]
function Rules.researchCost(g: any, n: any): (number, number, number, any)
	local R = Catalog.RESEARCH_RULES
	local RR = Catalog.RULES
	local ahead = Rules.researchAhead(g, n)
	local age = Rules.year(g) - n.year - RR.diffusionGrace
	local diffusion = age > 0 and math.max(RR.diffusionFloor, 1 - RR.diffusionPerYear * age) or 1
	local mod = Rules.researchModifiers(g)
	local pi = math.max(1, math.floor(n.rp * diffusion * (1 + R.aheadPi * ahead) * mod.pi + 0.5))
	local money = math.floor(n.cost * diffusion * (1 + R.aheadMoney * ahead) * mod.money / 100 + 0.5) * 100
	local days = math.max(1, math.floor(n.days * (1 + R.aheadDays * ahead) * mod.days + 0.5))
	return pi, money, days, { ahead = ahead, diffusion = diffusion }
end

-- Segundos reales que le faltan a un proyecto a la velocidad indicada (1 día = realSecondsPerDay a 1×).
function Rules.projectSecondsLeft(p: any, speed: number?, g: any?): number
	local rate = g and Rules.researchSpeed(g) or 1
	return math.max(0, p.days - p.progress) / rate * Catalog.CALENDAR.realSecondsPerDay / math.max(1, speed or 1)
end

-- Motores: nivel máximo investigado de una familia (el 1 viene con el motor) y variantes disponibles.
function Rules.engineLevelMax(g: any, family: string?): number
	if not family then
		return 1
	end
	local lvl = 1
	for l = 2, Catalog.RESEARCH_RULES.engineMaxLevel do
		if Rules.has(g, "eng_" .. family .. "_" .. l) then
			lvl = l
		else
			break
		end
	end
	return lvl
end

function Rules.variantUnlocked(g: any, v: any): boolean
	return v ~= nil and (v.research == nil or Rules.has(g, v.research))
end

function Rules.equipmentUnlocked(g: any, e: any): boolean
	return e ~= nil and (e.research == nil or Rules.has(g, e.research))
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
	f.opex = { salarios = spent({ "salarios" }), promocion = spent({ "promocion" }), mantenimiento = spent({ "mantenimiento" }) }
	f.invest = { desarrollo = spent({ "desarrollo" }), investigacion = spent({ "investigacion" }), mejoras = spent({ "mejora", "sede" }), contratacion = spent({ "contratacion", "indemnizacion" }), capacitacion = spent({ "capacitacion" }) }
	f.net = f.cash
	f.opProfit = f.revenue - f.manufacturing - f.opex.salarios - f.opex.promocion - f.opex.mantenimiento
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
		return Util.round(m.goal * Rules.reach(g) * Rules.marketFactor(g))
	end
	return m.goal
end

function Rules.missionReward(g: any, m: any): any
	if m.goalScale == "reach" then
		local k = Rules.reach(g) * Rules.marketFactor(g)
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
	elseif m.counter == "expansion" then
		return Rules.expansion(g)
	elseif m.counter == "leaderTypes" then
		return Rules.leaderTypes(g)
	end
	return g.counters[m.counter] or 0
end

-- Tipos de vehículo en los que tu cuota (promedio móvil mensual, g.marketShare) es de al menos 35 %.
function Rules.leaderTypes(g: any): number
	local n = 0
	for _, share in g.marketShare or {} do
		if share >= 0.35 then
			n += 1
		end
	end
	return n
end

function Rules.missionKey(g: any, m: any): string
	return m.kind == "anual" and (m.id .. "@" .. Rules.periodYear(g)) or m.id
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
	return Rules.facilityChecks(g, "offices")
end

return Rules
