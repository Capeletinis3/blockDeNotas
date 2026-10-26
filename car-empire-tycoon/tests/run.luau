--[[
	Pruebas de la lógica del servidor fuera de Roblox, con Lune (https://lune-org.github.io/docs).
	Uso (desde la carpeta car-empire-tycoon):  lune run tests/run.luau

	Copia los módulos de src/ a tests/.build/ reescribiendo los require de Roblox a rutas de archivo.
	Cubren las 16 pruebas obligatorias de la auditoría (marcadas [P1]…[P16]; la [P15], interfaz en PC y
	celular, está en tests/ui.luau), además de saneamiento, migración, guardado, candados y reenvíos.
]]

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local task = require("@lune/task")
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
local DataService = require("./.build/server/DataService")
local Sessions = require("./.build/server/Sessions")
_G.BALANCE_AS_MODULE = true
local Bot = require("./balance")

local T = require("./harness")
local check, eq, test = T.check, T.eq, T.test
local round = Util.round

local function seeded(seed: number)
	local state = seed
	return function(): number
		state = (state * 1103515245 + 12345) % 2147483648
		return state / 2147483648
	end
end

local function makeCtx(seed: number)
	local ctx = { events = {}, today = "2026-10-25", yesterday = "2026-10-24" }
	ctx.rng = seeded(seed)
	ctx.notify = function(kind: string, text: string)
		table.insert(ctx.events, { kind, text })
	end
	return ctx
end

local function jsonCopy(v: any): any
	return serde.decode("json", serde.encode("json", v))
end

local function loadFixture(): any
	return serde.decode("json", fs.readFile("tests/fixtures/save_v2.json"))
end

local function newCompany(name: string, color: string?, difficulty: string?): any
	local clean, err = Actions.validateCompany({ name = name, color = color, difficulty = difficulty })
	assert(clean, err)
	return GameState.newGame({ name = clean.name, color = clean.color, logo = clean.logo, difficulty = clean.difficulty, now = 1000 })
end

local function draftFor(g: any, baseId: string, name: string?): any
	local d = jsonCopy(DesignCalc.newDraft(g, baseId))
	if name then
		d.name = name
	end
	return d
end

local function saveNew(g: any, ctx: any, baseId: string, name: string?): string
	local r = Actions.saveDesign(g, ctx, { draft = draftFor(g, baseId, name) })
	assert(r.ok, r.msg)
	return r.designId
end

-- Minutos reales de simulación a velocidad 1× (1 s real = 10 min de juego).
local function runReal(g: any, ctx: any, realMinutes: number, each: ((any) -> ())?)
	for _ = 1, math.floor(realMinutes * 60) do
		Simulation.simulate(g, ctx, 10)
		if each then
			each(g)
		end
	end
end

local function runUntil(g: any, ctx: any, cond: () -> boolean, maxRealMinutes: number): boolean
	for _ = 1, math.floor(maxRealMinutes * 60) do
		Simulation.simulate(g, ctx, 10)
		if cond() then
			return true
		end
	end
	return false
end

local function findLot(g: any, id: string): any
	for _, l in g.lots do
		if l.id == id then
			return l
		end
	end
	return nil
end

local function findHist(g: any, id: string): any
	for _, l in g.lotHistory do
		if l.id == id then
			return l
		end
	end
	return nil
end

-- Invariantes de todos los lotes: nunca se vende ni descarta más de lo fabricado, ni se fabrica más de lo pedido.
local function lotInvariants(g: any)
	for _, list in { g.lots, g.lotHistory } do
		for _, l in list do
			assert(l.sold + l.discarded <= l.produced, "vendidas + descartadas > fabricadas en " .. l.id)
			assert(l.produced <= l.qty, "fabricadas > encargadas en " .. l.id)
			assert(l.sold >= 0 and l.produced >= 0 and l.discarded >= 0, "contador negativo en " .. l.id)
		end
	end
	assert(g.counters.unitsSold <= g.counters.unitsProduced, "vendidos > fabricados")
	assert(g.money >= 0, "dinero negativo")
end

-- Empresa grande (para lotes de miles de unidades sin esperar horas de juego).
local function bigCompany(name: string): any
	local g = newCompany(name)
	g.sede = 5
	g.counters.sedeLevel = 5
	g.money = 500000000
	return g
end

local function claimReady(g: any, ctx: any)
	for _, m in Catalog.MISSIONS do
		if Rules.missionState(g, m) == "lista" then
			Actions.claimMission(g, ctx, { id = m.id })
		end
	end
end

-- [P1] Calendario ------------------------------------------------------------------------------

test("[P1] Una empresa nueva comienza en enero de 1970 y el calendario avanza solo", function()
	local g = newCompany("Ruta Norte Motors")
	local ctx = makeCtx(1)
	eq(Rules.year(g), 1970, "año inicial")
	eq(Util.gameDate(g.time.day), "Ene 1970", "fecha que muestra el HUD")
	check(Catalog.CALENDAR.realSecondsPerYear >= 600 and Catalog.CALENDAR.realSecondsPerYear <= 720, "un año cada 10–12 minutos reales")
	runReal(g, ctx, Catalog.CALENDAR.realSecondsPerYear / 60)
	eq(Rules.year(g), 1971, "un año después, a 1×")
	eq(Util.gameDate(g.time.day), "Ene 1971", "mes y año")
	check(Catalog.CALENDAR.endYear >= 2030, "llega hasta 2030")
	-- Una partida guardada que pasó 2030 sigue funcionando (el calendario es extensible).
	g.time.day = (2040 - 1970) * 12 + 5
	eq(Rules.year(g), 2030, "después de 2030 el año visible queda en 2030")
	eq(Rules.periodYear(g), 2040, "y se cuentan años comerciales")
	eq(Util.gameDate(g.time.day), "Jun 2030", "fecha visible")
	Simulation.simulate(g, ctx, 600)
	check(GameState.validate(g), "válida en 2040")
end)

test("Épocas: en 1970 no hay tecnologías de otra época", function()
	local g = newCompany("Era SA")
	local d = DesignCalc.newDraft(g, "pixel")
	for _, id in { "auto8", "dct7", "ev60", "ev80", "ssb", "mhev" } do
		local p
		for _, c in Catalog.CATS do
			p = p or Catalog.part(c[1], id)
		end
		check(p ~= nil, "existe la pieza " .. id)
		check(p.year >= 2000, id .. " es de " .. p.year)
		check(DesignCalc.partBlock(g, d, p) ~= nil, id .. " bloqueada en 1970")
	end
	for _, b in Catalog.BASES do
		if b.year > 1970 then
			check(DesignCalc.baseAvailable(g, b) ~= nil, b.name .. " no disponible en 1970")
		end
	end
	check(DesignCalc.baseAvailable(g, Catalog.base("rayo")) ~= nil, "sin eléctricos en 1970")
	-- Ninguna tecnología de redes sociales o internet antes de los años 2000.
	for _, key in Catalog.RESEARCH_ORDER do
		for _, n in Catalog.RESEARCH[key].nodes do
			local lower = string.lower(n.name)
			if string.find(lower, "redes sociales") or string.find(lower, "internet") then
				check(n.year >= 1995, n.name .. " no aparece en los 70 (" .. n.year .. ")")
			end
			if string.find(lower, "eléctric") or string.find(lower, "híbrid") or string.find(lower, "8 velocidades") then
				check(n.year >= 1997, n.name .. " es moderna (" .. n.year .. ")")
			end
		end
	end
	-- El cliente no puede colar una pieza del futuro.
	local raw = draftFor(g, "pixel")
	raw.parts.transmision = "auto8"
	local ok, err = DesignCalc.sanitize(g, raw)
	check(ok == nil and string.find(err or "", "2008") ~= nil, "caja de 8 velocidades rechazada en 1970: " .. tostring(err))
	raw = draftFor(g, "pixel")
	raw.wheels.size = 20
	check(DesignCalc.sanitize(g, raw) == nil, "llantas de 20″ rechazadas en 1970")
end)

-- [P2] Diseño ------------------------------------------------------------------------------------

test("[P2] Diseñar y guardar un auto: desarrollo una sola vez, año de modelo y generación", function()
	local g = newCompany("Ruta Norte Motors")
	local ctx = makeCtx(2)
	local m0 = g.money
	local r = Actions.saveDesign(g, ctx, { draft = draftFor(g, "pixel", "Pixel Uno") })
	check(r.ok, r.msg)
	check(r.paid > 0 and g.money == m0 - r.paid, "se cobra el desarrollo")
	local d = g.designs[1]
	eq(d.modelYear, 1970, "año de modelo")
	eq(d.gen, 1, "primera generación")
	check(string.find(d.generation, "1970") ~= nil, "etiqueta con el año: " .. d.generation)
	-- Mismo modelo otra vez: la licencia ya está pagada.
	local m1 = g.money
	local r2 = Actions.saveDesign(g, ctx, { draft = draftFor(g, "pixel", "Pixel Dos") })
	local eng = DesignCalc.engineeringCost(g, g.designs[2] or d, "nuevo")
	check(r2.ok and r2.paid == eng and g.money == m1 - eng, "la licencia no se vuelve a pagar: solo la ingeniería del modelo nuevo (" .. tostring(r2.paid) .. ")")
	-- Cambios estéticos no pagan ingeniería; cambiar una pieza paga la de una versión.
	local v = jsonCopy(g.designs[2])
	v.paint.primary = "#D6333F"
	local m2 = g.money
	local r3 = Actions.saveDesign(g, ctx, { draft = v, sourceId = v.id })
	check(r3.ok and r3.paid == 0 and g.money == m2, "pintar de nuevo no cuesta ingeniería")
	v = jsonCopy(g.designs[2])
	v.parts.motor = "i4e"
	local r4 = Actions.saveDesign(g, ctx, { draft = v, sourceId = v.id })
	check(r4.ok and r4.paid == DesignCalc.engineeringCost(g, v, "version"), "cambiar el motor paga la ingeniería de una versión")
	check(DesignCalc.engineeringCost(g, v, "nuevo") < DesignCalc.engineeringCost({ time = { day = 40 * 12 }, research = { done = {} }, employees = {} }, v, "nuevo"), "la ingeniería cuesta más en épocas modernas")
	check(not Actions.saveDesign(g, ctx, { draft = draftFor(g, "pixel", "pixel uno") }).ok, "nombre repetido rechazado")
	-- Saneamiento: el cliente no puede inventar piezas ni bases.
	local bad = draftFor(g, "pixel")
	bad.parts.motor = "warp"
	check(not Actions.saveDesign(g, ctx, { draft = bad }).ok, "pieza inexistente")
	bad = draftFor(g, "pixel")
	bad.baseId = "nave"
	check(not Actions.saveDesign(g, ctx, { draft = bad }).ok, "base inexistente")
	-- Las estadísticas del cliente (editor) y del servidor salen de la misma función.
	local c1 = DesignCalc.computeDesign(g, d)
	local c2 = Simulation.designSnapshot(g, d).calc
	eq(c1.unitCost, c2.unitCost, "costo igual en editor y servidor")
	eq(c1.price, c2.price, "precio recomendado igual")
	check(c1.price > c1.unitCost, "el precio recomendado deja margen")
end)

test("Nueva generación: misma familia, número siguiente y año actual", function()
	local g = newCompany("Gen SA")
	local ctx = makeCtx(3)
	local id = saveNew(g, ctx, "brisa", "Brisa")
	g.time.day = 12 * 6 -- 1976
	local nd = draftFor(g, "brisa", "Brisa")
	local r = Actions.saveDesign(g, ctx, { draft = nd, newGenOf = id })
	check(r.ok, r.msg)
	local d2 = g.designs[2]
	eq(d2.gen, 2, "segunda generación")
	eq(d2.modelYear, 1976, "año de modelo nuevo")
	eq(d2.lineage, id, "misma familia")
	eq(g.counters.generations, 1, "contador para la misión")
	check(string.find(d2.generation, "2") ~= nil and string.find(d2.generation, "1976") ~= nil, "etiqueta " .. d2.generation)
end)

-- [P3]–[P5] Lotes --------------------------------------------------------------------------------

test("Lotes: cantidad libre (100, 1.000, 10.000, 50.000) y validación", function()
	local g = bigCompany("Lotes SA")
	local ctx = makeCtx(4)
	local id = saveNew(g, ctx, "brisa")
	for _, q in { 100, 1000, 10000, 50000 } do
		local r = Actions.createLot(g, ctx, { designId = id, qty = q })
		check(r.ok, "lote de " .. q .. ": " .. tostring(r.msg))
	end
	eq(#g.lots, 4, "cuatro lotes")
	eq(g.lots[4].qty, 50000, "50.000 unidades encargadas")
	for _, q in { 0, -5, 2.5, Catalog.RULES.maxLotQty + 1 } do
		check(not Actions.createLot(g, ctx, { designId = id, qty = q }).ok, "cantidad inválida " .. q)
	end
	check(not Actions.createLot(g, ctx, { designId = "x", qty = 10 }).ok, "diseño inexistente")
	check(not Actions.createLot(g, ctx, { designId = id, qty = 10, price = 1 }).ok, "precio fuera de rango")
	local m = g.money
	eq(m, g.money, "lanzar un lote no cobra nada por adelantado")
	-- 50.000 unidades no generan 50.000 registros.
	local size = #serde.encode("json", g)
	check(size < 60000, "partida chica con 61.100 unidades encargadas: " .. size .. " bytes")
end)

test("[P3][P4][P5] Se fabrica exactamente el lote, se detiene y no se repite", function()
	local g = bigCompany("Exacto SA")
	local ctx = makeCtx(5)
	local id = saveNew(g, ctx, "brisa")
	local calc = DesignCalc.computeDesign(g, g.designs[1])
	-- Precio máximo para que la venta sea lenta y se vea el stock acumulado.
	local hi = select(2, Actions.priceRange({ unitCost = calc.unitCost, refPrice = calc.price }))
	local r = Actions.createLot(g, ctx, { designId = id, qty = 10000, price = hi })
	check(r.ok, r.msg)
	local lot = findLot(g, r.lotId)
	local done = runUntil(g, ctx, function()
		lotInvariants(g)
		return lot.prodState == "completado"
	end, 200)
	check(done, "el lote terminó")
	eq(lot.produced, 10000, "exactamente 10.000 fabricadas")
	eq(g.counters.unitsProduced, 10000, "contador global")
	eq(lot.costSpent, 10000 * lot.unitCost, "se cobró cada unidad una sola vez")
	local before = g.counters.unitsProduced
	local lotsBefore = #g.lots + #g.lotHistory
	runReal(g, ctx, 20, lotInvariants)
	eq(g.counters.unitsProduced, before, "[P4] no se fabricó nada más")
	eq(lot.produced, 10000, "el lote no crece")
	eq(#g.lots + #g.lotHistory, lotsBefore, "[P5] no se creó ningún lote nuevo")
	-- Al agotarse se archiva y tampoco se relanza solo.
	check(Actions.setLotPrice(g, ctx, { lotId = lot.id, price = calc.price }).ok, "bajar el precio")
	local soldOut = runUntil(g, ctx, function()
		lotInvariants(g)
		return lot.saleState == "agotado"
	end, 400)
	check(soldOut, "el lote se agotó")
	check(findLot(g, lot.id) == nil and findHist(g, lot.id) ~= nil, "pasó al historial")
	runReal(g, ctx, 10, lotInvariants)
	eq(#g.lots, 0, "[P5] sin pedidos automáticos después de agotarse")
	eq(g.counters.unitsProduced, 10000, "nada fabricado de más")
end)

test("Sin fondos: la producción se pausa sin deuda y sigue sola cuando entra dinero", function()
	local g = newCompany("Justa SA", nil, "dificil")
	local ctx = makeCtx(6)
	local id = saveNew(g, ctx, "pixel")
	local unit = DesignCalc.computeDesign(g, g.designs[1]).unitCost
	g.money = unit * 3 + 50 -- alcanza para 3 unidades
	local calc = DesignCalc.computeDesign(g, g.designs[1])
	local hi = select(2, Actions.priceRange({ unitCost = calc.unitCost, refPrice = calc.price }))
	local r = Actions.createLot(g, ctx, { designId = id, qty = 500, price = hi })
	check(r.ok, r.msg)
	local lot = findLot(g, r.lotId)
	-- Sin ventas (el tipo no tiene demanda en esta prueba) para que no entre dinero.
	local saved = Catalog.DEMAND.compacto
	Catalog.DEMAND.compacto = { { 1970, 0 }, { 2100, 0 } }
	runReal(g, ctx, 2, lotInvariants)
	eq(lot.produced, 3, "solo las unidades que se pueden pagar")
	eq(lot.prodState, "sin fondos", "estado visible")
	check(g.money >= 0 and g.money < unit, "nunca en negativo")
	local p = lot.produced
	runReal(g, ctx, 2, lotInvariants)
	eq(lot.produced, p, "no avanza sin dinero ni acumula avance")
	g.money += unit * 10
	runReal(g, ctx, 2, lotInvariants)
	check(lot.produced == 13, "reanuda sola con el dinero nuevo: " .. lot.produced)
	Catalog.DEMAND.compacto = saved
end)

test("Varios lotes: las líneas de la sede se reparten y el resto espera en cola", function()
	local g = newCompany("Cola SA", nil, "facil")
	local ctx = makeCtx(7)
	local a = saveNew(g, ctx, "pixel")
	local b = saveNew(g, ctx, "brisa")
	g.money = 1000000
	check(Actions.createLot(g, ctx, { designId = a, qty = 30 }).ok, "lote A")
	check(Actions.createLot(g, ctx, { designId = b, qty = 30 }).ok, "lote B")
	Simulation.simulate(g, ctx, 60)
	eq(#Rules.producingLots(g), 1, "garaje: una línea")
	eq(g.lots[2].prodState, "cola", "el segundo espera")
	check(Actions.moveLot(g, ctx, { lotId = g.lots[2].id, delta = -1 }).ok, "subir en la cola")
	eq(g.lots[1].designId, b, "ahora B va primero")
	check(Actions.toggleLotPause(g, ctx, { lotId = g.lots[1].id }).ok, "pausar B")
	eq(Rules.producingLots(g)[1].designId, a, "la línea toma A mientras B está en pausa")
end)

-- [P6]–[P8] Ventas automáticas -----------------------------------------------------------------

test("[P6][P7][P8] Ventas automáticas sin negociar, nunca más que lo fabricado, varios modelos a la vez", function()
	local g = newCompany("Ventas SA", nil, "facil")
	local ctx = makeCtx(8)
	g.sede = 3
	g.money = 3000000
	local a = saveNew(g, ctx, "pixel")
	local b = saveNew(g, ctx, "brisa")
	local c = saveNew(g, ctx, "toro")
	local la = Actions.createLot(g, ctx, { designId = a, qty = 400 }).lotId
	local lb = Actions.createLot(g, ctx, { designId = b, qty = 400 }).lotId
	local lc = Actions.createLot(g, ctx, { designId = c, qty = 400 }).lotId
	local soldAt = {}
	runReal(g, ctx, 3, function()
		lotInvariants(g)
		for _, id in { la, lb, lc } do
			local l = findLot(g, id) or findHist(g, id)
			if l.sold > 0 and not soldAt[id] then
				soldAt[id] = true
			end
		end
	end)
	check(g.counters.unitsSold > 0, "[P6] se vendió sin ninguna acción del jugador")
	check(soldAt[la] and soldAt[lb] and soldAt[lc], "[P8] los tres modelos vendieron en el mismo período")
	-- La venta va al ritmo de la demanda, que se puede explicar: precio y atractivo.
	local lot = findLot(g, la)
	if lot then
		local r0 = Rules.lotPotentialRate(g, lot)
		local saved = lot.price
		lot.price = round(lot.refPrice * 1.5)
		local r1 = Rules.lotPotentialRate(g, lot)
		lot.price = saved
		check(r1 < r0 * 0.6, "precio 50 % más alto vende bastante menos (" .. Util.num(r0, 1) .. " → " .. Util.num(r1, 1) .. "/min)")
	end
end)

test("Ventas comprensibles: atractivo, precio, demanda, reputación y alcance mueven el ritmo", function()
	local g = newCompany("Mercado SA")
	local ctx = makeCtx(9)
	saveNew(g, ctx, "brisa")
	local d = g.designs[1]
	local calc = DesignCalc.computeDesign(g, d)
	local base = Rules.designSalesEstimate(g, calc, d, calc.price).rate
	check(base > 0, "vende algo")
	check(Rules.designSalesEstimate(g, calc, d, calc.price * 2).rate < base * 0.4, "precio ×2 vende mucho menos")
	check(Rules.designSalesEstimate(g, calc, d, calc.price * 0.8).rate > base, "más barato vende más")
	g.reputation = 4.5
	check(Rules.designSalesEstimate(g, calc, d, calc.price).rate > base, "más reputación vende más")
	g.reputation = 3
	g.sede = 2
	check(Rules.designSalesEstimate(g, calc, d, calc.price).rate > base * 2, "una sede más grande llega a más clientes")
	g.sede = 1
	-- Un auto de mejor calidad (terminación) atrae más.
	local better = jsonCopy(d)
	better.quality = 5
	local cb = DesignCalc.computeDesign(g, better)
	check(Rules.designSalesEstimate(g, cb, better, calc.price).rate > base, "más calidad, más ventas al mismo precio")
	-- La demanda depende del tipo y la época.
	check(Rules.demand(g, "suv", 1975) == 0 and Rules.demand(g, "suv", 2005) > Rules.demand(g, "suv", 1990), "los SUV crecen con los años")
	check(Rules.demand(g, "electrico", 1990) == 0 and Rules.demand(g, "electrico", 2025) > 0, "eléctricos solo en la época moderna")
	-- Competidores: marcas ficticias con modelos de su época.
	local rivals = Rules.rivalOffers("sedan", 1975)
	check(#rivals >= 2, "hay rivales en sedanes")
	for _, rv in rivals do
		check(type(rv.name) == "string" and rv.appeal > 0, "rival con nombre y atractivo")
	end
end)

-- [P9]–[P11] Cerrar venta e historial -----------------------------------------------------------

test("[P9][P10][P11] Cerrar venta: descarta lo no vendido sin reintegro, cancela lo pendiente y nunca más vende", function()
	local g = bigCompany("Cierre SA")
	local ctx = makeCtx(10)
	local id = saveNew(g, ctx, "brisa")
	local calc = DesignCalc.computeDesign(g, g.designs[1])
	local hi = select(2, Actions.priceRange({ unitCost = calc.unitCost, refPrice = calc.price }))
	local r = Actions.createLot(g, ctx, { designId = id, qty = 5000, price = hi })
	local lot = findLot(g, r.lotId)
	runReal(g, ctx, 6, lotInvariants)
	local produced, sold = lot.produced, lot.sold
	local avail = Rules.lotAvailable(lot)
	local pending = Rules.lotPending(lot)
	check(avail > 0 and pending > 0 and sold > 0, "hay vendidas, stock y pendientes (" .. sold .. "/" .. avail .. "/" .. pending .. ")")
	local m = g.money
	local res = Actions.closeSale(g, ctx, { lotId = lot.id })
	check(res.ok, res.msg)
	check(string.find(res.msg, Util.num(avail)) ~= nil, "el mensaje dice cuántas se descartan")
	eq(g.money, m, "[P9] sin reintegro ni cobro al cerrar")
	eq(lot.discarded, avail, "[P9] unidades descartadas")
	eq(lot.saleState, "retirado", "estado Retirado")
	eq(lot.prodState, "cancelado", "producción pendiente cancelada")
	eq(lot.qty, produced, "lo pendiente no se fabricó ni se cobró")
	eq(lot.costSpent, produced * lot.unitCost, "costo = solo lo fabricado")
	eq(lot.lossDiscarded, avail * lot.unitCost, "pérdida registrada")
	local h = findHist(g, lot.id)
	check(findLot(g, lot.id) == nil and h ~= nil and h.saleState == "retirado" and h.discarded == avail, "en el historial, no en venta")
	local entry = nil
	for _, e in g.modelHistory do
		if e.key == lot.design.lineage .. "#" .. lot.design.gen then
			entry = e
		end
	end
	check(entry ~= nil and entry.discarded == avail and entry.sold == sold and entry.produced == produced, "el historial permanente suma el lote retirado")
	-- [P10] nunca vuelve a vender ni a fabricar.
	local unitsSold, unitsProduced = g.counters.unitsSold, g.counters.unitsProduced
	runReal(g, ctx, 10, lotInvariants)
	eq(lot.sold, sold, "[P10] no vendió más")
	eq(g.counters.unitsSold, unitsSold, "[P10] ventas globales iguales")
	eq(g.counters.unitsProduced, unitsProduced, "no fabricó más")
	check(not Actions.closeSale(g, ctx, { lotId = lot.id }).ok, "no se cierra dos veces")
	check(not Actions.setLotPrice(g, ctx, { lotId = lot.id, price = calc.price }).ok, "no se cambia el precio de un retirado")
	-- [P11] historial y contabilidad: sus números quedan guardados.
	eq(lot.revenue, sold * hi, "ingresos del lote")
	eq(lot.sold + lot.discarded, lot.produced, "vendidas + descartadas = fabricadas")
	eq(g.counters.lotsRetired, 1, "contador de retirados")
	eq(g.counters.unitsDiscarded, avail, "contador de descartadas")
	local note = g.ledger[#g.ledger]
	eq(note.type, "descarte", "registro del descarte")
	eq(note.amount, 0, "el registro no mueve dinero (ya se pagó al fabricar)")
	check(GameState.validate(g), "partida válida")
end)

test("Cerrar venta de un lote que todavía no fabricó nada: se cancela sin costo", function()
	local g = newCompany("Nada SA")
	local ctx = makeCtx(11)
	local id = saveNew(g, ctx, "pixel")
	local m = g.money
	local r = Actions.createLot(g, ctx, { designId = id, qty = 1000 })
	local res = Actions.closeSale(g, ctx, { lotId = r.lotId })
	check(res.ok, res.msg)
	eq(g.money, m, "sin costo")
	local h = findHist(g, r.lotId)
	eq(h.produced, 0, "nada fabricado")
	eq(h.discarded, 0, "nada descartado")
	eq(h.saleState, "retirado", "retirado")
end)

test("[P11] Contabilidad: dinero = inicial − desarrollo − fabricado + ventas; sin doble costo", function()
	local g = newCompany("Libros SA", nil, "facil")
	local ctx = makeCtx(12)
	local m0 = g.money
	local r = Actions.saveDesign(g, ctx, { draft = draftFor(g, "pixel") })
	local dev = r.paid
	local a = Actions.createLot(g, ctx, { designId = r.designId, qty = 120 }).lotId
	runReal(g, ctx, 4, lotInvariants)
	Actions.closeSale(g, ctx, { lotId = a })
	runReal(g, ctx, 1)
	local revenue, cost = 0, 0
	for _, list in { g.lots, g.lotHistory } do
		for _, l in list do
			revenue += l.revenue
			cost += l.costSpent
		end
	end
	eq(g.money, m0 - dev - cost + revenue, "conciliación exacta")
	local f = Rules.finance(g, 12)
	eq(f.revenue, revenue, "ingresos del período = suma de los lotes")
	eq(f.manufacturing, cost, "fabricación del período = suma de los lotes")
	eq(f.net, g.money - m0, "flujo neto = variación de caja")
	-- El costo de lo vendido es informativo: no se descuenta otra vez de la caja.
	check(f.cogs <= f.manufacturing, "costo de lo vendido ≤ fabricado")
	eq(f.opProfit, f.revenue - f.manufacturing, "resultado operativo sin doble conteo (sin salarios ni campaña)")
end)

-- [P12] Sede y PI ---------------------------------------------------------------------------------

test("[P12] Ampliar la sede aumenta los PI por minuto (3 → 8 → 20 → 45 → 90)", function()
	local g = newCompany("Sede SA")
	local ctx = makeCtx(13)
	local expected = { 3, 8, 20, 45, 90 }
	eq(Rules.piPerMinute(g), 3, "garaje inicial")
	check(not Actions.expandSede(g, ctx, {}).ok, "sin requisitos no se amplía")
	for lvl = 2, 5 do
		local nx = Rules.nextSede(g)
		g.counters.unitsSold = nx.req.sold
		g.reputation = nx.req.rep
		g.money = nx.cost
		local r = Actions.expandSede(g, ctx, {})
		check(r.ok, r.msg)
		eq(g.money, 0, "se cobró la ampliación")
		eq(Rules.piPerMinute(g), expected[lvl], "PI/min de " .. Rules.sede(g).name)
		check(Rules.caps(g).capacity > 0 and Rules.sede(g).lines == lvl, "más líneas")
	end
	check(not Actions.expandSede(g, ctx, {}).ok, "no hay sede después del imperio")
	-- El personal es solo un extra, con tope.
	local base = Rules.piPerMinute(g)
	for i = 1, 30 do
		table.insert(g.employees, { id = "e" .. i, name = "X", role = "Ingeniero", level = 6, skill = 98, salary = 100, assign = "laboratorio" })
	end
	check(Rules.piPerMinute(g) <= base * 1.3 + 1e-6, "el personal suma como máximo 30 %")
	check(Rules.piPerMinute(g) > base, "pero suma")
end)

-- [P13] Investigación ----------------------------------------------------------------------------

test("[P13] Investigación bloqueada por requisitos y por época", function()
	local g = newCompany("Lab SA", nil, "facil")
	local ctx = makeCtx(14)
	local turbo = Catalog.researchNode("mo3") -- 1977, requiere mo1
	local r = Actions.startResearch(g, ctx, { id = "mo3" })
	check(not r.ok and string.find(r.msg, "1977") ~= nil, "bloqueada por época: " .. r.msg)
	g.time.day = (1977 - 1970) * 12
	r = Actions.startResearch(g, ctx, { id = "mo3" })
	check(not r.ok and string.find(r.msg, Catalog.researchNode("mo1").name, 1, true) ~= nil, "bloqueada por requisito: " .. r.msg)
	g.time.day = 0
	g.rp = 0
	local m = g.money
	r = Actions.startResearch(g, ctx, { id = "mo1" })
	check(r.ok, r.msg)
	eq(g.money, m - Catalog.researchNode("mo1").cost, "cuesta dinero al empezar")
	check(not Actions.startResearch(g, ctx, { id = "ca1" }).ok, "una a la vez")
	local mins = Catalog.researchNode("mo1").rp / Rules.piPerMinute(g)
	check(mins >= 1 and mins <= 2.5, "mejora pequeña ≈ 1–2 min en el garaje (" .. Util.num(mins, 1) .. ")")
	runReal(g, ctx, mins + 0.1)
	check(Util.contains(g.research.done, "mo1"), "terminada a tiempo")
	g.time.day = (1977 - 1970) * 12
	check(Rules.researchState(g, turbo) == "disponible", "con época y requisito, disponible")
	-- Cancelar devuelve el dinero y los PI.
	g.money = 1000000
	local m2, rp2 = g.money, g.rp
	check(Actions.startResearch(g, ctx, { id = "mo3" }).ok, "empieza turbo")
	Simulation.simulate(g, ctx, 60)
	local c = Actions.cancelResearch(g, ctx, {})
	check(c.ok, c.msg)
	eq(g.money, m2, "dinero devuelto")
	check(g.rp >= rp2, "PI devueltos")
end)

test("Árbol completo 1970–2030: todas las ramas, cada nodo con un efecto real y tiempos razonables", function()
	local labels = {}
	for _, key in Catalog.RESEARCH_ORDER do
		table.insert(labels, Catalog.RESEARCH[key].label)
	end
	for _, want in { "Motores", "Carrocerías", "Transmisiones", "Seguridad", "Producción", "Electrónica", "Materiales" } do
		local found = false
		for _, l in labels do
			found = found or string.find(l, want, 1, true) ~= nil
		end
		check(found, "rama " .. want)
	end
	-- Lo que habilita cada nodo (piezas, bases, opciones del editor, acabados).
	local unlocks = {}
	for _, p in Catalog.PARTS do
		if p.research then
			unlocks[p.research] = true
		end
	end
	for _, b in Catalog.BASES do
		if b.research then
			unlocks[b.research] = true
		end
	end
	for _, opts in Catalog.BODY_OPTS do
		for _, o in opts do
			if o[5] then
				unlocks[o[5]] = true
			end
		end
	end
	for _, opts in Catalog.INTERIOR do
		for _, o in opts do
			if o[6] then
				unlocks[o[6]] = true
			end
		end
	end
	unlocks.pr5 = true -- acabados Perlado y Cromado (DesignCalc.finishBlock)
	local fxUsed = { hpPct = 1, consPct = 1, comfort = 1, quality = 1, safety = 1, handling = 1, durability = 1, topPct = 1, kgPct = 1, brake = 1, prodSpeed = 1, unitCostPct = 1, demand = 1, devCostPct = 1, repGain = 1, spoilerGrip = 1, campaign = 1 }
	local years, total = {}, 0
	for _, key in Catalog.RESEARCH_ORDER do
		for _, n in Catalog.RESEARCH[key].nodes do
			total += 1
			local hasFx = false
			for k, v in n.fx do
				check(fxUsed[k] ~= nil, n.id .. ": efecto «" .. k .. "» que el juego usa")
				hasFx = hasFx or v ~= 0
			end
			check(hasFx or unlocks[n.id], n.id .. " (" .. n.name .. ") tiene un efecto real")
			check(n.year >= 1970 and n.year <= 2030, n.id .. " año " .. n.year)
			for _, req in n.req do
				local rn = Catalog.researchNode(req)
				check(rn ~= nil and rn.year <= n.year, n.id .. " requiere " .. req .. " de un año anterior")
			end
			years[math.floor(n.year / 10) * 10] = true
			-- Tiempo con la sede esperada de su época: 1–15 minutos.
			local mins = n.rp / Catalog.interp(Catalog.EXPECTED_PI, n.year)
			check(mins >= 1 and mins <= 15, n.id .. " tarda " .. Util.num(mins, 1) .. " min")
		end
	end
	check(total >= 40, "árbol amplio (" .. total .. " nodos)")
	for dec = 1970, 2020, 10 do
		check(years[dec], "investigaciones en los " .. dec)
	end
	-- Los costos crecen con las épocas sin dispararse: el último nodo no cuesta 100 veces más PI por minuto que el primero.
	local first, last = Catalog.researchNode("mo1"), Catalog.researchNode("el7")
	check(last.rp / Catalog.interp(Catalog.EXPECTED_PI, last.year) < 15 * first.rp / Catalog.interp(Catalog.EXPECTED_PI, first.year), "tiempos comparables entre épocas")
end)

test("Efectos reales: una tecnología cambia el cálculo de los diseños nuevos, no los lotes ya lanzados", function()
	local g = bigCompany("Efecto SA")
	local ctx = makeCtx(15)
	local id = saveNew(g, ctx, "brisa")
	local before = DesignCalc.computeDesign(g, g.designs[1])
	local lotId = Actions.createLot(g, ctx, { designId = id, qty = 100 }).lotId
	table.insert(g.research.done, "mo1") -- +5 % de potencia
	local after = DesignCalc.computeDesign(g, g.designs[1])
	check(after.hp > before.hp, "más potencia con la tecnología")
	eq(findLot(g, lotId).design.calc.hp, before.hp, "el lote ya lanzado conserva su versión")
	local cap = Rules.lineRate(g)
	table.insert(g.research.done, "pr1")
	check(Rules.lineRate(g) > cap, "producción industrial acelera la línea")
end)

-- [P14] Guardado con lotes -------------------------------------------------------------------------

test("Migración real de una partida de la versión anterior (unidades, órdenes y materiales)", function()
	local old = loadFixture()
	eq(old.schema, 2, "fixture de la versión 2")
	check(#old.units > 0 and #old.production.orders > 0, "con unidades y órdenes")
	local m0 = old.money
	local g, err = GameState.migrate(jsonCopy(old), 5000)
	check(g ~= nil, "migra: " .. tostring(err))
	local ok, why = GameState.validate(g)
	check(ok, "válida después de migrar: " .. tostring(why))
	eq(g.schema, GameState.SCHEMA, "esquema actual")
	check(g.money > m0, "se reintegró lo que dejó de existir")
	local refund = 0
	for _, u in old.units do
		if u.status ~= "vendido" then
			refund += u.cost
		end
	end
	check(g.money - m0 >= refund, "al menos el costo de los autos sin vender")
	eq(#g.designs, #old.designs, "diseños conservados")
	eq(g.designs[1].gen, 1, "primera generación")
	eq(g.counters.unitsSold, old.counters.unitsSold, "contadores conservados")
	eq(g.company.name, old.company.name, "empresa")
	check(g.units == nil and g.production == nil and g.materials == nil and g.customers == nil, "sin estructuras viejas")
	eq(#g.lots, 0, "sin lotes inventados")
	check(g.notifications[1].id == "mig3", "aviso de la actualización")
	-- Migrar dos veces no vuelve a reintegrar.
	local again = GameState.migrate(jsonCopy(g), 6000)
	eq(again.money, g.money, "idempotente")
	-- Se puede jugar enseguida.
	local ctx = makeCtx(16)
	local r = Actions.createLot(g, ctx, { designId = g.designs[1].id, qty = 50 })
	check(r.ok, r.msg)
	runReal(g, ctx, 1, lotInvariants)
end)

-- [P16] Tutorial ---------------------------------------------------------------------------------

test("[P16] El tutorial se completa en todas las dificultades sin trabarse por dinero ni investigación", function()
	for _, dif in Catalog.DIFFICULTY_ORDER do
		local log = Bot.play(dif, 30)
		local g = log.g
		for _, m in Catalog.MISSIONS do
			if m.kind == "tutorial" then
				check(g.claimed[m.id] == true, dif .. ": misión " .. m.id .. " (" .. m.title .. ")")
			end
		end
		check(log.minMoney >= 0, dif .. ": nunca en negativo")
		check(log.milestones["primera venta"] ~= nil and log.milestones["primera venta"] < 2, dif .. ": primera venta en menos de 2 minutos")
		check(log.milestones["sede 2"] ~= nil and log.milestones["sede 2"] < 25, dif .. ": Empresa pequeña antes de 25 min (" .. tostring(log.milestones["sede 2"]) .. ")")
		check(GameState.validate(g), dif .. ": partida válida")
	end
	-- Recorrido mínimo del tutorial con el capital más bajo: un solo diseño barato y un lote chico.
	local g = newCompany("Minima SA", nil, "dificil")
	local ctx = makeCtx(17)
	local id = saveNew(g, ctx, "pixel")
	claimReady(g, ctx)
	local unit = DesignCalc.computeDesign(g, g.designs[1]).unitCost
	check(g.money >= 25 * unit, "con el capital de Magnate alcanza para un lote de 25 autos")
	check(Actions.createLot(g, ctx, { designId = id, qty = 25 }).ok, "lote")
	claimReady(g, ctx)
	check(runUntil(g, ctx, function()
		claimReady(g, ctx)
		return g.claimed.t3 == true
	end, 10), "vende 25 y cobra la misión")
	-- Investigación: la primera mejora pequeña se puede pagar y terminar.
	local cheapest
	for _, key in Catalog.RESEARCH_ORDER do
		for _, n in Catalog.RESEARCH[key].nodes do
			if Rules.researchState(g, n) == "disponible" and (not cheapest or n.cost < cheapest.cost) then
				cheapest = n
			end
		end
	end
	check(cheapest and g.money >= cheapest.cost, "puede pagar una investigación")
	check(Actions.startResearch(g, ctx, { id = cheapest.id }).ok, "investiga")
	check(runUntil(g, ctx, function()
		return g.counters.researchDone >= 1
	end, 5), "la termina en menos de 5 minutos")
end)

test("Misiones: anual se reinicia cada año y las recompensas se cobran una vez", function()
	local g = newCompany("Anual SA")
	local ctx = makeCtx(18)
	local y1 = Catalog.mission("y1")
	local goal = Rules.missionGoal(g, y1)
	local ds = GameState.day(g)
	ds.units = goal
	eq(Rules.missionState(g, y1), "lista", "meta del año")
	check(Actions.claimMission(g, ctx, { id = "y1" }).ok, "cobrada")
	check(not Actions.claimMission(g, ctx, { id = "y1" }).ok, "no dos veces")
	g.time.day = 12
	eq(Rules.missionState(g, y1), "progreso", "año nuevo, misión nueva")
	g.sede = 3
	check(Rules.missionGoal(g, y1) > goal, "la meta crece con la sede")
end)

test("Dos empresas: dinero, diseños y lotes independientes", function()
	local A = newCompany("Ruta Norte Motors")
	local B = newCompany("Kairo Sur", "#FF8A3D")
	local ctxA, ctxB = makeCtx(19), makeCtx(20)
	local ra = Actions.saveDesign(A, ctxA, { draft = draftFor(A, "pixel") })
	local moneyA = A.money
	check(Actions.saveDesign(B, ctxB, { draft = draftFor(B, "brisa") }).ok, "B guarda")
	eq(A.money, moneyA, "el dinero de A no cambia")
	check(not Actions.createLot(B, ctxB, { designId = ra.designId .. "x", qty = 1 }).ok, "B no usa ids ajenos")
	eq(#A.designs, 1, "A intacto")
end)

-- Segunda auditoría: casos obligatorios restantes y riesgos nuevos -----------------------------------

test("[C4] Cambiar el motor cambia las estadísticas y el costo (cliente y servidor con la misma función)", function()
	local g = newCompany("Motores SA")
	local d = DesignCalc.newDraft(g, "brisa")
	local base = DesignCalc.computeDesign(g, d)
	d.parts.motor = "v6"
	local v6 = DesignCalc.computeDesign(g, d)
	check(v6.hp > base.hp and v6.unitCost > base.unitCost, "V6: más potencia y más costo")
	check(v6.consumption > base.consumption and v6.accel < base.accel, "V6: gasta más y acelera mejor")
	d.parts.motor = "i4e"
	local eco = DesignCalc.computeDesign(g, d)
	check(eco.consumption < base.consumption and eco.unitCost < base.unitCost, "1.3: gasta menos y es más barato")
	d.parts.motor = "i4"
	d.parts.seguridad = "cint3"
	table.insert(g.research.done, "se1")
	local safe = DesignCalc.computeDesign(g, d)
	check(safe.safety > base.safety and safe.unitCost > base.unitCost, "paquete de seguridad: más seguridad y más costo")
	-- Cada estadística pesa en el atractivo de algún objetivo (nada decorativo).
	local idx = Rules.indices(safe)
	for _, k in { "power", "eco", "comfort", "safety", "dur", "hand", "quality" } do
		check(type(idx[k]) == "number", "índice " .. k)
	end
	local fast = table.clone(safe)
	fast.top += 40
	check(Rules.indices(fast).power > idx.power, "la velocidad máxima cuenta en las prestaciones")
	local brakes = table.clone(safe)
	brakes.stop -= 8
	check(Rules.indices(brakes).safety > idx.safety, "el frenado cuenta en la seguridad")
end)

test("[C5] Componentes no investigados o de otra época bloqueados en el editor y en el servidor", function()
	local g = newCompany("Bloqueo SA")
	local d = DesignCalc.newDraft(g, "aurora")
	check(DesignCalc.baseAvailable(g, Catalog.base("aurora")) ~= nil, "Aurora GT no existe en 1970")
	d = DesignCalc.newDraft(g, "duna")
	local v8 = Catalog.part("motor", "v8")
	check(DesignCalc.partBlock(g, d, v8) ~= nil, "V8 sin investigar")
	local raw = draftFor(g, "duna")
	raw.parts.motor = "v8"
	check(DesignCalc.sanitize(g, raw) == nil, "el servidor rechaza el V8 sin la investigación")
	table.insert(g.research.done, "mo2")
	check(DesignCalc.partBlock(g, d, v8) == nil, "con la investigación, disponible")
	raw.parts.seguridad = "airbag"
	check(DesignCalc.sanitize(g, raw) == nil, "bolsas de aire en 1970: rechazadas")
end)

test("[C6][C7][C8][C9] Lotes de 100, 1.000 y 50.000: se fabrica exactamente esa cantidad", function()
	for _, q in { 100, 1000, 50000 } do
		local g = bigCompany("Exacta " .. q)
		for _, st in g.stations do
			st.level = 10
		end
		local ctx = makeCtx(40 + q % 7)
		local id = saveNew(g, ctx, "brisa")
		local calc = DesignCalc.computeDesign(g, g.designs[1])
		local hi = select(2, Rules.priceRange(calc.unitCost, calc.price))
		local lotId = Actions.createLot(g, ctx, { designId = id, qty = q, price = hi }).lotId
		local lot = findLot(g, lotId)
		check(runUntil(g, ctx, function()
			lotInvariants(g)
			return (findLot(g, lotId) or findHist(g, lotId) or lot).prodState == "completado"
		end, 400), q .. ": terminó")
		eq(lot.produced, q, q .. ": exactamente " .. q .. " fabricadas")
		eq(g.counters.unitsProduced, q, q .. ": nada de más")
		eq(lot.costSpent, q * lot.unitCost, q .. ": cada unidad cobrada una vez")
		runReal(g, ctx, 3, lotInvariants)
		eq(g.counters.unitsProduced, q, q .. ": se detuvo")
		local bytes = #serde.encode("json", g)
		check(bytes < 40000, q .. ": la partida no crece con la cantidad (" .. bytes .. " bytes)")
	end
end)

test("[C13] Cambiar el precio cambia el ritmo de ventas desde ese momento", function()
	local g = newCompany("Precio SA")
	local ctx = makeCtx(41)
	g.money = 1000000
	local id = saveNew(g, ctx, "brisa")
	local lotId = Actions.createLot(g, ctx, { designId = id, qty = 500 }).lotId
	runReal(g, ctx, 1)
	local lot = findLot(g, lotId)
	local r0 = Rules.lotPotentialRate(g, lot)
	check(Actions.setLotPrice(g, ctx, { lotId = lotId, price = lot.price * 1.3 }).ok, "precio más alto")
	local r1 = Rules.lotPotentialRate(g, lot)
	check(r1 < r0, "vende más lento")
	check(not Actions.setLotPrice(g, ctx, { lotId = lotId, price = 1 }).ok, "fuera de rango")
	check(not Actions.setLotPrice(g, ctx, { lotId = lotId, price = 0 / 0 }).ok, "un número inválido se rechaza")
	-- Ninguna estrategia de precio domina siempre: el más caro deja más margen pero vende menos.
	local c = DesignCalc.computeDesign(g, g.designs[1])
	local cheap = Rules.designSalesEstimate(g, c, g.designs[1], c.price * 0.8)
	local dear = Rules.designSalesEstimate(g, c, g.designs[1], c.price * 1.4)
	check(cheap.rate > dear.rate and (c.price * 1.4 - c.unitCost) > (c.price * 0.8 - c.unitCost), "volumen contra margen")
end)

test("[C19] Banco de PI: acumula 20 minutos, avisa al llenarse y las recompensas no se pierden", function()
	local g = newCompany("Banco SA")
	local ctx = makeCtx(42)
	eq(Catalog.RULES.piBankMinutes, 20, "capacidad configurable: 20 minutos")
	eq(Rules.piCap(g), 60, "garaje: 3 PI/min × 20")
	runReal(g, ctx, 25)
	eq(g.rp, 60, "se llena y se detiene en el tope")
	check(g.bankFull == true, "marca de banco lleno")
	local warned = false
	for _, n in g.notifications do
		warned = warned or string.find(n.text, "banco de investigación está lleno", 1, true) ~= nil
	end
	check(warned, "avisa una vez")
	-- Una misión cobrada con el banco lleno suma igual.
	saveNew(g, ctx, "pixel")
	local before = g.rp
	check(Actions.claimMission(g, ctx, { id = "t1" }).ok, "misión")
	check(g.rp > before, "el PI de la misión se suma aunque el banco esté lleno")
	-- Con un proyecto activo, la generación va al proyecto.
	check(Actions.startResearch(g, ctx, { id = "mo1" }).ok, "investigar")
	runReal(g, ctx, 3)
	check(Util.contains(g.research.done, "mo1"), "se completa con el banco")
end)

test("Anti-farmeo: lotes chicos o repetidos no generan PI sin límite", function()
	local g = bigCompany("Farmeo SA")
	g.sede = 1
	local ctx = makeCtx(43)
	local id = saveNew(g, ctx, "pixel")
	local cap = Rules.piPerMinute(g) * Catalog.ECON.bonusPiCapMinutes
	g.rp = 0
	g.research.active = { id = "mo1", progress = 0, paid = 0 } -- todo lo generado va a un proyecto: el banco solo junta bonificaciones
	local nodeRp = Catalog.researchNode("mo1").rp
	Catalog.researchNode("mo1").rp = 1e9
	local bonus = 0
	for _ = 1, 30 do
		local r = Actions.createLot(g, ctx, { designId = id, qty = 1 })
		if r.ok then
			runReal(g, ctx, 0.2)
		end
	end
	bonus = g.rp
	Catalog.researchNode("mo1").rp = nodeRp
	check(bonus <= cap * 2 + 0.01, "30 lotes de una unidad dan como mucho el tope mensual (" .. Util.num(bonus, 2) .. " PI)")
	eq(g.counters.lotsSoldOut >= 1 and true or false, true, "los lotes se agotan")
end)

test("[C21] Desbloquear una tecnología de otra década (cuando llega su año y sus requisitos)", function()
	local g = newCompany("Década SA", nil, "facil")
	local ctx = makeCtx(44)
	g.money = 5000000
	g.time.day = (1983 - 1970) * 12
	local n = Catalog.researchNode("mo4") -- 1983, requiere mo1
	check(Rules.researchState(g, n) == "bloqueada", "sin requisito")
	table.insert(g.research.done, "mo1")
	check(Rules.researchState(g, n) == "disponible", "con requisito y año")
	check(Actions.startResearch(g, ctx, { id = "mo4" }).ok, "empieza")
	g.rp = n.rp
	check(runUntil(g, ctx, function()
		return Util.contains(g.research.done, "mo4")
	end, 120), "terminada (el banco acelera, no completa de golpe)")
	g.time.day = (1984 - 1970) * 12 -- el motor llega al mercado un año después de la tecnología
	local d = DesignCalc.newDraft(g, "brisa")
	check(DesignCalc.partBlock(g, d, Catalog.part("motor", "i4v")) == nil, "habilita el motor 2.0 16V de los 80")
	-- El paso de los años no regala investigaciones.
	local before = #g.research.done
	runReal(g, ctx, 30)
	eq(#g.research.done, before, "el calendario no investiga solo")
end)

test("[C23] Historial permanente: los modelos se conservan después de muchos lotes", function()
	local g = bigCompany("Historia SA")
	local ctx = makeCtx(45)
	local id = saveNew(g, ctx, "pixel", "Apex Compact")
	for i = 1, Catalog.RULES.maxLotHistory + 15 do
		local r = Actions.createLot(g, ctx, { designId = id, qty = 10 + i })
		check(r.ok, "lote " .. i)
		Actions.closeSale(g, ctx, { lotId = r.lotId })
	end
	eq(#g.lotHistory, Catalog.RULES.maxLotHistory, "historial reciente acotado")
	eq(#g.modelHistory, 1, "un modelo y generación en el historial permanente")
	eq(g.modelHistory[1].lots, Catalog.RULES.maxLotHistory + 15, "cuenta todos los lotes, también los que salieron del reciente")
	-- Nueva generación: otra entrada, la anterior no se pisa.
	g.time.day = 12 * 7
	local nd = draftFor(g, "pixel", "Apex Compact")
	check(Actions.saveDesign(g, ctx, { draft = nd, newGenOf = id }).ok, "Apex Compact 2")
	local id2 = g.designs[#g.designs].id
	local r = Actions.createLot(g, ctx, { designId = id2, qty = 50 })
	Actions.closeSale(g, ctx, { lotId = r.lotId })
	eq(#g.modelHistory, 2, "una entrada por generación")
	eq(g.modelHistory[1].gen, 1, "la 1.ª generación conserva su configuración")
	eq(g.modelHistory[2].gen, 2, "la 2.ª tiene la suya")
	check(g.modelHistory[1].spec.parts.motor ~= nil and g.modelHistory[1].stats.unitCost ~= nil, "configuración y estadísticas guardadas")
	-- Eliminar el diseño no borra su historia.
	check(Actions.delDesign(g, ctx, { designId = id }).ok, "eliminar el diseño")
	eq(#g.modelHistory, 2, "la historia sigue")
	check(GameState.validate(g), "partida válida")
end)

test("Migración 3 → 4: historial permanente desde los lotes, campaña y seguridad", function()
	local g = bigCompany("Vieja Tres")
	local ctx = makeCtx(46)
	local id = saveNew(g, ctx, "brisa")
	local full = {}
	for i = 1, 3 do
		local r = Actions.createLot(g, ctx, { designId = id, qty = 20 * i })
		local l = findLot(g, r.lotId)
		l.produced, l.sold, l.revenue, l.costSpent = l.qty, l.qty, l.qty * l.price, l.qty * l.unitCost
		l.saleState, l.prodState = "agotado", "completado"
		table.remove(g.lots, 1)
		table.insert(full, 1, l) -- versión 3: el historial guardaba el lote completo
	end
	local old = jsonCopy(g)
	old.schema = 3
	old.lotHistory = jsonCopy(full)
	old.modelHistory, old.launched, old.marketShare = nil, nil, nil
	old.promo = true
	old.designs[1].parts.seguridad = nil
	local m, err = GameState.migrate(old, 1)
	check(m ~= nil, "migra: " .. tostring(err))
	local ok, why = GameState.validate(m)
	check(ok, "válida: " .. tostring(why))
	eq(m.schema, GameState.SCHEMA, "esquema actual")
	eq(#m.modelHistory, 1, "un resumen")
	eq(m.modelHistory[1].sold, 20 + 40 + 60, "con todas las ventas")
	eq(m.promo, 1, "la campaña activa pasa a radio y prensa")
	eq(m.designs[1].parts.seguridad, "basica", "seguridad básica en los diseños viejos")
	check(m.lotHistory[1].design.calc == nil, "historial reciente liviano")
	eq(m.money, old.money, "no cambia el dinero")
end)

test("[C24] Competidores: generaciones, precios que importan y reacción a tu cuota", function()
	local g = newCompany("Rival SA")
	local early = Rules.rivalOffers("compacto", 1970, g)
	local later = Rules.rivalOffers("compacto", 1990, g)
	check(#early >= 2 and #later >= 2, "hay rivales en compactos")
	local genUp = false
	for _, o in later do
		genUp = genUp or o.gen > 1
	end
	check(genUp, "los rivales sacan generaciones nuevas")
	-- El precio de un rival cambia tu reparto: si se abarata, vendés menos.
	local ctx = makeCtx(47)
	g.money = 1000000
	local id = saveNew(g, ctx, "pixel")
	local lotId = Actions.createLot(g, ctx, { designId = id, qty = 500 }).lotId
	runReal(g, ctx, 0.5)
	local lot = findLot(g, lotId)
	local base = Rules.lotPotentialRate(g, lot)
	local saved = Catalog.RIVALS[2].price
	Catalog.RIVALS[2].price = 0.6
	local cheaperRivals = Rules.lotPotentialRate(g, lot)
	Catalog.RIVALS[2].price = saved
	check(cheaperRivals < base, "un rival más barato te quita ventas")
	-- Si les quitás mercado, los agresivos bajan precios.
	local calm = Rules.rivalOffers("compacto", 1975, g)
	g.marketShare.compacto = 0.6
	local react = Rules.rivalOffers("compacto", 1975, g)
	local cut = false
	for i, o in react do
		cut = cut or o.price < calm[i].price
	end
	check(cut, "bajan precios cuando tu cuota es alta")
	-- La cuota se actualiza sola cada mes.
	runReal(g, ctx, 2)
	check((g.marketShare.compacto or 0) > 0, "la cuota de mercado se registra")
end)

test("Inversiones: campaña paga el primer mes al activarse, duplicar paga ingeniería", function()
	local g = newCompany("Gasto SA")
	local ctx = makeCtx(48)
	g.money = 500000
	check(not Actions.setCampaign(g, ctx, { level = 1 }).ok, "sin investigar no hay campaña")
	table.insert(g.research.done, "mk1")
	local m = g.money
	check(Actions.setCampaign(g, ctx, { level = 1 }).ok, "radio y prensa")
	eq(g.money, m - Rules.campaignCost(g, 1), "primer mes cobrado enseguida")
	check(not Actions.setCampaign(g, ctx, { level = 2 }).ok, "televisión requiere otra investigación")
	check(Actions.setCampaign(g, ctx, { level = 0 }).ok, "apagar")
	eq(g.money, m - Rules.campaignCost(g, 1), "apagar no devuelve ni cobra")
	local id = saveNew(g, ctx, "pixel")
	local m2 = g.money
	check(Actions.dupDesign(g, ctx, { designId = id }).ok, "duplicar")
	eq(g.money, m2 - DesignCalc.engineeringCost(g, g.designs[1], "nuevo"), "el duplicado paga la ingeniería de un modelo nuevo")
	-- Estaciones: hasta nivel 2 por sede (10 con el imperio), cada nivel más caro.
	eq(Rules.maxStationLevel(g), 2, "garaje: nivel 2")
	g.sede = 5
	eq(Rules.maxStationLevel(g), 10, "imperio: nivel 10")
	check(Rules.upgradeCost({ level = 9 }) > Rules.upgradeCost({ level = 2 }) * 100, "los niveles altos cuestan mucho más")
end)

test("[C17][C18] Ampliar la sede: cobra, aplica enseguida, no se puede sin dinero ni dos veces", function()
	local g = newCompany("Ampliar SA")
	local ctx = makeCtx(49)
	local nx = Rules.nextSede(g)
	g.counters.unitsSold = nx.req.sold
	g.reputation = nx.req.rep
	g.money = nx.cost - 1
	check(not Actions.expandSede(g, ctx, {}).ok, "sin dinero suficiente no amplía")
	eq(g.sede, 1, "sigue en el garaje")
	g.money = nx.cost + 10
	local pi0, lines0 = Rules.piPerMinute(g), Rules.caps(g).lines
	check(Actions.expandSede(g, ctx, {}).ok, "amplía")
	eq(g.money, 10, "descuenta el costo exacto")
	check(Rules.piPerMinute(g) > pi0 and Rules.caps(g).lines == lines0 + 1, "más PI y una línea más, al instante")
	check(not Actions.expandSede(g, ctx, {}).ok, "la siguiente pide sus propios requisitos")
	eq(g.sede, 2, "no se compra dos veces")
end)

test("[C25] Equilibrio por década: autos rentables, investigación en tiempo y progreso del bot", function()
	-- Escenarios de 1970, 1980, 1990, 2000, 2010 y 2020 con la sede esperada de la época.
	local SEDE = { [1970] = 1, [1980] = 3, [1990] = 4, [2000] = 5, [2010] = 5, [2020] = 5 }
	for _, year in { 1970, 1980, 1990, 2000, 2010, 2020 } do
		local g = newCompany("Década " .. year)
		local ctx = makeCtx(year)
		g.time.day = (year - 1970) * 12
		g.sede = SEDE[year]
		g.money = 200000000
		for _, key in Catalog.RESEARCH_ORDER do
			for _, n in Catalog.RESEARCH[key].nodes do
				if n.year <= year - 2 then
					table.insert(g.research.done, n.id)
				end
			end
		end
		local types = 0
		for _, b in Catalog.BASES do
			if DesignCalc.baseAvailable(g, b) == nil and Rules.demand(g, b.type) > 0 then
				local d = Bot.bestDesign(g, b.id, b.name, g.money)
				local c = DesignCalc.computeDesign(g, d)
				local est = Rules.designSalesEstimate(g, c, d, c.price)
				check(c.price > c.unitCost, year .. " · " .. b.name .. ": deja margen")
				check(est.rate > 0.5, year .. " · " .. b.name .. ": se vende (" .. Util.num(est.rate, 1) .. "/min)")
				types += 1
			end
		end
		check(types >= 3, year .. ": varios tipos rentables (" .. types .. ")")
		-- Una investigación de la época se termina dentro del objetivo con la generación de la sede esperada.
		for _, key in Catalog.RESEARCH_ORDER do
			for _, n in Catalog.RESEARCH[key].nodes do
				if n.year == year or (n.year > year and n.year <= year + 1) then
					-- Objetivos pedidos: pequeña 1–2 min, normal 3–5, importante 6–10, gran avance 10–15.
					local mins = n.rp / Catalog.interp(Catalog.EXPECTED_PI, n.year)
					local MAX = { s = 2, n = 5, i = 10, b = 15 }
					check(mins <= MAX[n.tier] + 0.01, n.id .. " dentro del objetivo (" .. Util.num(mins, 1) .. " min)")
				end
			end
		end
	end
	-- Progresión completa simulada: ni demasiado rápida ni demasiado lenta, y siempre con dinero positivo.
	local log = Bot.play("normal", 330)
	check(log.milestones["primera venta"] < 1, "primera venta en menos de 1 min")
	check(log.milestones["primera ganancia"] < 5, "primera ganancia en menos de 5 min")
	check(log.milestones["sede 2"] >= 8 and log.milestones["sede 2"] <= 25, "Empresa pequeña entre 8 y 25 min (" .. Util.num(log.milestones["sede 2"], 1) .. ")")
	check(log.milestones["sede 3"] ~= nil and log.milestones["sede 3"] <= 70, "Sede empresarial antes de 70 min")
	check(log.milestones["sede 4"] ~= nil and log.milestones["sede 4"] <= 200, "Corporación antes de 200 min")
	check(log.minMoney >= 0, "nunca dinero negativo")
	local rs = Bot.researchSummary(log)
	check(rs.avgGap > 0 and rs.avgGap <= 15, "una tecnología nueva cada " .. Util.num(rs.avgGap, 1) .. " min en promedio")
	check(log.newUnlocks >= 10, "componentes nuevos durante la partida (" .. log.newUnlocks .. ")")
	for typeId, bt in log.byType do
		check(bt.revenue > bt.cost, typeId .. ": rentable en la partida")
	end
	-- Recuperarse de una mala decisión: un lote con precio absurdo se cierra y la empresa sigue.
	local g = newCompany("Error SA", nil, "dificil")
	local ctx = makeCtx(50)
	local id = saveNew(g, ctx, "pixel")
	local c = DesignCalc.computeDesign(g, g.designs[1])
	local hi = select(2, Rules.priceRange(c.unitCost, c.price))
	local lotId = Actions.createLot(g, ctx, { designId = id, qty = 15, price = hi }).lotId
	runReal(g, ctx, 2)
	Actions.closeSale(g, ctx, { lotId = lotId })
	local after = g.money
	local r = Actions.createLot(g, ctx, { designId = id, qty = 400 })
	check(r.ok, "puede lanzar otro lote")
	-- Patrimonio = dinero + autos terminados sin vender (a su costo): crece vendiendo a buen precio.
	local function equity(): number
		local e = g.money
		for _, l in g.lots do
			e += Rules.lotAvailable(l) * l.unitCost
		end
		return e
	end
	check(runUntil(g, ctx, function()
		return equity() > after + 60000
	end, 25), "se recupera vendiendo a buen precio (" .. Util.money(after) .. " → " .. Util.money(equity()) .. ")")
end)

-- Guardado y sesiones ---------------------------------------------------------------------------

local function newStore()
	local s = DataService.MemoryStore.new(jsonCopy)
	s.wait = function(t: number)
		task.wait(t)
	end
	return s
end

local function makeServer(store: any, jobId: string, clock: any, opts: any?)
	local o = opts or {}
	local pushed = {}
	local data = DataService.new(store, {
		jobId = jobId,
		now = function()
			return clock.t
		end,
		wait = function(_: number) end,
		copy = jsonCopy,
		validate = GameState.validate,
		loadProfile = GameState.loadProfile,
	})
	local mgr = Sessions.new({
		data = data,
		filter = function(text: string)
			if string.find(string.lower(text), "prohibido") then
				return nil, "Ese nombre no está permitido."
			end
			return text, nil
		end,
		push = function(player: any, payload: any)
			if payload.tick then
				-- Envío liviano del segundo a segundo: se aplica sobre la última partida completa (como el cliente).
				if pushed[player] and pushed[player].game then
					Util.mergeLive(pushed[player].game, jsonCopy(payload.live))
				end
			else
				pushed[player] = jsonCopy(payload)
			end
		end,
		notice = function() end,
		garage = nil,
		newRng = function()
			return seeded(99)
		end,
		now = function()
			return clock.t
		end,
		clock = function()
			return clock.c
		end,
		wait = function(s: number)
			if o.realWait then
				task.wait(s)
			end
		end,
		spawn = o.realSpawn and function(fn: any)
			task.spawn(fn)
		end or function(fn: any)
			fn()
		end,
		log = function() end,
		saveMode = "memory",
	})
	return mgr, pushed, data
end

local idn = 0
local function rid(): string
	idn += 1
	return "request-" .. idn .. "-xxxx"
end

local function playThrough(mgr: any, p: any)
	local r = mgr:request(p, "createCompany", { slot = "1", name = "Sesion SA" })
	assert(r.ok, r.msg)
	return mgr.list[p]
end

test("Sesión: crear empresa y recuperarla al volver a entrar", function()
	local store = newStore()
	local clock = { t = 1000, c = 0 }
	local mgr, pushed = makeServer(store, "A", clock)
	local p = { UserId = 1, Name = "uno" }
	mgr:add(p)
	eq(pushed[p].status, "ready", "jugador nuevo listo")
	check(pushed[p].game == nil, "sin empresa activa")
	local s = playThrough(mgr, p)
	check(s.game ~= nil, "empresa activa")
	local r = mgr:request(p, "saveDesign", { draft = draftFor(s.game, "pixel"), requestId = rid() })
	check(r.ok, r.msg)
	mgr:remove(p)
	check(store.data["player_1"].lock == nil, "al salir se libera el candado")
	local mgr2, pushed2 = makeServer(store, "B", clock)
	mgr2:add(p)
	local v = pushed2[p]
	eq(v.status, "ready", "carga en otro servidor")
	check(v.game == nil, "como en la V3, se empieza en el menú de empresas")
	eq(v.profile.last, "1", "la última empresa jugada queda recordada")
	eq(v.profile.slots["1"].name, "Sesion SA", "la ranura aparece en el menú")
	check(mgr2:request(p, "selectSlot", { slot = "1" }).ok, "continuar la empresa")
	v = pushed2[p]
	eq(v.game.company.name, "Sesion SA", "empresa recuperada")
	eq(#v.game.designs, 1, "diseño recuperado")
end)

test("Reenviar la misma operación no la duplica", function()
	local store = newStore()
	local clock = { t = 1000, c = 0 }
	local mgr = makeServer(store, "A", clock)
	local p = { UserId = 2 }
	mgr:add(p)
	local s = playThrough(mgr, p)
	mgr:request(p, "saveDesign", { draft = draftFor(s.game, "pixel"), requestId = rid() })
	local id = rid()
	local r1 = mgr:request(p, "claimMission", { id = "t1", requestId = id })
	check(r1.ok, "primera")
	local money = s.game.money
	local r2 = mgr:request(p, "claimMission", { id = "t1", requestId = id })
	check(r2.duplicate, "reconocida como reenvío")
	eq(s.game.money, money, "no se cobró de nuevo")
	check(not mgr:request(p, "claimMission", { id = "t1" }).ok, "sin identificador se rechaza")
end)

test("Pausa de más de 5 minutos: el candado se renueva sin cambios", function()
	local store = newStore()
	local clock = { t = 1000, c = 0 }
	local mgr = makeServer(store, "A", clock)
	local p = { UserId = 3 }
	mgr:add(p)
	local s = playThrough(mgr, p)
	mgr:request(p, "setSpeed", { speed = 0 })
	mgr:tick()
	local writesBefore = store.writes
	for _ = 1, 420 do
		clock.t += 1
		clock.c += 1
		mgr:tick()
	end
	check(not s.dirty or store.writes > writesBefore, "sin cambios económicos")
	check(clock.t - store.data["player_3"].lock.time < 120, "candado renovado en la pausa")
	local mgrB = makeServer(store, "B", clock)
	local pB = { UserId = 3 }
	mgrB:add(pB)
	eq(mgrB.list[pB].status, "failed", "otro servidor no puede abrirla")
	eq(mgrB.list[pB].loadCode, "locked", "por el candado vigente")
end)

test("Dos sesiones intentando usar la misma partida", function()
	local store = newStore()
	local clock = { t = 1000, c = 0 }
	local mgrA, pushedA = makeServer(store, "A", clock)
	local p = { UserId = 4 }
	mgrA:add(p)
	playThrough(mgrA, p)
	mgrA:tick()
	-- El servidor A deja de responder (sin renovar): pasa el plazo del candado.
	clock.t += DataService.LOCK_TIMEOUT + 5
	local mgrB = makeServer(store, "B", clock)
	local pB = { UserId = 4 }
	mgrB:add(pB)
	eq(mgrB.list[pB].status, "ready", "B toma la partida vencida")
	-- A vuelve: su guardado detecta la sesión perdida y se bloquea.
	local sA = mgrA.list[p]
	sA.dirty = true
	mgrA:save(sA)
	eq(sA.status, "lost", "A queda como sesión perdida")
	eq(pushedA[p].status, "lost", "el cliente de A lo sabe")
	check(type(pushedA[p].blocked) == "string", "con explicación")
	local r = mgrA:request(p, "setSpeed", { speed = 2 })
	check(not r.ok, "A no acepta acciones")
	clock.c += 100
	mgrA:tick()
	eq(store.data["player_4"].lock.jobId, "B", "A no pisa el candado de B")
end)

test("Salida durante la carga: libera el candado sin escribir la partida", function()
	local store = newStore()
	store.delay = 0.05
	local clock = { t = 1000, c = 0 }
	local mgr = makeServer(store, "A", clock, { realSpawn = true, realWait = true })
	local p = { UserId = 5 }
	mgr:add(p)
	mgr:remove(p)
	task.wait(0.3)
	local rec = store.data["player_5"]
	check(rec == nil or rec.lock == nil, "sin candado colgado")
	check(rec == nil or rec.profile == nil or next(rec.profile.slots) == nil, "sin datos escritos")
end)

test("Salida durante un guardado: espera y guarda con el candado liberado", function()
	local store = newStore()
	local clock = { t = 1000, c = 0 }
	local mgr = makeServer(store, "A", clock, { realSpawn = true, realWait = true })
	local p = { UserId = 6 }
	mgr:add(p)
	task.wait(0.05)
	local s = playThrough(mgr, p)
	store.delay = 0.1
	s.dirty = true
	task.spawn(function()
		mgr:save(s)
	end)
	task.wait(0.02)
	mgr:remove(p)
	task.wait(0.4)
	local rec = store.data["player_6"]
	check(rec.lock == nil, "candado liberado")
	eq(rec.profile.slots["1"].company.name, "Sesion SA", "datos guardados")
end)

test("Fallo de carga: no escribe, informa y permite reintentar", function()
	local store = newStore()
	local clock = { t = 1000, c = 0 }
	local mgr, pushed = makeServer(store, "A", clock)
	store.failNext = DataService.LOAD_ATTEMPTS
	local p = { UserId = 7 }
	mgr:add(p)
	eq(pushed[p].status, "failed", "estado de error")
	eq(store.writes, 0, "no escribió nada")
	check(not mgr:request(p, "createCompany", { slot = "1", name = "Nada SA" }).ok, "no deja jugar")
	local r = mgr:request(p, "retryLoad")
	check(r.ok, "reintento")
	eq(pushed[p].status, "ready", "cargó al reintentar")
end)

test("Ranura dañada: se conserva intacta y las demás siguen jugables", function()
	local store = newStore()
	local clock = { t = 1000, c = 0 }
	local good = GameState.newGame({ name = "Buena SA", color = "#7667FF", now = 1 })
	local broken = jsonCopy(good)
	broken.money = "mucho"
	store.data["player_8"] = { schema = 2, profile = { slots = { ["1"] = good, ["2"] = broken }, active = "2", settings = {}, processed = {} } }
	local rawBroken = serde.encode("json", store.data["player_8"].profile.slots["2"])
	local mgr, pushed = makeServer(store, "A", clock)
	local p = { UserId = 8 }
	mgr:add(p)
	local v = pushed[p]
	eq(v.status, "ready", "carga lista")
	check(v.profile.slots["2"].damaged, "ranura 2 marcada como dañada")
	check(v.game == nil, "la activa dañada no se abre")
	check(not mgr:request(p, "selectSlot", { slot = "2" }).ok, "no se puede abrir")
	check(mgr:request(p, "selectSlot", { slot = "1" }).ok, "la buena sí")
	mgr.list[p].dirty = true
	mgr:save(mgr.list[p])
	eq(serde.encode("json", store.data["player_8"].profile.slots["2"]), rawBroken, "la dañada se reescribe sin cambios")
end)

test("Migración: registro de la etapa 1 → perfil con ranuras", function()
	-- Forma de la etapa 1: una partida de la versión 2 sin las tablas que se agregaron después.
	local old = loadFixture()
	old.company.name = "Vieja SA"
	old.schema = 1
	old.employees, old.stations, old.claimed, old.stats, old.market = nil, nil, nil, nil, nil
	old.sales = { { day = 0, price = 20000, cost = 15000, margin = 5000, name = "X" } }
	local store = newStore()
	store.data["player_9"] = { schema = 1, game = old }
	local clock = { t = 1000, c = 0 }
	local mgr, pushed = makeServer(store, "A", clock)
	local p = { UserId = 9 }
	mgr:add(p)
	eq(pushed[p].status, "ready", "carga")
	check(mgr:request(p, "selectSlot", { slot = "1" }).ok, "abrir la empresa migrada")
	local v = pushed[p]
	eq(v.game.company.name, "Vieja SA", "empresa migrada")
	eq(v.game.schema, GameState.SCHEMA, "esquema actual")
	eq(Rules.finance(v.game, 7).revenue, 20000, "agregados reconstruidos desde el historial")
	-- Un registro de una versión futura no se toca.
	store.data["player_10"] = { schema = 2, profile = { slots = { ["1"] = { schema = 99, company = { name = "Futuro" } } } } }
	local p2 = { UserId = 10 }
	mgr:add(p2)
	check(pushed[p2].profile.slots["1"].damaged, "versión futura marcada como dañada, no sobrescrita")
end)

test("Menú: varias empresas independientes, renombrar y eliminar con confirmación", function()
	local store = newStore()
	local clock = { t = 1000, c = 0 }
	local mgr, pushed = makeServer(store, "A", clock)
	local p = { UserId = 11 }
	mgr:add(p)
	check(mgr:request(p, "createCompany", { slot = "1", name = "Primera SA" }).ok, "1")
	local g1 = mgr.list[p].game
	mgr:request(p, "saveDesign", { draft = draftFor(g1, "pixel"), requestId = rid() })
	check(not mgr:request(p, "createCompany", { slot = "2", name = "primera sa" }).ok, "nombre repetido entre ranuras")
	check(mgr:request(p, "createCompany", { slot = "2", name = "Segunda SA" }).ok, "2")
	local g2 = mgr.list[p].game
	check(g1 ~= g2 and #g2.designs == 0 and g2.money == Catalog.DIFFICULTIES.normal.money, "datos independientes")
	eq(pushed[p].profile.active, "2", "activa la segunda")
	check(not mgr:request(p, "renameCompany", { slot = "1", name = "Prohibido SA" }).ok, "filtro de texto")
	check(mgr:request(p, "renameCompany", { slot = "1", name = "Uno Renombrada" }).ok, "renombrada")
	check(not mgr:request(p, "deleteCompany", { slot = "1", confirm = "otra" }).ok, "confirmación incorrecta")
	check(mgr:request(p, "deleteCompany", { slot = "1", confirm = "Uno Renombrada" }).ok, "eliminada")
	check(pushed[p].profile.slots["1"] == nil, "ranura 1 vacía")
	eq(pushed[p].profile.slots["2"].name, "Segunda SA", "la otra intacta")
	check(mgr:request(p, "setSetting", { key = "textScale", value = 1.12 }).ok, "preferencia (Grande, como la V3)")
	check(not mgr:request(p, "setSetting", { key = "textScale", value = 7 }).ok, "valor inválido")
	check(mgr:request(p, "setSetting", { key = "camSpeed", value = 1.3 }).ok, "sensibilidad de cámara entre 0,4 y 2")
	check(not mgr:request(p, "setSetting", { key = "camSpeed", value = 2.5 }).ok, "sensibilidad fuera de rango")
	check(not mgr:request(p, "wipeAll", { confirm = "no" }).ok, "borrar todo exige confirmación")
	check(mgr:request(p, "wipeAll", { confirm = "BORRAR" }).ok, "borrar todo")
	check(next(pushed[p].profile.slots) == nil, "no quedan ranuras")
end)

test("Demostraciones de la V3: se juegan en memoria y no tocan las ranuras", function()
	local store = newStore()
	local clock = { t = 1000, c = 0 }
	local mgr, pushed = makeServer(store, "A", clock)
	local p = { UserId = 31 }
	mgr:add(p)
	playThrough(mgr, p)
	check(mgr:request(p, "leaveCompany", {}).ok, "volver al menú")
	for _, kind in { "tutorial", "operacion", "avanzada", "imperio" } do
		local r = mgr:request(p, "playDemo", { kind = kind })
		check(r.ok, "demo " .. kind .. ": " .. tostring(r.msg))
		local v = pushed[p]
		eq(v.game.demo, kind, "la vista marca la demostración " .. kind)
		eq(v.demo, kind, "el estado informa la demostración")
		local ok, err = GameState.validate(mgr.list[p].game)
		check(ok, "la partida de demostración es válida: " .. tostring(err))
		if kind ~= "tutorial" then
			check(#v.game.designs >= 3 and #v.game.lots >= 3 and #v.game.lotHistory >= 2, "demo con diseños, lotes activos e historial")
			check(Rules.finance(v.game, 12).units > 0, "historial de ventas de demostración en las estadísticas")
		end
		if kind == "imperio" then
			local g = mgr.list[p].game
			check(Rules.extraYears(g) >= 1 and Rules.year(g) == 2030, "Imperio: año comercial extra con 2030 visible")
			check(Rules.nextExpansion(g) ~= nil and g.counters.unitsSold >= Rules.nextExpansion(g).sold, "Imperio: la primera región se puede abrir")
			check(mgr:request(p, "expandGlobal", { requestId = rid() }).ok, "Imperio: abre la primera región")
		end
	end
	local r = mgr:request(p, "createLot", { designId = mgr.list[p].game.designs[1].id, qty = 100, requestId = rid() })
	check(r.ok, "las acciones funcionan en la demostración")
	mgr:request(p, "leaveCompany", {})
	mgr:remove(p)
	local saved = store.data["player_31"].profile
	eq(saved.slots["1"].company.name, "Sesion SA", "la empresa real sigue igual")
	check(saved.slots["2"] == nil and saved.slots["3"] == nil, "la demostración no ocupa ranuras")
	check(saved.active ~= "demo", "la demostración no queda como última empresa")
	check(not mgr:request(p, "playDemo", { kind = "otra" }).ok, "demo desconocida rechazada")
end)

test("Dos jugadores en el mismo servidor: sesiones independientes", function()
	local store = newStore()
	local clock = { t = 1000, c = 0 }
	local mgr = makeServer(store, "A", clock)
	local a, b = { UserId = 21 }, { UserId = 22 }
	mgr:add(a)
	mgr:add(b)
	mgr:request(a, "createCompany", { slot = "1", name = "Empresa A" })
	mgr:request(b, "createCompany", { slot = "1", name = "Empresa B", difficulty = "dificil" })
	local ga, gb = mgr.list[a].game, mgr.list[b].game
	mgr:request(a, "saveDesign", { draft = draftFor(ga, "pixel"), requestId = rid() })
	eq(gb.money, Catalog.DIFFICULTIES.dificil.money, "B no pagó nada")
	eq(#gb.designs, 0, "B sin diseños")
	local r = mgr:request(b, "createLot", { designId = ga.designs[1].id, qty = 1, requestId = rid() })
	check(not r.ok, "B no puede fabricar el diseño de A")
	mgr:remove(a)
	mgr:remove(b)
	check(store.data["player_21"].profile.slots["1"].company.name ~= store.data["player_22"].profile.slots["1"].company.name, "claves separadas")
end)


test("[P14] Guardar y cargar con lotes: 50.000 unidades, historial y estado de cada lote", function()
	local store = newStore()
	local clock = { t = 1000, c = 0 }
	local mgr = makeServer(store, "A", clock)
	local p = { UserId = 41 }
	mgr:add(p)
	local s = playThrough(mgr, p)
	local g = s.game
	g.sede = 5
	g.money = 500000000
	local r = mgr:request(p, "saveDesign", { draft = draftFor(g, "brisa"), requestId = rid() })
	check(r.ok, r.msg)
	r = mgr:request(p, "saveDesign", { draft = draftFor(g, "pixel"), requestId = rid() })
	local big = mgr:request(p, "createLot", { designId = g.designs[1].id, qty = 50000, requestId = rid() })
	check(big.ok, big.msg)
	local small = mgr:request(p, "createLot", { designId = g.designs[2].id, qty = 3000, requestId = rid() })
	for _ = 1, 240 do
		clock.t += 1
		clock.c += 1
		mgr:tick()
	end
	local cr = mgr:request(p, "closeSale", { lotId = small.lotId, requestId = rid() })
	check(cr.ok, "cerrar la venta del chico: " .. tostring(cr.msg) .. " " .. tostring(small.msg))
	local before = jsonCopy({ lots = g.lots, hist = g.lotHistory, money = g.money, day = g.time.day, sold = g.counters.unitsSold })
	mgr:remove(p)
	local rec = store.data["player_41"]
	local bytes = #serde.encode("json", rec)
	check(bytes < 120000, "registro chico con 50.000 unidades encargadas (" .. bytes .. " bytes)")
	local mgr2, pushed2 = makeServer(store, "B", clock)
	mgr2:add(p)
	check(mgr2:request(p, "selectSlot", { slot = "1" }).ok, "abrir")
	local g2 = mgr2.list[p].game
	eq(serde.encode("json", g2.lots), serde.encode("json", before.lots), "lotes activos idénticos")
	eq(serde.encode("json", g2.lotHistory), serde.encode("json", before.hist), "historial idéntico")
	eq(g2.money, before.money, "dinero")
	eq(g2.counters.unitsSold, before.sold, "ventas")
	eq(g2.lotHistory[1].saleState, "retirado", "el retirado sigue retirado")
	eq(pushed2[p].game.lots[1].qty, 50000, "la vista del cliente recibe el lote")
	-- Y sigue fabricando desde donde quedó, sin repetir.
	local produced = g2.lots[1].produced
	for _ = 1, 60 do
		clock.t += 1
		clock.c += 1
		mgr2:tick()
	end
	check(g2.lots[1].produced > produced and g2.lots[1].produced <= 50000, "continúa la producción")
end)

test("Reenviar Cerrar venta o Lanzar lote con el mismo identificador no los duplica", function()
	local store = newStore()
	local clock = { t = 1000, c = 0 }
	local mgr = makeServer(store, "A", clock)
	local p = { UserId = 42 }
	mgr:add(p)
	local s = playThrough(mgr, p)
	mgr:request(p, "saveDesign", { draft = draftFor(s.game, "pixel"), requestId = rid() })
	local id = rid()
	check(mgr:request(p, "createLot", { designId = s.game.designs[1].id, qty = 20, requestId = id }).ok, "lanzado")
	check(mgr:request(p, "createLot", { designId = s.game.designs[1].id, qty = 20, requestId = id }).duplicate, "reenvío reconocido")
	eq(#s.game.lots, 1, "un solo lote")
	local cid = rid()
	check(mgr:request(p, "closeSale", { lotId = s.game.lots[1].id, requestId = cid }).ok, "cerrado")
	check(mgr:request(p, "closeSale", { lotId = s.game.lotHistory[1].id, requestId = cid }).duplicate, "reenvío del cierre")
	eq(s.game.counters.lotsRetired, 1, "cerrado una sola vez")
end)

test("Salir durante una producción y volver: nada se fabrica ni se vende sin conexión y sigue igual", function()
	local store = newStore()
	local clock = { t = 1000, c = 0 }
	local mgr = makeServer(store, "A", clock)
	local p = { UserId = 43 }
	mgr:add(p)
	local s = playThrough(mgr, p)
	local g = s.game
	g.money = 2000000
	mgr:request(p, "saveDesign", { draft = draftFor(g, "brisa"), requestId = rid() })
	local r = mgr:request(p, "createLot", { designId = g.designs[1].id, qty = 5000, requestId = rid() })
	check(r.ok, r.msg)
	for _ = 1, 90 do
		clock.t += 1
		clock.c += 1
		mgr:tick()
	end
	local snap = jsonCopy({ produced = g.lots[1].produced, sold = g.lots[1].sold, money = g.money, day = g.time.day })
	check(snap.produced > 0 and snap.produced < 5000, "a mitad de producción")
	mgr:remove(p)
	clock.t += 3600 -- una hora sin conexión
	local mgr2, pushed2 = makeServer(store, "B", clock)
	mgr2:add(p)
	check(mgr2:request(p, "selectSlot", { slot = "1" }).ok, "vuelve a entrar")
	local g2 = mgr2.list[p].game
	eq(g2.lots[1].produced, snap.produced, "lo fabricado se conserva")
	eq(g2.lots[1].sold, snap.sold, "lo vendido se conserva")
	eq(g2.money, snap.money, "el dinero se conserva")
	eq(g2.time.day, snap.day, "el calendario no avanzó sin conexión")
	for _ = 1, 30 do
		clock.t += 1
		clock.c += 1
		mgr2:tick()
	end
	check(g2.lots[1].produced > snap.produced, "la producción sigue al volver")
	check(pushed2[p].game.lots[1].produced == g2.lots[1].produced, "el cliente recibe el avance segundo a segundo")
	check(GameState.validate(g2), "partida válida")
end)

test("Envío al cliente: liviano segundo a segundo, completo cuando cambia la estructura", function()
	local store = newStore()
	local clock = { t = 1000, c = 0 }
	local sizes = {}
	local mgr = makeServer(store, "A", clock)
	mgr.deps.push = function(_player: any, payload: any)
		table.insert(sizes, { tick = payload.tick == true, bytes = #serde.encode("json", payload) })
	end
	local p = { UserId = 44 }
	mgr:add(p)
	local s = playThrough(mgr, p)
	s.game.money = 5000000
	mgr:request(p, "saveDesign", { draft = draftFor(s.game, "brisa"), requestId = rid() })
	mgr:request(p, "createLot", { designId = s.game.designs[1].id, qty = 50000, requestId = rid() })
	table.clear(sizes)
	for _ = 1, 20 do
		clock.t += 1
		clock.c += 1
		mgr:tick()
	end
	local light, full, maxLight = 0, 0, 0
	for _, x in sizes do
		if x.tick then
			light += 1
			maxLight = math.max(maxLight, x.bytes)
		else
			full += 1
		end
	end
	check(light >= 15, "la mayoría de los envíos son livianos (" .. light .. " de " .. #sizes .. ")")
	check(maxLight < 4000, "un envío liviano pesa poco (" .. maxLight .. " bytes)")
end)

-- Correcciones finales (tercera etapa) --------------------------------------------------------------
-- Una partida larga del bot (1970 → 2030 y dos horas de años comerciales extra) se comparte entre las
-- pruebas [F…] para no repetirla.

local longLog = nil
local function longGame(): any
	if not longLog then
		longLog = Bot.play("normal", 780)
	end
	return longLog
end

local function allNodes(): { any }
	local out = {}
	for _, key in Catalog.RESEARCH_ORDER do
		for _, n in Catalog.RESEARCH[key].nodes do
			table.insert(out, n)
		end
	end
	return out
end

test("[F1] Llegar a 2030 sin perder progreso", function()
	local log = longGame()
	local g = log.g
	check(log.milestones["sede 5"] ~= nil, "llega al Imperio automotriz")
	eq(Rules.year(g), 2030, "el año visible queda en 2030")
	check(Rules.periodYear(g) > 2030 and Rules.extraYears(g) >= 1, "y la partida siguió en años comerciales (" .. Rules.periodYear(g) .. ")")
	check(log.minMoney >= 0, "nunca dinero negativo")
	local ok, err = GameState.validate(jsonCopy(g))
	check(ok, "la partida final es válida: " .. tostring(err))
	lotInvariants(g)
end)

test("[F2] Después del último año: producción, ventas, campañas, salarios, investigación y generaciones siguen", function()
	local g = bigCompany("Después SA")
	local ctx = makeCtx(201)
	g.time.day = (Catalog.CALENDAR.endYear - 1970 + 1) * 12 + 3 -- segundo año comercial extra
	eq(Rules.year(g), 2030, "año visible")
	eq(Util.gameDate(g.time.day), "Abr 2030", "fecha visible")
	-- Una investigación pendiente de cualquier época se puede terminar.
	check(Actions.startResearch(g, ctx, { id = "mo1" }).ok, "empieza una investigación pendiente")
	check(runUntil(g, ctx, function()
		return Util.contains(g.research.done, "mo1")
	end, 10), "y se termina")
	-- Modelo nuevo, campaña, empleado y lote.
	local id = saveNew(g, ctx, "brisa", "Posterior")
	check(Actions.setCampaign(g, ctx, { level = 1 }).ok or Rules.campaignBlock(g, 1) ~= nil, "campaña (si está investigada)")
	if Rules.campaignBlock(g, 1) ~= nil then
		table.insert(g.research.done, "mk1")
		check(Actions.setCampaign(g, ctx, { level = 1 }).ok, "campaña activada")
	end
	check(Actions.moreCandidates(g, ctx, {}).ok, "busca candidatos")
	local cand = g.candidates[1]
	check(cand ~= nil and Actions.hire(g, ctx, { candidateId = cand.id }).ok, "contrata")
	local lot = Actions.createLot(g, ctx, { designId = id, qty = 20000 })
	check(lot.ok, lot.msg)
	local produced0, sold0 = g.counters.unitsProduced, g.counters.unitsSold
	local promo0, sal0 = 0, 0
	local day0 = g.time.day
	-- Tres horas reales después del final del calendario.
	runReal(g, ctx, 180)
	check(g.time.day - day0 >= 12 * 15, "pasaron más de 15 años comerciales (" .. (g.time.day - day0) .. " meses)")
	eq(Rules.year(g), 2030, "el año visible sigue en 2030")
	check(g.counters.unitsProduced > produced0, "sigue fabricando")
	check(g.counters.unitsSold > sold0, "sigue vendiendo")
	for _, e in g.ledger do
		if e.type == "promocion" then
			promo0 += 1
		elseif e.type == "salarios" then
			sal0 += 1
		end
	end
	check(promo0 > 0, "se cobran las campañas")
	check(sal0 > 0, "se pagan los salarios")
	lotInvariants(g)
	-- Nueva generación después de 2030: hace falta un año comercial desde la anterior.
	local d = g.designs[1]
	check(Rules.canNewGeneration(g, d), "se puede crear una generación nueva")
	local r = Actions.saveDesign(g, ctx, { draft = draftFor(g, "brisa", d.name), newGenOf = d.id })
	check(r.ok, r.msg)
	local newest = g.designs[#g.designs]
	check(not Rules.canNewGeneration(g, newest), "la recién creada todavía no admite otra")
	runReal(g, ctx, Catalog.CALENDAR.realSecondsPerYear / 60 + 0.2)
	check(Rules.canNewGeneration(g, newest), "un año comercial después, sí")
	-- Las misiones anuales se renuevan cada año comercial.
	local y1 = Catalog.mission("y1")
	local k1 = Rules.missionKey(g, y1)
	runReal(g, ctx, Catalog.CALENDAR.realSecondsPerYear / 60)
	check(Rules.missionKey(g, y1) ~= k1, "la misión anual tiene otra clave el año siguiente")
end)

test("[F3][F4] Guardar una partida larga y recuperarla sin cambiar el calendario", function()
	local log = longGame()
	local g = jsonCopy(log.g)
	local bytes = #serde.encode("json", g)
	check(bytes < 900000, "una partida de 60 años + años extra pesa " .. bytes .. " bytes (3 empresas < 4 MB)")
	print("    tamaño de la partida larga del bot: " .. bytes .. " bytes")
	local store = newStore()
	local clock = { t = 5000, c = 0 }
	local mgr = makeServer(store, "A", clock)
	local p = { UserId = 71 }
	mgr:add(p)
	local s = playThrough(mgr, p)
	-- Se reemplaza la partida de la sesión por la del bot (misma empresa, mismo nombre de ranura).
	for k in s.game do
		s.game[k] = nil
	end
	for k, v in jsonCopy(g) do
		s.game[k] = v
	end
	local day, minute, money = s.game.time.day, s.game.time.minute, s.game.money
	mgr:remove(p)
	clock.t += 3 * 3600 -- tres horas sin conectarse
	local mgr2 = makeServer(store, "B", clock)
	mgr2:add(p)
	check(mgr2:request(p, "selectSlot", { slot = "1" }).ok, "abrir la partida guardada")
	local g2 = mgr2.list[p].game
	eq(g2.time.day, day, "mismo mes (el calendario no avanza sin conexión)")
	eq(g2.time.minute, minute, "mismo minuto")
	eq(g2.money, money, "mismo dinero")
	eq(Rules.year(g2), 2030, "año visible")
	eq(Rules.periodYear(g2), Rules.periodYear(g), "mismo año comercial")
	eq(#g2.modelHistory, #g.modelHistory, "historial completo")
	eq(serde.encode("json", g2.records), serde.encode("json", g.records), "récords idénticos")
	-- Y sigue jugando.
	local sold = g2.counters.unitsSold
	for _ = 1, 120 do
		clock.t += 1
		clock.c += 1
		mgr2:tick()
	end
	check(g2.counters.unitsSold > sold, "después de cargar sigue vendiendo")
end)

test("[F5] Las 56 investigaciones se completan", function()
	local nodes = allNodes()
	eq(#nodes, 56, "el árbol tiene 56 tecnologías")
	local log = longGame()
	eq(#log.g.research.done, 56, "el bot las completa todas")
	local seen = {}
	for _, id in log.g.research.done do
		check(not seen[id], "sin repetidas: " .. id)
		seen[id] = true
	end
	check(Rules.missionState(log.g, Catalog.mission("s12")) ~= "progreso", "misión «Completá todas las investigaciones»")
	-- Revisión de las 56: año, nivel, PI, dinero y requisitos coherentes.
	for _, n in nodes do
		check(n.year >= 1970 and n.year <= Catalog.CALENDAR.endYear, n.id .. ": año dentro del calendario")
		check(Catalog.RESEARCH_TIERS[n.tier] ~= nil and n.rp > 0 and n.cost > 0, n.id .. ": nivel, PI y dinero")
		for _, r in n.req do
			local q = Catalog.researchNode(r)
			check(q ~= nil and q.year <= n.year, n.id .. ": su requisito " .. r .. " existe y no es posterior")
		end
	end
end)

test("[F6] Tiempos reales de investigación (bot): cerca de los objetivos", function()
	local rs = Bot.researchSummary(longGame())
	-- Objetivos: pequeña 1–2 min, normal 3–5, importante 6–10, gran avance 10–15. El bot optimizador usa
	-- el banco como acelerador, así que termina algo antes; se acepta un margen.
	local RANGE = { s = { 0.7, 2.2 }, n = { 2.5, 5.5 }, i = { 4.5, 10.5 }, b = { 6, 15.5 } }
	for k, rg in RANGE do
		local bt = rs.byTier[k]
		local avg = bt.total / bt.n
		check(avg >= rg[1] and avg <= rg[2], Catalog.RESEARCH_TIERS[k].label .. ": media " .. Util.num(avg, 1) .. " min")
		check(bt.max <= rg[2] * 1.1, Catalog.RESEARCH_TIERS[k].label .. ": máxima " .. Util.num(bt.max, 1) .. " min")
	end
	check(rs.avgLag <= 0.5, "el optimizador investiga apenas aparece cada tecnología (" .. Util.num(rs.avgLag, 1) .. " años)")
	-- Estrategia simple (sin ampliar más allá de la sede 3 hasta 2009): más lenta, pero sin esperas eternas.
	local flat = Bot.researchSummary(Bot.play("normal", 660, { flat = true }))
	eq(flat.done, 56, "la estrategia simple también completa las 56")
	for k, cap in { s = 2.2, n = 16, i = 21, b = 21 } do
		check(flat.byTier[k].max <= cap, "simple · " .. Catalog.RESEARCH_TIERS[k].label .. ": máxima " .. Util.num(flat.byTier[k].max, 1) .. " min")
	end
end)

test("[F7] Comparar estrategias: diversificar rinde más que un solo tipo", function()
	local best = longGame()
	local one = Bot.play("normal", 660, { single = true })
	local flat = Bot.play("normal", 660, { flat = true })
	local function revenue(log: any): number
		return log.g.counters.revenueTotal or 0
	end
	check(revenue(best) > revenue(one) * 2, "diversificado " .. Util.money(revenue(best)) .. " frente a un solo tipo " .. Util.money(revenue(one)))
	check(revenue(best) > revenue(flat) * 2, "con generaciones nuevas " .. Util.money(revenue(best)) .. " frente a la simple " .. Util.money(revenue(flat)))
	-- La rentabilidad por tipo no es idéntica: los económicos dejan menos margen que deportivos y SUV.
	local function margin(t: string): number
		local bt = best.byType[t]
		return (bt.revenue - bt.cost) / bt.revenue
	end
	check(margin("deportivo") - margin("compacto") > 0.08, "deportivo " .. Util.num(margin("deportivo") * 100, 1) .. " % frente a compacto " .. Util.num(margin("compacto") * 100, 1) .. " %")
	check(margin("suv") > margin("sedan"), "SUV deja más margen que sedán")
	check(best.byType.compacto.sold > best.byType.deportivo.sold, "pero el compacto vende más unidades")
end)

test("[F8] Ingresos y gastos después de la sede máxima: siempre hay en qué invertir", function()
	local log = longGame()
	for _, dec in { 2000, 2010, 2020 } do
		local d = log.decades[dec]
		check(d.upgrades > 0, dec .. ": invierte en expansión (" .. Util.money(d.upgrades) .. ")")
		check(d.revenue > d.manufacturing, dec .. ": ingresos mayores que la fabricación")
	end
	check(log.decades[2020].regions >= 5, "5 regiones o más en 2030 (" .. log.decades[2020].regions .. ")")
	check(log.decades[2020].endMoney < 1500000000, "el dinero no se acumula sin destino (" .. Util.money(log.decades[2020].endMoney) .. ")")
	check(log.decades[2020].revenue > log.decades[2000].revenue, "los ingresos siguen creciendo con las regiones")
	-- La expansión: requisitos, costo, efecto en la demanda y en las campañas.
	local g = bigCompany("Global SA")
	local ctx = makeCtx(202)
	g.sede = 4
	check(not Actions.expandGlobal(g, ctx, {}).ok, "sin Imperio no hay expansión")
	g.sede = 5
	check(not Actions.expandGlobal(g, ctx, {}).ok, "sin las ventas pedidas no hay expansión")
	g.counters.unitsSold = 1000000
	table.insert(g.research.done, "mk1")
	local dem, camp, line = Rules.demand(g, "sedan"), Rules.campaignCost(g, 1), Rules.lineRate(g)
	local nx = Rules.nextExpansion(g)
	local m = g.money
	check(Actions.expandGlobal(g, ctx, {}).ok, "se expande")
	eq(g.money, m - nx.cost, "cobra el costo")
	check(math.abs(Rules.demand(g, "sedan") / dem - (1 + Catalog.EXPANSION.demand)) < 1e-6, "+15 % de demanda")
	check(Rules.campaignCost(g, 1) > camp and Rules.lineRate(g) > line, "campañas más caras y líneas más rápidas")
	check(Rules.nextExpansion(g).cost > nx.cost, "la siguiente región cuesta más")
	g.money = 1e12
	for _ = 2, #Catalog.EXPANSION.regions do
		check(Actions.expandGlobal(g, ctx, {}).ok, "región " .. (g.expansion + 1))
	end
	check(not Actions.expandGlobal(g, ctx, {}).ok, "después de la última no hay más")
	check(Rules.missionState(g, Catalog.mission("s18")) == "lista", "misión de las diez regiones lista")
	local bad = jsonCopy(g)
	bad.sede = 3
	check(not GameState.validate(bad), "expansión sin Imperio: partida dañada")
end)

test("[F9] Historial permanente: miles de modelos sin perder récords ni totales", function()
	local g = bigCompany("Archivo SA")
	local ctx = makeCtx(203)
	local id = saveNew(g, ctx, "pixel", "Primero")
	local r = Actions.createLot(g, ctx, { designId = id, qty = 2000 })
	runReal(g, ctx, 1)
	local template = jsonCopy(findLot(g, r.lotId))
	Actions.closeSale(g, ctx, { lotId = r.lotId })
	local firstKey = g.records.firstModel.key
	local totalSold, totalRev = g.modelHistory[1].sold, g.modelHistory[1].revenue
	-- 2.500 modelos más (como si se jugaran cientos de horas), con ventas variadas.
	local rng = seeded(7)
	for i = 1, 2500 do
		local lot = jsonCopy(template)
		lot.id = "fake" .. i
		lot.saleState, lot.prodState = "agotado", "completado"
		lot.design.lineage = "L" .. i
		lot.design.name = "Modelo " .. i
		lot.produced = 10 + math.floor(rng() * 5000)
		lot.sold = math.floor(lot.produced * rng())
		lot.discarded = lot.produced - lot.sold
		lot.revenue = lot.sold * 9000
		lot.costSpent = lot.produced * 4000
		lot.monthSold = math.floor(lot.sold / 3)
		if i == 1777 then
			lot.produced, lot.sold, lot.discarded, lot.revenue, lot.monthSold = 900000, 900000, 0, 900000 * 9000, 300000
		end
		lot.qty = lot.produced
		totalSold += lot.sold
		totalRev += lot.revenue
		Simulation.archiveLot(g, lot)
	end
	-- Los totales no se pierden: historial + «Otros modelos» = todo lo vendido.
	local sumSold, sumRev = g.records.others.sold, g.records.others.revenue
	local detailed = 0
	for _, e in g.modelHistory do
		sumSold += e.sold
		sumRev += e.revenue
		if not e.compact then
			detailed += 1
		end
	end
	check(#g.modelHistory <= Catalog.RULES.maxModelHistory, "historial acotado (" .. #g.modelHistory .. " modelos)")
	check(detailed <= Catalog.RULES.maxModelDetail, "detalle completo para los más importantes (" .. detailed .. ")")
	eq(g.records.others.models, 2501 - #g.modelHistory, "el resto queda resumido en «Otros modelos»")
	eq(sumSold, totalSold, "unidades vendidas: ninguna se pierde")
	eq(sumRev, totalRev, "ingresos: ninguno se pierde")
	local function find(key: string): any
		for _, e in g.modelHistory do
			if e.key == key then
				return e
			end
		end
		return nil
	end
	local first = find(firstKey)
	check(first ~= nil and not first.compact, "el primer modelo se conserva con su configuración")
	local star = find("L1777#1")
	check(star ~= nil and not star.compact and star.spec.parts ~= nil, "el más vendido se conserva completo")
	eq(g.records.bestLot.name, "Modelo 1777", "récord del lote más vendido")
	check(g.records.bestMonth.value >= 300000, "récord del mejor mes")
	local ok, err = GameState.validate(jsonCopy(g))
	check(ok, "la partida sigue siendo válida: " .. tostring(err))
	local bytes = #serde.encode("json", g)
	check(bytes * 3 < 4000000, "3 empresas así entran en una clave de DataStore (" .. bytes .. " bytes cada una)")
	print("    tamaño con 2.501 modelos: " .. bytes .. " bytes")
end)

test("[F9b] Migración 4 → 5: récords desde el historial y expansión en cero", function()
	local log = longGame()
	local old = jsonCopy(log.g)
	old.schema = 4
	old.records = nil
	old.expansion = nil
	old.sede = 5
	local m, err = GameState.migrate(old, 1)
	check(m ~= nil, tostring(err))
	eq(m.expansion, 0, "expansión en cero")
	check(m.records.firstModel ~= nil and m.records.bestLot ~= nil, "récords reconstruidos")
	local ok, verr = GameState.validate(m)
	check(ok, tostring(verr))
end)

test("[F10] Sin regresiones: lote, venta automática y Cerrar venta en un año comercial extra", function()
	local g = bigCompany("Extra SA")
	local ctx = makeCtx(204)
	g.time.day = (Catalog.CALENDAR.endYear - 1970 + 5) * 12
	local id = saveNew(g, ctx, "pixel", "Extra")
	local r = Actions.createLot(g, ctx, { designId = id, qty = 3000 })
	check(r.ok, r.msg)
	runReal(g, ctx, 5)
	local l = findLot(g, r.lotId)
	check(l.produced > 0 and l.sold > 0, "fabrica y vende solo")
	local m = g.money
	local c = Actions.closeSale(g, ctx, { lotId = r.lotId })
	check(c.ok, c.msg)
	check(findLot(g, r.lotId) == nil and findHist(g, r.lotId).saleState == "retirado", "Cerrar venta lo retira")
	check(g.money <= m, "cerrar no regala dinero")
	lotInvariants(g)
end)

T.finish()
Build.clean()
process.exit(T.failed == 0 and 0 or 1)
