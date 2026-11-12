--!strict
--[[
	Simulación de la partida. Solo corre en el servidor.
	ctx = { rng: () -> number, notify: (kind, text) -> () }

	Cada paso de 10 minutos de juego (1 s real a 1×): reloj → cierre de mes (si corresponde) → producción de
	los lotes → ventas automáticas → investigación. Todo se lleva en contadores agregados: fabricar o vender
	50.000 autos solo cambia números, nunca crea registros por unidad.

	Producción: cada línea fabrica el lote que tiene asignado a `Rules.lineRate` autos por minuto real. Cada
	unidad se cobra al terminarla (costo fijado al lanzar el lote). Si no alcanza el dinero, el lote queda
	«sin fondos» y sigue solo cuando haya dinero. Al llegar a la cantidad encargada, la producción TERMINA:
	nunca se repite un lote ni se crean órdenes automáticas.

	Ventas: los autos terminados se venden solos al ritmo de `Rules.lotSalesRate` (demanda del tipo × parte que
	le toca al lote frente a los rivales). Nunca se vende más de lo fabricado. Un lote sin unidades pendientes
	ni stock pasa a «agotado» y deja la lista activa (queda en el historial).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local DesignCalc = require(Shared.DesignCalc)
local Rules = require(Shared.Rules)
local Staff = require(Shared.Staff)
local Office = require(Shared.Office)
local GameState = require(script.Parent.GameState)

local round = Util.round
local clamp = Util.clamp
local money = Util.money

local Simulation = {}

local function pick(ctx: any, list: { any }): any
	return list[math.floor(ctx.rng() * #list) + 1]
end
Simulation.pick = pick

-- Dinero ---------------------------------------------------------------------------

-- Movimiento con registro en el libro (eventos puntuales: diseño, investigación, sede…).
function Simulation.ledger(g: any, kind: string, amount: number, note: string)
	amount = round(amount)
	table.insert(g.ledger, { day = g.time.day, min = math.floor(g.time.minute), type = kind, amount = amount, note = note })
	local ds = GameState.day(g)
	ds.flow[kind] = (ds.flow[kind] or 0) + amount
	GameState.trim(g)
end

-- Movimiento continuo (fabricación y ventas): solo suma al agregado del mes, sin una línea por unidad.
local function flow(g: any, kind: string, amount: number)
	local ds = GameState.day(g)
	ds.flow[kind] = (ds.flow[kind] or 0) + amount
end

-- Cobra solo si alcanza; nunca deja el dinero en negativo.
function Simulation.spend(g: any, amount: number, kind: string, note: string): boolean
	amount = round(amount)
	if not (amount >= 0) or g.money < amount then
		return false
	end
	if amount == 0 then
		return true
	end
	g.money -= amount
	Simulation.ledger(g, kind, -amount, note)
	return true
end

-- ¿Alcanza el dinero para un gasto? (consulta; no descuenta nada)
function Simulation.canAfford(g: any, amount: number): boolean
	return type(amount) == "number" and amount == amount and amount >= 0 and g.money >= round(amount)
end

function Simulation.earn(g: any, amount: number, kind: string, note: string)
	amount = round(amount)
	if amount <= 0 then
		return
	end
	g.money += amount
	Simulation.ledger(g, kind, amount, note)
end

function Simulation.notify(g: any, ctx: any, kind: string, text: string, go: string?)
	table.insert(g.notifications, 1, { id = GameState.uid(g, "n"), kind = kind, text = text, go = go, read = false, day = g.time.day, at = Util.gameDate(g.time.day) })
	while #g.notifications > 40 do
		table.remove(g.notifications)
	end
	if ctx and ctx.notify then
		ctx.notify(kind, text)
	end
end

function Simulation.addXp(g: any, ctx: any, n: number)
	g.xp += n
	local up = false
	while g.xp >= Rules.xpForLevel(g.level) do
		g.xp -= Rules.xpForLevel(g.level)
		g.level += 1
		up = true
	end
	if up then
		Simulation.notify(g, ctx, "nivel", "¡Subiste al nivel " .. g.level .. "!", "compania")
	end
end

-- Suma PI generados (sin tope; los decimales se conservan para no perder precisión entre ticks cortos).
-- g.bankFull es un campo de versiones con banco de PI limitado: se borra para que nunca quede un aviso viejo.
function Simulation.addPi(g: any, n: number, _ctx: any?)
	g.bankFull = nil
	if n > 0 then
		g.rp += n
	end
end

--[[ PI por jugar (ventas, lotes agotados con ganancia, lanzamientos exitosos). Comparten un tope por mes
	(Catalog.ECON.bonusPiCapMinutes de la generación de la sede) para que no se puedan farmear repitiendo
	acciones baratas (desactivados desde la etapa 3: Catalog.ECON.bonusPiEnabled). No hay tope de acumulación.
	Devuelve los PI otorgados. ]]
function Simulation.bonusPi(g: any, amount: number): number
	-- Etapa 3: los PI salen solo del centro de investigación y de las líneas (y de las misiones).
	if not Catalog.ECON.bonusPiEnabled then
		return 0
	end
	local m = g.stats.month
	local cap = Rules.piPerMinute(g) * Catalog.ECON.bonusPiCapMinutes
	local give = math.max(0, math.min(amount, cap - (m.bonusPi or 0)))
	if give > 0 then
		m.bonusPi = (m.bonusPi or 0) + give
		g.rp += give
	end
	return give
end

-- Lotes ------------------------------------------------------------------------------

-- Copia independiente de la versión confirmada del diseño: configuración + valores calculados.
function Simulation.designSnapshot(g: any, d: any): any
	local c = DesignCalc.computeDesign(g, d)
	local base = Catalog.base(d.baseId)
	return {
		id = d.id,
		version = d.version or 1,
		name = d.name,
		brand = d.brand,
		baseId = d.baseId,
		type = base.type,
		gen = d.gen or 1,
		modelYear = d.modelYear or Rules.year(g),
		lineage = d.lineage or d.id,
		spec = Util.deepCopy(d),
		calc = Util.deepCopy(c),
	}
end

function Simulation.makeLot(g: any, snap: any, qty: number, price: number): any
	local appeal = Rules.appeal(snap.calc, snap.spec)
	return {
		id = GameState.uid(g, "l"),
		designId = snap.id,
		design = snap,
		qty = qty,
		produced = 0,
		sold = 0,
		discarded = 0,
		price = price,
		refPrice = snap.calc.price,
		unitCost = Rules.lotUnitCost(g, snap.calc.unitCost), -- con la eficiencia de Producción al ordenarlo
		appeal = appeal,
		revenue = 0,
		costSpent = 0,
		prodProgress = 0,
		saleAcc = 0,
		prodState = "cola",
		-- Se fabrica completo antes de vender: al terminar llegan las reseñas y el jugador lo pone a la venta.
		saleState = "produccion",
		createdDay = g.time.day,
		monthSold = 0,
		lastMonthSold = 0,
	}
end

-- Historial permanente: entrada del modelo y generación de este lote (se crea al lanzarlo).
function Simulation.registerModel(g: any, lot: any): any
	local e = GameState.modelEntry(g, lot)
	GameState.trim(g, e.key)
	return e
end

-- Saca un lote de la lista activa: suma sus números al historial permanente y guarda una versión liviana
-- en el historial reciente (más reciente primero; sin la copia completa del diseño).
function Simulation.archiveLot(g: any, lot: any)
	for i, l in g.lots do
		if l.id == lot.id then
			table.remove(g.lots, i)
			break
		end
	end
	lot.endDay = g.time.day
	lot.bestMonth = math.max(lot.bestMonth or 0, lot.monthSold or 0)
	-- Primero se suman los números y después se recorta (una entrada nueva tiene 0 ventas y no debe
	-- resumirse antes de recibirlos).
	local e = GameState.modelEntry(g, lot)
	local profit = lot.revenue - lot.costSpent
	e.lots += 1
	e.produced += lot.produced
	e.sold += lot.sold
	e.discarded += lot.discarded
	e.revenue += lot.revenue
	e.cost += lot.costSpent
	e.bestLotSold = math.max(e.bestLotSold, lot.sold)
	e.bestLotProfit = math.max(e.bestLotProfit, profit)
	e.bestMonth = math.max(e.bestMonth, lot.bestMonth)
	e.lastDay = g.time.day
	e.name = lot.design.name
	if lot.review then
		e.review = lot.review.avg
	end
	GameState.noteRecords(g, e, { name = lot.design.name, gen = lot.design.gen, sold = lot.sold, profit = profit, bestMonth = lot.bestMonth, day = g.time.day })
	table.insert(g.lotHistory, 1, GameState.slimLot(lot))
	GameState.trim(g, e.key)
end

function Simulation.stepProduction(g: any, ctx: any, minutes: number)
	-- Lotes de partidas anteriores que esperaban en la cola toman una línea en cuanto se libera.
	Rules.assignLines(g)
	local active = Rules.producingLots(g)
	local rate = Rules.lineRate(g) * Rules.realMinutes(minutes)
	local busy = {}
	for _, lot in active do
		busy[lot.id] = true
		local pending = lot.qty - lot.produced
		lot.prodProgress += rate
		local n = math.min(math.floor(lot.prodProgress), pending)
		if n > 0 and not lot.prepaid then
			-- Lotes de versiones anteriores: se cobra cada unidad al terminarla; si no alcanza, se fabrican
			-- solo las que se pueden pagar. (Los lotes nuevos se pagan completos al ordenarlos.)
			local affordable = lot.unitCost > 0 and math.floor(g.money / lot.unitCost) or n
			if affordable < n then
				n = affordable
			end
		end
		if n > 0 then
			if not lot.prepaid then
				local cost = n * lot.unitCost
				g.money -= cost
				flow(g, "fabricacion", -cost)
				lot.costSpent += cost
			end
			lot.produced += n
			lot.prodProgress -= n
			lot.prodState = "produciendo"
			g.counters.unitsProduced += n
			local ds = GameState.day(g)
			ds.produced = (ds.produced or 0) + n
			if lot.produced >= lot.qty then
				lot.prodState = "completado"
				lot.prodProgress = 0
				Simulation.addXp(g, ctx, 40)
				Simulation.reviewLot(g, ctx, lot)
			end
		elseif pending > 0 and lot.prodProgress >= 1 then
			-- Hay unidades listas para terminar pero no hay dinero: se pausa sin acumular más avance.
			lot.prodProgress = math.min(lot.prodProgress, 1)
			if lot.prodState ~= "sin fondos" then
				lot.prodState = "sin fondos"
				Simulation.notify(g, ctx, "aviso", "Producción de " .. lot.design.name .. " en pausa: no alcanza el dinero para la próxima unidad (" .. money(lot.unitCost) .. "). Sigue sola cuando entre dinero.", "fabrica")
			end
		else
			lot.prodState = "produciendo"
		end
	end
	-- Los demás lotes con producción pendiente (solo de partidas anteriores) esperan una línea libre.
	for _, lot in g.lots do
		if not busy[lot.id] and Rules.lotProducing(lot) then
			lot.prodState = "cola"
		end
	end
end

--[[ Fin de la fabricación: los cuatro críticos evalúan el auto (una sola vez; queda guardado) y el lote pasa a
	«por lanzar» hasta que el jugador fija el precio (Actions.launchSale). Un lote que ya estaba a la venta
	(partidas anteriores) no cambia de estado. ]]
function Simulation.reviewLot(g: any, ctx: any, lot: any)
	if lot.review == nil then
		-- Calidad de fabricación: el personal de Producción suma puntos al auto que se termina (una vez).
		local q = Rules.staff(g, "calidad")
		if q > 0 and lot.mfgQuality == nil then
			lot.mfgQuality = Util.round(q * 10) / 10
			lot.design.calc.quality = math.min(100, lot.design.calc.quality + lot.mfgQuality)
			lot.appeal = Rules.appeal(lot.design.calc, lot.design.spec)
		end
		lot.review = Rules.criticReviews(g, lot.design)
	end
	if lot.saleState == "produccion" then
		lot.saleState = "por lanzar"
		Simulation.notify(g, ctx, "ok", "Lote terminado: " .. Util.num(lot.produced) .. " × " .. lot.design.name .. ". Llegaron las reseñas (" .. Util.num(lot.review.avg, 1) .. "/10): elegí el precio y ponelo a la venta.", "ventas")
	else
		Simulation.notify(g, ctx, "ok", "Lote terminado: " .. Util.num(lot.qty) .. " × " .. lot.design.name .. ". La producción se detuvo.", "fabrica")
	end
end

function Simulation.stepSales(g: any, ctx: any, minutes: number)
	local markets = {}
	local realMin = Rules.realMinutes(minutes)
	local baseline = Rules.eraBaseline(Rules.yearFrac(g))
	local done = {}
	for _, lot in g.lots do
		if lot.saleState == "en venta" then
			local avail = Rules.lotAvailable(lot)
			local t = lot.design.type
			markets[t] = markets[t] or Rules.market(g, t)
			local rate = Rules.lotSalesRate(g, lot, markets[t])
			lot.saleAcc += rate * realMin
			local n = math.min(math.floor(lot.saleAcc), avail)
			if n > 0 then
				local firstSale = lot.sold == 0
				local revenue = n * lot.price
				g.money += revenue
				flow(g, "venta", revenue)
				Simulation.recoverSalaryDebt(g, ctx, revenue)
				lot.sold += n
				lot.revenue += revenue
				lot.saleAcc -= n
				lot.monthSold += n
				local ds = GameState.day(g)
				ds.revenue += revenue
				ds.cogs += n * lot.unitCost
				ds.units += n
				ds.margin += n * (lot.price - lot.unitCost)
				g.counters.unitsSold += n
				g.counters.revenueTotal = (g.counters.revenueTotal or 0) + revenue
				g.counters.marginTotal = (g.counters.marginTotal or 0) + n * (lot.price - lot.unitCost)
				g.stats.month.sold += n
				g.stats.month.rel += n * (lot.appeal - baseline)
				-- Primeras ventas del lote (una vez: el paso de 0 a más ventas solo ocurre una vez). Es un aviso breve
				-- en pantalla, sin guardarlo en la partida ni en las noticias. Si se agotó de golpe, alcanza con el aviso
				-- de agotado.
				if firstSale and Rules.lotAvailable(lot) > 0 and ctx and ctx.notify then
					ctx.notify("ok", "Primeras ventas de " .. lot.design.name .. ": " .. Util.num(lot.sold) .. (lot.sold == 1 and " auto" or " autos") .. " a " .. money(lot.price) .. ". Se sigue vendiendo solo; podés ajustar el precio en Ventas.")
				end
				-- Lanzamiento exitoso: la primera vez que un diseño llega a launchSold ventas (una vez por diseño).
				if lot.sold >= Catalog.ECON.launchSold and not g.launched[lot.designId] then
					g.launched[lot.designId] = true
					local pi = math.floor(Simulation.bonusPi(g, Rules.piPerMinute(g) * Catalog.ECON.launchPiMinutes))
					Simulation.notify(g, ctx, "ok", "Lanzamiento exitoso: " .. lot.design.name .. " llegó a " .. Catalog.ECON.launchSold .. " ventas." .. (pi > 0 and (" +" .. pi .. " PI") or ""), "ventas")
				end
			end
			if Rules.lotAvailable(lot) == 0 then
				-- Sin stock no se acumulan ventas «atrasadas».
				lot.saleAcc = math.min(lot.saleAcc, 1)
			end
			if lot.produced >= lot.qty and Rules.lotAvailable(lot) == 0 and Rules.lotPending(lot) == 0 then
				table.insert(done, lot)
			end
		end
	end
	for _, lot in done do
		lot.saleState = "agotado"
		g.counters.lotsSoldOut = (g.counters.lotsSoldOut or 0) + 1
		local profit = lot.revenue - lot.costSpent
		local bonus = 0
		-- Lote exitoso: solo cuenta si es de un tamaño razonable (un lote de una unidad no da PI).
		if profit > 0 and lot.qty >= Catalog.ECON.soldOutMinQty then
			bonus = math.floor(Simulation.bonusPi(g, Rules.piPerMinute(g) * Catalog.ECON.soldOutPiMinutes))
			g.reputation = clamp(g.reputation + 0.03, 1, 5)
		end
		Simulation.addXp(g, ctx, 120)
		Simulation.archiveLot(g, lot)
		Simulation.notify(g, ctx, "ok", "¡Agotado! " .. lot.design.name .. ": " .. Util.num(lot.sold) .. " autos vendidos · beneficio " .. money(profit) .. (bonus > 0 and (" · +" .. bonus .. " PI") or ""), "ventas")
	end
end

--[[ Investigación: el centro y las líneas activas generan PI (se acumulan para pagar proyectos nuevos) y cada
	proyecto en curso avanza por DÍAS simulados (las velocidades y la pausa se aplican solas porque dependen de
	los minutos simulados). Al llegar a sus días se completa una sola vez y desbloquea la tecnología. ]]
function Simulation.stepResearch(g: any, ctx: any, minutes: number)
	Simulation.addPi(g, Rules.piPerMinute(g) * Rules.realMinutes(minutes), ctx)
	local projects = g.research.projects
	if not projects or #projects == 0 then
		return
	end
	local days = minutes / Catalog.RULES.gameDayMinutes * Rules.researchSpeed(g)
	local finished = {}
	for i, p in projects do
		p.progress = math.min(p.days, p.progress + days)
		if p.progress >= p.days - 1e-9 then
			table.insert(finished, i)
		end
	end
	for k = #finished, 1, -1 do
		local p = table.remove(projects, finished[k])
		local n = Catalog.researchNode(p.id)
		if n and not Rules.has(g, p.id) then
			table.insert(g.research.done, p.id)
			g.counters.researchDone += 1
			Simulation.addXp(g, ctx, 150)
			Simulation.notify(g, ctx, "ok", "Investigación completada: " .. n.name .. ". " .. n.gain, "investigacion")
		end
	end
end

-- Compras permanentes ------------------------------------------------------------------

function Simulation.ownsLine(g: any, n: number): boolean
	return Rules.ownsLine(g, n)
end

-- Refleja la línea 3 de la cuenta en una empresa (la compra vive en el perfil: GameState.applyAccount).
-- Devuelve la función que deshace el cambio.
function Simulation.grantLine3(g: any): () -> ()
	g.facilities = g.facilities or {}
	local before = g.facilities.accountLine3
	g.facilities.accountLine3 = true
	return function()
		g.facilities.accountLine3 = before
	end
end

-- Personal --------------------------------------------------------------------------

local function randInt(ctx: any, lo: number, hi: number): number
	return lo + math.floor(ctx.rng() * (hi - lo + 1))
end

--[[ Un candidato del mercado laboral. Su especialidad es al azar entre los cuatro departamentos (o, en una
	búsqueda especializada, `focus` con probabilidad searchFocus). La reputación sube la probabilidad de
	talento; un candidato extraordinario puede aparecer siempre. ]]
function Simulation.makeCandidate(g: any, ctx: any, focus: string?): any
	local S = Catalog.STAFF
	local spec
	if focus and ctx.rng() < S.searchFocus then
		spec = focus
	else
		local pool = {}
		for _, id in Staff.DEPT_ORDER do
			if id ~= focus then
				table.insert(pool, id)
			end
		end
		spec = pool[randInt(ctx, 1, #pool)]
	end
	local rep = Util.clamp((g.reputation - 1) / 4, 0, 1)
	local talent = math.max(ctx.rng(), ctx.rng() * (0.6 + 0.5 * rep)) -- la reputación corre la curva hacia arriba
	local exceptional = ctx.rng() < S.exceptionalChance
	if exceptional then
		talent = 0.9 + ctx.rng() * 0.1
	end
	local skills, potential = {}, {}
	for _, d in S.departments do
		for _, k in d.skills do
			if d.id == spec then
				local v = Util.clamp(math.floor(15 + talent * 55 + ctx.rng() * 12), 5, 95)
				skills[k] = v
				potential[k] = Util.clamp(v + randInt(ctx, 8, 20 + math.floor(talent * 25)), v, 100)
			else
				local v = randInt(ctx, 0, 15)
				skills[k] = v
				potential[k] = Util.clamp(v + randInt(ctx, 10, 35), v, 100)
			end
		end
	end
	local c = {
		id = GameState.uid(g, "c"),
		name = pick(ctx, Catalog.FIRST) .. " " .. pick(ctx, Catalog.LAST),
		spec = spec,
		skills = skills,
		potential = potential,
		exceptional = exceptional or nil,
	}
	c.salary = Staff.salaryFor(c, Rules.year(g))
	return c
end

-- Reemplaza los candidatos del mes por `n` nuevos (los no contratados desaparecen).
function Simulation.refreshCandidates(g: any, ctx: any, focus: string?)
	local list = {}
	for _ = 1, Catalog.STAFF.candidatesPerMonth do
		table.insert(list, Simulation.makeCandidate(g, ctx, focus))
	end
	g.candidates = list
end

-- Mercado del mes: al empezar cada mes hay 8 candidatos nuevos y el contador de búsquedas vuelve a cero.
function Simulation.ensureMarket(g: any, ctx: any)
	g.market = g.market or { month = -1, searches = 0 }
	if g.market.month ~= g.time.day then
		g.market.month = g.time.day
		g.market.searches = 0
		Simulation.refreshCandidates(g, ctx, nil)
	end
end

-- Sueldos atrasados: el 30 % de cada venta va a la deuda salarial hasta saldarla (sin pagar de más).
function Simulation.recoverSalaryDebt(g: any, ctx: any, revenue: number)
	local pr = g.payroll
	if not pr or pr.debt <= 0 or revenue <= 0 then
		return
	end
	local pay = math.min(pr.debt, Util.round(revenue * Catalog.STAFF.debtRecoveryShare))
	if pay <= 0 then
		return
	end
	g.money -= pay
	pr.debt -= pay
	flow(g, "salarios", -pay)
	if pr.debt <= 0 then
		pr.debt = 0
		pr.debtMonths = 0
		Simulation.notify(g, ctx, "ok", "Se pagaron todos los sueldos atrasados. Las ventas vuelven a ingresar completas.", "personal")
	end
end

-- Pago de sueldos al empezar el mes: se paga lo que alcanza y el resto queda como deuda salarial.
function Simulation.payroll(g: any, ctx: any)
	g.payroll = g.payroll or { debt = 0, debtMonths = 0 }
	local pr = g.payroll
	local sal = Staff.salaries(g)
	if sal > 0 then
		local pay = math.min(sal, math.max(0, g.money))
		if pay > 0 then
			g.money -= pay
			Simulation.ledger(g, "salarios", -pay, "Salarios del mes")
		end
		if pay < sal then
			pr.debt += sal - pay
			Simulation.notify(g, ctx, "error", "No alcanzó para todos los sueldos: " .. money(sal - pay) .. " quedan como deuda salarial. El 30 % de las ventas se destina a pagarla.", "personal")
		end
	end
	if pr.debt > 0 then
		pr.debtMonths += 1
	else
		pr.debtMonths = 0
	end
	pr.lastDay = Rules.absDay(g) -- los que entren desde ahora cobran desde el próximo pago (Staff.unpaidSalary)
	-- Experiencia: cada expEvery meses trabajados mejora las habilidades de su departamento (hasta su potencial).
	local S = Catalog.STAFF
	for _, e in g.employees do
		e.months = (e.months or 0) + 1
		if e.months % S.expEvery == 0 then
			local d = Staff.dept(e.dept)
			for _, k in d and d.skills or {} do
				e.skills[k] = math.min(e.potential[k] or 100, (e.skills[k] or 0) + S.expGain)
			end
			e.salary = math.max(e.salary, Staff.salaryFor(e, Rules.year(g)))
		end
	end
end

--[[ Capacitaciones: avanzan por días simulados (respetan velocidades y pausa). Al terminar cada participante
	recibe exactamente el resultado anunciado (nunca más que su potencial), vuelve a su productividad normal y,
	si se capacitó en una habilidad de un departamento que no es su especialidad, se adapta más rápido. ]]
function Simulation.stepTrainings(g: any, ctx: any, minutes: number)
	local list = g.trainings
	if not list or #list == 0 then
		return
	end
	local days = minutes / Catalog.RULES.gameDayMinutes
	for i = #list, 1, -1 do
		local t = list[i]
		t.progress = math.min(t.days, t.progress + days)
		if t.progress >= t.days - 1e-9 then
			table.remove(list, i)
			local sk = Staff.skill(t.skill)
			for _, id in t.members do
				for _, e in g.employees do
					if e.id == id and e.training == t.id then
						e.skills[t.skill] = math.min(e.potential[t.skill] or 0, math.max(e.skills[t.skill] or 0, t.results[id] or 0))
						e.training = nil
						if sk and sk.dept ~= e.spec then
							e.adapt = e.adapt or {}
							e.adapt[sk.dept] = math.min(1, (e.adapt[sk.dept] or Catalog.STAFF.adaptStart) + Catalog.STAFF.trainingAdapt)
						end
						e.salary = math.max(e.salary, Staff.salaryFor(e, Rules.year(g)))
					end
				end
			end
			Simulation.notify(g, ctx, "ok", "Capacitación terminada: " .. #t.members .. " en " .. (sk and sk.name or t.skill) .. ".", "personal")
		end
	end
end

--[[ Obras de instalaciones: avanzan por días simulados (velocidades y pausa) y la organización del personal
	de Administración las acelera en vivo. Al terminar aplican el nivel nuevo una sola vez. ]]
function Simulation.stepBuilds(g: any, ctx: any, minutes: number)
	local f = g.facilities
	if not f or #f.builds == 0 then
		return
	end
	local days = minutes / Catalog.RULES.gameDayMinutes * Rules.buildSpeed(g)
	for i = #f.builds, 1, -1 do
		local b = f.builds[i]
		b.progress = math.min(b.days, b.progress + days)
		if b.progress >= b.days - 1e-9 then
			table.remove(f.builds, i)
			local label
			if b.kind == "offices" and (g.sede or 1) < b.level then
				g.sede = b.level
				g.counters.sedeLevel = g.sede
				-- La decoración pasa al plano nuevo: se conserva lo compatible y lo demás vuelve al inventario.
				if type(g.office) == "table" then
					Office.remap(g.office, g.sede)
				end
				label = "Oficinas centrales: " .. Rules.sede(g).office .. " (" .. Rules.sede(g).name .. ")"
			elseif (b.kind == "factory" or b.kind == "research") and (f[b.kind] or 1) < b.level then
				f[b.kind] = b.level
				label = Catalog.FACILITIES[b.kind].name .. ": " .. Rules.facilityDef(b.kind, b.level).name
			elseif b.kind == "line2" then
				f.lines["2"] = true
				label = "Línea de producción 2"
			end
			if label then
				Simulation.addXp(g, ctx, 300)
				Simulation.notify(g, ctx, "ok", "Obra terminada: " .. label .. ".", "compania")
			end
		end
	end
end

-- Campaña: avanza con el calendario (comunicación la hace durar más) y termina sola.
function Simulation.stepCampaign(g: any, ctx: any, minutes: number)
	local c = Rules.campaign(g)
	if not c then
		return
	end
	c.progress = math.min(c.days, c.progress + minutes / Catalog.RULES.gameDayMinutes * Rules.campaignSpeed(g))
	if c.progress >= c.days - 1e-9 then
		g.campaign = nil
		Simulation.notify(g, ctx, "info", "Terminó la campaña «" .. c.name .. "».", "ventas")
	end
end

-- Adaptación diaria de quienes trabajan fuera de su especialidad.
function Simulation.stepStaff(g: any, minutes: number)
	local S = Catalog.STAFF
	local days = minutes / Catalog.RULES.gameDayMinutes
	for _, e in g.employees do
		if e.dept ~= e.spec then
			e.adapt = e.adapt or {}
			e.adapt[e.dept] = math.min(1, (e.adapt[e.dept] or S.adaptStart) + days * (1 - S.adaptStart) / S.adaptDays)
		end
	end
end

-- Cierre de mes -------------------------------------------------------------------------

--[[ Novedades de la competencia del año `y` (todas salen de Rules.rivalOffers, el mismo cálculo del reparto):
	  - modelos nuevos (primera generación lanzada este año) y generaciones nuevas;
	  - bajas de precio de al menos 5 puntos MÁS que las ya informadas (no se repite la misma baja cada año);
	  - cambios de líder entre las marcas rivales de un tipo (enero de este año frente a enero del anterior).
	Devuelve (textos, bajas vigentes por modelo). Como mucho RIVAL_NEWS_MAX textos (los demás no se guardan). ]]
Simulation.RIVAL_NEWS_MAX = 12
Simulation.RIVAL_NEWS_SHOWN = 4
function Simulation.rivalNewsFor(g: any, y: number): ({ string }, { [string]: number })
	local items, cuts = {}, {}
	local typeNames: any = (Catalog.TYPES :: any)
	local prev = type(g.rivalNews) == "table" and type(g.rivalNews.cuts) == "table" and g.rivalNews.cuts or {}
	local function add(text: string)
		if #items < Simulation.RIVAL_NEWS_MAX then
			table.insert(items, text)
		end
	end
	for _, typeId in Catalog.TYPE_ORDER do
		if Rules.baseDemand(typeId, y) > 0 then
			for _, o in Rules.rivalOffers(typeId, y, g) do
				local key = o.rival.id .. ":" .. o.line.id
				if o.launched == y and o.gen == 1 then
					add(o.rival.name .. " presentó el " .. o.name .. " (" .. string.lower(typeNames[typeId]) .. ")")
				elseif o.launched == y then
					add(o.rival.name .. " lanzó la " .. o.gen .. ".ª generación del " .. o.name)
				end
				local c = Util.round(o.cut * 100)
				if c > 0 then
					cuts[key] = c
				end
				if c >= 5 and c - (prev[key] or 0) >= 5 then
					add(o.rival.name .. " bajó " .. c .. " % el precio del " .. o.name)
				end
			end
			local now, before = Rules.rivalLeader(typeId, y, g), Rules.rivalLeader(typeId, y - 1, g)
			if now and before and now.rival.id ~= before.rival.id then
				add(now.rival.name .. " pasa a liderar a las marcas rivales en " .. string.lower(typeNames[typeId]) .. " (antes " .. before.rival.name .. ")")
			end
		end
	end
	return items, cuts
end

function Simulation.monthRollover(g: any, ctx: any)
	-- Los movimientos de este bloque pertenecen al mes que empieza.
	Simulation.payroll(g, ctx)
	Simulation.ensureMarket(g, ctx)
	-- Mantenimiento de las instalaciones: con tope en una parte de las ventas del mes anterior (sin ventas no se
	-- cobra) y nunca más que el dinero disponible.
	local prev = g.stats.days[Rules.dayKey(g.time.day - 1)]
	local cap = (prev and prev.revenue or 0) * Catalog.FACILITIES.maintenanceRevenueCap
	local maint = math.min(Rules.maintenance(g), cap, math.max(0, g.money))
	if maint > 0 then
		g.money -= maint
		Simulation.ledger(g, "mantenimiento", -maint, "Mantenimiento de instalaciones")
	end
	-- Campaña corporativa: reconocimiento de marca (la reputación sube un poco cada mes, según el efecto).
	local camp = Rules.campaign(g)
	if camp and camp.kind == "corporativa" then
		local k = Catalog.MARKETING.kinds.corporativa
		g.reputation = clamp(g.reputation + k.repPerMonth * Rules.campaignBoost(g) / k.maxBoost, 1, 5)
	end
	-- Reputación: se acerca al nivel que justifica el atractivo de lo que vendiste el mes pasado.
	local m = g.stats.month
	if m.sold > 0 then
		local target = clamp(3 + (m.rel / m.sold) / 8, 1, 5)
		local step = Catalog.ECON.reputationStep * (1 + (target > g.reputation and Rules.tech(g, "repGain") / 100 or 0))
		g.reputation = clamp(g.reputation + (target - g.reputation) * step, 1, 5)
	end
	-- PI por ventas del mes: +1 cada 50 autos (dentro del tope mensual de bonificaciones).
	local salesPi = Simulation.bonusPi(g, m.sold / Catalog.ECON.salesPiPer)
	g.stats.month = { sold = 0, rel = 0, salesPi = salesPi, bonusPi = 0 }
	for _, lot in g.lots do
		lot.bestMonth = math.max(lot.bestMonth or 0, lot.monthSold)
		lot.lastMonthSold = lot.monthSold
		lot.monthSold = 0
	end
	-- Cuota de mercado de tu empresa por tipo (promedio móvil): los rivales la usan para reaccionar.
	for _, typeId in Catalog.TYPE_ORDER do
		local mk = Rules.market(g, typeId)
		local mine = 0
		for _, w in mk.lots do
			mine += w
		end
		local share = mk.total > 0 and mk.demand > 0 and mine / mk.total or 0
		g.marketShare[typeId] = (g.marketShare[typeId] or 0) * 0.8 + share * 0.2
	end
	if g.time.day % 12 == 0 and Rules.extraYears(g) > 0 then
		-- Después del último año histórico: el calendario visible queda fijo y se cuentan años comerciales.
		Simulation.notify(g, ctx, "info", "Año comercial " .. Rules.extraYears(g) .. " después de " .. Catalog.CALENDAR.endYear .. ": la historia llegó a su fin por ahora, pero tu empresa sigue fabricando, vendiendo e investigando.", nil)
	elseif g.time.day % 12 == 0 then
		local y = Rules.year(g)
		local news = {}
		for _, key in Catalog.RESEARCH_ORDER do
			for _, n in Catalog.RESEARCH[key].nodes do
				if n.year == y then
					table.insert(news, n.name)
				end
			end
		end
		Simulation.notify(g, ctx, "info", "Comienza " .. y .. "." .. (#news > 0 and (" Nuevas tecnologías para investigar: " .. table.concat(news, ", ") .. ".") or ""), #news > 0 and "investigacion" or nil)
		-- Competencia: novedades reales de las ofertas rivales de este año (Simulation.rivalNewsFor).
		local items, cuts = Simulation.rivalNewsFor(g, y)
		g.rivalNews = { year = y, items = items, cuts = cuts }
		if #items > 0 then
			local shown = table.move(items, 1, math.min(#items, Simulation.RIVAL_NEWS_SHOWN), 1, {})
			Simulation.notify(g, ctx, "info", "Competencia en " .. y .. ": " .. table.concat(shown, " · ") .. (#items > #shown and (" · y " .. (#items - #shown) .. " novedades más en Mercado") or "") .. ".", "mercado")
		end
		-- Los lanzamientos de diseños que ya no existen no necesitan recordarse.
		local alive = {}
		for _, d in g.designs do
			alive[d.id] = true
		end
		for _, l in g.lots do
			alive[l.designId] = true
		end
		for id in g.launched do
			if not alive[id] then
				g.launched[id] = nil
			end
		end
	end
end

-- Reloj -------------------------------------------------------------------------------

function Simulation.simulate(g: any, ctx: any, minutes: number)
	local left = minutes
	while left > 0 do
		local step = math.min(left, 10)
		left -= step
		g.time.minute += step
		local monthLen = Rules.monthMinutes(g.time.day)
		if g.time.minute >= monthLen then
			g.time.minute -= monthLen
			g.time.day += 1
			Simulation.monthRollover(g, ctx)
		end
		Simulation.stepProduction(g, ctx, step)
		Simulation.stepSales(g, ctx, step)
		Simulation.stepResearch(g, ctx, step)
		Simulation.stepStaff(g, step)
		Simulation.stepTrainings(g, ctx, step)
		Simulation.stepCampaign(g, ctx, step)
		Simulation.stepBuilds(g, ctx, step)
	end
end

return Simulation
