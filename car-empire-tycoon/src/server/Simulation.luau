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

-- Puntos de investigación al banco (con tope de Catalog.RULES.piBankMinutes minutos de generación).
function Simulation.addPi(g: any, n: number)
	g.rp = math.min(Rules.piCap(g), g.rp + n)
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
		unitCost = snap.calc.unitCost,
		appeal = appeal,
		revenue = 0,
		costSpent = 0,
		prodProgress = 0,
		saleAcc = 0,
		prodState = "cola",
		saleState = "en venta",
		createdDay = g.time.day,
		monthSold = 0,
		lastMonthSold = 0,
	}
end

-- Saca un lote de la lista activa y lo guarda en el historial (más reciente primero).
function Simulation.archiveLot(g: any, lot: any)
	for i, l in g.lots do
		if l.id == lot.id then
			table.remove(g.lots, i)
			break
		end
	end
	lot.endDay = g.time.day
	table.insert(g.lotHistory, 1, lot)
	GameState.trim(g)
end

function Simulation.stepProduction(g: any, ctx: any, minutes: number)
	local active = Rules.producingLots(g)
	local rate = Rules.lineRate(g) * Rules.realMinutes(minutes)
	local busy = {}
	for _, lot in active do
		busy[lot.id] = true
		local pending = lot.qty - lot.produced
		lot.prodProgress += rate
		local n = math.min(math.floor(lot.prodProgress), pending)
		if n > 0 then
			-- Se cobra cada unidad al terminarla; si no alcanza, se fabrican solo las que se pueden pagar.
			local affordable = lot.unitCost > 0 and math.floor(g.money / lot.unitCost) or n
			if affordable < n then
				n = affordable
			end
		end
		if n > 0 then
			local cost = n * lot.unitCost
			g.money -= cost
			flow(g, "fabricacion", -cost)
			lot.costSpent += cost
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
				Simulation.notify(g, ctx, "ok", "Lote terminado: " .. Util.num(lot.qty) .. " × " .. lot.design.name .. ". La producción se detuvo.", "fabrica")
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
	-- Los demás lotes con producción pendiente esperan una línea libre.
	for _, lot in g.lots do
		if not busy[lot.id] and Rules.lotProducing(lot) and lot.prodState ~= "pausado" then
			lot.prodState = "cola"
		end
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
				local revenue = n * lot.price
				g.money += revenue
				flow(g, "venta", revenue)
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
		if profit > 0 then
			bonus = round(Rules.piPerMinute(g) * Catalog.ECON.soldOutPiMinutes)
			Simulation.addPi(g, bonus)
			g.reputation = clamp(g.reputation + 0.03, 1, 5)
		end
		Simulation.addXp(g, ctx, 120)
		Simulation.archiveLot(g, lot)
		Simulation.notify(g, ctx, "ok", "¡Agotado! " .. lot.design.name .. ": " .. Util.num(lot.sold) .. " autos vendidos · beneficio " .. money(profit) .. (bonus > 0 and (" · +" .. bonus .. " PI") or ""), "ventas")
	end
end

-- Investigación: la generación de la sede llena el banco; el proyecto activo toma del banco.
function Simulation.stepResearch(g: any, ctx: any, minutes: number)
	local gain = Rules.piPerMinute(g) * Rules.realMinutes(minutes)
	local a = g.research.active
	if not a then
		Simulation.addPi(g, gain)
		return
	end
	g.rp += gain
	local n = Catalog.researchNode(a.id)
	local draw = math.min(g.rp, n.rp - a.progress)
	a.progress += draw
	g.rp -= draw
	if a.progress >= n.rp - 1e-6 then
		table.insert(g.research.done, a.id)
		g.research.active = nil
		g.counters.researchDone += 1
		Simulation.addXp(g, ctx, 150)
		Simulation.notify(g, ctx, "ok", "Investigación completada: " .. n.name .. ". " .. n.gain, "investigacion")
	end
	g.rp = math.min(g.rp, Rules.piCap(g))
end

-- Personal --------------------------------------------------------------------------

function Simulation.makeCandidates(g: any, ctx: any, n: number): { any }
	local out = {}
	for _ = 1, n do
		local lvl = 1 + math.floor(ctx.rng() * math.min(6, 1 + g.sede))
		table.insert(out, {
			id = GameState.uid(g, "c"),
			name = pick(ctx, Catalog.FIRST) .. " " .. pick(ctx, Catalog.LAST),
			role = pick(ctx, Catalog.ROLES),
			level = lvl,
			skill = clamp(40 + lvl * 7 + math.floor(ctx.rng() * 12), 30, 98),
			salary = 800 + lvl * 400,
			fee = 3000 + lvl * 2500,
		})
	end
	return out
end

-- Cierre de mes -------------------------------------------------------------------------

function Simulation.monthRollover(g: any, ctx: any)
	-- Los movimientos de este bloque pertenecen al mes que empieza.
	local sal = Rules.salaries(g)
	if sal > 0 then
		local pay = math.min(sal, g.money)
		if pay > 0 then
			g.money -= pay
			Simulation.ledger(g, "salarios", -pay, "Salarios del mes")
		end
		if pay < sal then
			g.reputation = clamp(g.reputation - 0.05, 1, 5)
			Simulation.notify(g, ctx, "error", "No alcanzó el dinero para pagar todos los salarios. Bajó la reputación.", "personal")
		end
	end
	if g.promo then
		local cost = Rules.sede(g).campaign
		if not Simulation.spend(g, cost, "promocion", "Campaña publicitaria del mes") then
			g.promo = false
			Simulation.notify(g, ctx, "aviso", "La campaña publicitaria se detuvo por falta de fondos.", "ventas")
		end
	end
	-- Reputación: se acerca al nivel que justifica el atractivo de lo que vendiste el mes pasado.
	local m = g.stats.month
	if m.sold > 0 then
		local target = clamp(3 + (m.rel / m.sold) / 8, 1, 5)
		local step = Catalog.ECON.reputationStep * (1 + (target > g.reputation and Rules.tech(g, "repGain") / 100 or 0))
		g.reputation = clamp(g.reputation + (target - g.reputation) * step, 1, 5)
	end
	-- PI por ventas: +1 cada 50 autos, con tope de medio minuto de generación por mes.
	local salesPi = math.min(m.sold / Catalog.ECON.salesPiPer, Rules.piPerMinute(g) * Catalog.ECON.salesPiCapMinutes)
	if salesPi > 0 then
		Simulation.addPi(g, salesPi)
	end
	g.stats.month = { sold = 0, rel = 0, salesPi = salesPi }
	for _, lot in g.lots do
		lot.lastMonthSold = lot.monthSold
		lot.monthSold = 0
	end
	if #g.candidates < 3 then
		for _, c in Simulation.makeCandidates(g, ctx, 2) do
			table.insert(g.candidates, c)
		end
	end
	if g.time.day % 12 == 0 then
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
	end
end

-- Reloj -------------------------------------------------------------------------------

function Simulation.simulate(g: any, ctx: any, minutes: number)
	local left = minutes
	while left > 0 do
		local step = math.min(left, 10)
		left -= step
		g.time.minute += step
		if g.time.minute >= Catalog.RULES.dayMinutes then
			g.time.minute -= Catalog.RULES.dayMinutes
			g.time.day += 1
			Simulation.monthRollover(g, ctx)
		end
		Simulation.stepProduction(g, ctx, step)
		Simulation.stepSales(g, ctx, step)
		Simulation.stepResearch(g, ctx, step)
	end
end

return Simulation
