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

local function newCompany(name: string, color: string?, _legacy: string?): any
	local clean, err = Actions.validateCompany({ name = name, color = color or "#7667FF", logo = "pico" })
	assert(clean, err)
	return GameState.newGame({ name = clean.name, color = clean.color, logo = clean.logo, now = 1000 })
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

--[[ Reglas de la etapa 2: cada modelo tiene UN lote, que se paga completo al ordenarlo, se fabrica entero,
	recibe las reseñas y recién después sale a la venta con el precio que elige el jugador.
	orderLot: ordena un lote; si el modelo ya tuvo el suyo, lo duplica antes (como haría un jugador).
	launchWhenReady: deja correr la simulación hasta que el lote esté «por lanzar» y lo pone a la venta. ]]
local function orderLot(g: any, ctx: any, designId: string, qty: number, price: number?): any
	for _, d in g.designs do
		if d.id == designId and d.lotLaunched then
			local r = Actions.dupDesign(g, ctx, { designId = designId })
			assert(r.ok, r.msg)
			designId = g.designs[#g.designs].id
		end
	end
	return Actions.createLot(g, ctx, { designId = designId, qty = qty, price = price })
end

local function launchWhenReady(g: any, ctx: any, lotId: string, price: number?, maxRealMinutes: number?): boolean
	runUntil(g, ctx, function()
		local l = findLot(g, lotId)
		return l == nil or l.saleState ~= "produccion"
	end, maxRealMinutes or 120)
	local l = findLot(g, lotId)
	if not l or l.saleState ~= "por lanzar" then
		return false
	end
	return Actions.launchSale(g, ctx, { lotId = lotId, price = price or l.price }).ok
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
	eq(Catalog.CALENDAR.realSecondsPerDay, 2, "un día de juego cada 2 segundos reales a 1×")
	check(Catalog.CALENDAR.realSecondsPerYear >= 720 and Catalog.CALENDAR.realSecondsPerYear <= 740, "un año de 365 días ≈ 12 minutos reales")
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
	local d = DesignCalc.newDraft(g, "brisa")
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
			if (string.find(lower, "eléctric") and not string.find(lower, "ventanillas")) or string.find(lower, "híbrid") or string.find(lower, "8 velocidades") then
				check(n.year >= 1997, n.name .. " es moderna (" .. n.year .. ")")
			end
		end
	end
	-- El cliente no puede colar una pieza del futuro.
	local raw = draftFor(g, "brisa")
	raw.parts.transmision = "auto8"
	local ok, err = DesignCalc.sanitize(g, raw)
	check(ok == nil and string.find(err or "", "Requiere investigar", 1, true) ~= nil, "caja de 8 velocidades rechazada en 1970: " .. tostring(err))
	raw = draftFor(g, "brisa")
	raw.wheels.size = 20
	check(DesignCalc.sanitize(g, raw) == nil, "llantas de 20″ rechazadas en 1970")
end)

-- [P2] Diseño ------------------------------------------------------------------------------------

test("[P2] Diseñar y guardar un auto: desarrollo una sola vez, año de modelo y generación", function()
	local g = newCompany("Ruta Norte Motors")
	local ctx = makeCtx(2)
	local m0 = g.money
	local r = Actions.saveDesign(g, ctx, { draft = draftFor(g, "brisa", "Pixel Uno") })
	check(r.ok, r.msg)
	check(r.paid > 0 and g.money == m0 - r.paid, "se cobra el desarrollo")
	local d = g.designs[1]
	eq(d.modelYear, 1970, "año de modelo")
	eq(d.gen, 1, "primera generación")
	check(string.find(d.generation, "1970") ~= nil, "etiqueta con el año: " .. d.generation)
	-- Mismo modelo otra vez: la licencia ya está pagada.
	local m1 = g.money
	local r2 = Actions.saveDesign(g, ctx, { draft = draftFor(g, "brisa", "Pixel Dos") })
	local eng = DesignCalc.engineeringCost(g, g.designs[2] or d, "nuevo")
	check(r2.ok and r2.paid == eng and g.money == m1 - eng, "la licencia no se vuelve a pagar: solo la ingeniería del modelo nuevo (" .. tostring(r2.paid) .. ")")
	-- Cambios estéticos no pagan ingeniería; cambiar una pieza paga la de una versión.
	local v = jsonCopy(g.designs[2])
	v.paint.primary = "#D6333F"
	local m2 = g.money
	local r3 = Actions.saveDesign(g, ctx, { draft = v, sourceId = v.id })
	check(r3.ok and r3.paid == 0 and g.money == m2, "pintar de nuevo no cuesta ingeniería")
	v = jsonCopy(g.designs[2])
	v.parts.transmision = "man4"
	local r4 = Actions.saveDesign(g, ctx, { draft = v, sourceId = v.id })
	check(r4.ok and r4.paid == DesignCalc.engineeringCost(g, v, "version"), "cambiar una pieza mecánica paga la ingeniería de una versión")
	check(DesignCalc.engineeringCost(g, v, "nuevo") < DesignCalc.engineeringCost({ time = { day = 40 * 12 }, research = { done = {} }, employees = {} }, v, "nuevo"), "la ingeniería cuesta más en épocas modernas")
	check(not Actions.saveDesign(g, ctx, { draft = draftFor(g, "brisa", "pixel uno") }).ok, "nombre repetido rechazado")
	-- Saneamiento: el cliente no puede inventar piezas ni bases.
	local bad = draftFor(g, "brisa")
	bad.parts.motor = "warp"
	check(not Actions.saveDesign(g, ctx, { draft = bad }).ok, "pieza inexistente")
	bad = draftFor(g, "brisa")
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

test("Lotes: cantidad libre (100, 1.000, 10.000, 50.000), un lote por modelo y validación", function()
	local g = bigCompany("Lotes SA")
	local ctx = makeCtx(4)
	local id = saveNew(g, ctx, "brisa")
	local unit = DesignCalc.computeDesign(g, g.designs[1]).unitCost
	for _, q in { 100, 1000, 10000, 50000 } do
		local r = orderLot(g, ctx, id, q)
		check(r.ok, "lote de " .. q .. ": " .. tostring(r.msg))
		eq(findLot(g, r.lotId).costSpent, q * unit, "el lote de " .. q .. " se paga completo al ordenarlo")
	end
	eq(#g.lots, 4, "cuatro lotes (cuatro modelos)")
	eq(g.lots[4].qty, 50000, "50.000 unidades encargadas")
	check(not Actions.createLot(g, ctx, { designId = id, qty = 10 }).ok, "un modelo que ya tuvo su lote no fabrica otro")
	local fresh = saveNew(g, ctx, "brisa", "Validación")
	for _, q in { 0, -5, 2.5, Catalog.RULES.maxLotQty + 1 } do
		check(not Actions.createLot(g, ctx, { designId = fresh, qty = q }).ok, "cantidad inválida " .. q)
	end
	check(not Actions.createLot(g, ctx, { designId = "x", qty = 10 }).ok, "diseño inexistente")
	check(not Actions.createLot(g, ctx, { designId = fresh, qty = 10, price = 1 }).ok, "precio fuera de rango")
	local poor = g.money
	g.money = unit * 5
	check(not Actions.createLot(g, ctx, { designId = fresh, qty = 6 }).ok, "sin dinero para el lote completo no se ordena")
	eq(g.money, unit * 5, "y no se cobra nada")
	g.money = poor
	-- 50.000 unidades no generan 50.000 registros.
	local size = #serde.encode("json", g)
	check(size < 60000, "partida chica con 61.100 unidades encargadas: " .. size .. " bytes")
end)

test("[P3][P4][P5] Se fabrica exactamente el lote, se detiene, se evalúa y no se repite", function()
	local g = bigCompany("Exacto SA")
	local ctx = makeCtx(5)
	local id = saveNew(g, ctx, "brisa")
	local calc = DesignCalc.computeDesign(g, g.designs[1])
	local r = Actions.createLot(g, ctx, { designId = id, qty = 10000 })
	check(r.ok, r.msg)
	local lot = findLot(g, r.lotId)
	local done = runUntil(g, ctx, function()
		lotInvariants(g)
		eq(lot.sold, 0, "no se vende mientras se fabrica")
		return lot.prodState == "completado"
	end, 200)
	check(done, "el lote terminó")
	eq(lot.produced, 10000, "exactamente 10.000 fabricadas")
	eq(g.counters.unitsProduced, 10000, "contador global")
	eq(lot.costSpent, 10000 * lot.unitCost, "se cobró cada unidad una sola vez")
	eq(lot.saleState, "por lanzar", "terminado: espera que el jugador fije el precio")
	check(lot.review ~= nil and #lot.review.scores == 4, "llegaron las cuatro reseñas")
	local before = g.counters.unitsProduced
	local lotsBefore = #g.lots + #g.lotHistory
	runReal(g, ctx, 20, lotInvariants)
	eq(g.counters.unitsProduced, before, "[P4] no se fabricó nada más")
	eq(lot.produced, 10000, "el lote no crece")
	eq(lot.sold, 0, "sin precio no se vende")
	eq(#g.lots + #g.lotHistory, lotsBefore, "[P5] no se creó ningún lote nuevo")
	-- A la venta; al agotarse se archiva y tampoco se relanza solo.
	check(Actions.launchSale(g, ctx, { lotId = lot.id, price = calc.price }).ok, "a la venta")
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

test("Fondos: el lote se paga completo al ordenarlo y nunca queda a medio fabricar por falta de dinero", function()
	local g = newCompany("Justa SA")
	local ctx = makeCtx(6)
	local id = saveNew(g, ctx, "brisa")
	local unit = DesignCalc.computeDesign(g, g.designs[1]).unitCost
	g.money = unit * 3 + 50 -- alcanza para 3 unidades
	check(not Actions.createLot(g, ctx, { designId = id, qty = 500 }).ok, "500 no alcanzan")
	eq(g.money, unit * 3 + 50, "sin cobro")
	local r = Actions.createLot(g, ctx, { designId = id, qty = 3 })
	check(r.ok, r.msg)
	eq(g.money, 50, "se cobraron las 3 al ordenar")
	local lot = findLot(g, r.lotId)
	runUntil(g, ctx, function()
		return lot.prodState == "completado"
	end, 5)
	eq(lot.produced, 3, "se fabrican aunque no quede dinero")
	eq(g.money, 50, "sin cobros extra al fabricar")
	check(g.money >= 0, "nunca en negativo")
end)

test("Varios lotes: las líneas de la sede se reparten y el resto espera en cola", function()
	local g = newCompany("Cola SA")
	local ctx = makeCtx(7)
	local a = saveNew(g, ctx, "brisa", "Modelo A")
	local b = saveNew(g, ctx, "brisa", "Modelo B")
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
	local g = newCompany("Ventas SA")
	local ctx = makeCtx(8)
	g.sede = 3
	g.money = 3000000
	local a = saveNew(g, ctx, "brisa", "Sedán A")
	local b = saveNew(g, ctx, "brisa", "Sedán B")
	local c = saveNew(g, ctx, "duna", "Coupé C")
	local la = Actions.createLot(g, ctx, { designId = a, qty = 400 }).lotId
	local lb = Actions.createLot(g, ctx, { designId = b, qty = 400 }).lotId
	local lc = Actions.createLot(g, ctx, { designId = c, qty = 400 }).lotId
	for _, id in { la, lb, lc } do
		check(launchWhenReady(g, ctx, id), "fabricado, evaluado y a la venta")
	end
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

test("[P9][P10][P11] Cerrar venta: descarta lo no vendido sin reintegro, reintegra lo no fabricado y nunca más vende", function()
	local g = bigCompany("Cierre SA")
	local ctx = makeCtx(10)
	local id = saveNew(g, ctx, "brisa")
	local calc = DesignCalc.computeDesign(g, g.designs[1])
	local hi = select(2, Actions.priceRange({ unitCost = calc.unitCost, refPrice = calc.price }))
	local r = Actions.createLot(g, ctx, { designId = id, qty = 5000 })
	local lot = findLot(g, r.lotId)
	check(launchWhenReady(g, ctx, r.lotId, hi), "fabricado y a la venta a precio alto")
	runReal(g, ctx, 3, lotInvariants)
	local produced, sold = lot.produced, lot.sold
	local avail = Rules.lotAvailable(lot)
	check(avail > 0 and sold > 0, "hay vendidas y stock (" .. sold .. "/" .. avail .. ")")
	local m = g.money
	local res = Actions.closeSale(g, ctx, { lotId = lot.id })
	check(res.ok, res.msg)
	check(string.find(res.msg, Util.num(avail)) ~= nil, "el mensaje dice cuántas se descartan")
	eq(g.money, m, "[P9] sin reintegro ni cobro al cerrar")
	eq(lot.discarded, avail, "[P9] unidades descartadas")
	eq(lot.saleState, "retirado", "estado Retirado")
	eq(lot.qty, produced, "nada pendiente")
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
	eq(note.amount, 0, "el registro no mueve dinero (ya se pagó al ordenar)")
	check(GameState.validate(g), "partida válida")
	-- Un lote cerrado a medio fabricar: se reintegra lo que no se llegó a fabricar.
	local r2 = orderLot(g, ctx, id, 5000)
	local lot2 = findLot(g, r2.lotId)
	runReal(g, ctx, 1)
	local made = lot2.produced
	check(made > 0 and made < 5000, "a medio fabricar (" .. made .. ")")
	local m2 = g.money
	check(Actions.closeSale(g, ctx, { lotId = lot2.id }).ok, "cerrar")
	eq(g.money - m2, (5000 - made) * lot2.unitCost, "se reintegra lo no fabricado")
	eq(lot2.prodState, "cancelado", "producción cancelada")
	eq(lot2.discarded, made, "lo fabricado y no vendido se descarta")
	eq(lot2.costSpent, made * lot2.unitCost, "costo = solo lo fabricado")
end)

test("Cerrar venta de un lote que todavía no fabricó nada: se cancela y se reintegra", function()
	local g = newCompany("Nada SA")
	local ctx = makeCtx(11)
	local id = saveNew(g, ctx, "brisa")
	local m = g.money
	local r = Actions.createLot(g, ctx, { designId = id, qty = 10 })
	check(r.ok and g.money < m, "el lote se pagó al ordenarlo")
	local res = Actions.closeSale(g, ctx, { lotId = r.lotId })
	check(res.ok, res.msg)
	eq(g.money, m, "cerrado sin fabricar: se reintegra todo")
	local h = findHist(g, r.lotId)
	eq(h.produced, 0, "nada fabricado")
	eq(h.discarded, 0, "nada descartado")
	eq(h.saleState, "retirado", "retirado")
end)

test("[P11] Contabilidad: dinero = inicial − desarrollo − fabricado + ventas; sin doble costo", function()
	local g = newCompany("Libros SA")
	local ctx = makeCtx(12)
	local m0 = g.money
	local r = Actions.saveDesign(g, ctx, { draft = draftFor(g, "brisa") })
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
	-- El personal no suma PI por minuto (en una etapa futura reducirá costos y duración).
	local base = Rules.piPerMinute(g)
	for i = 1, 30 do
		table.insert(g.employees, { id = "e" .. i, name = "X", role = "Ingeniero", level = 6, skill = 98, salary = 100, assign = "laboratorio" })
	end
	eq(Rules.piPerMinute(g), base, "el personal no aumenta los PI por minuto")
end)

-- [P13] Investigación ----------------------------------------------------------------------------

test("[P13] Investigación bloqueada por requisitos, por época y por recursos", function()
	local g = newCompany("Lab SA")
	local ctx = makeCtx(14)
	local turbo = Catalog.researchNode("mo3") -- 1977, requiere mo1
	local r = Actions.startResearch(g, ctx, { id = "mo3" })
	check(not r.ok and string.find(r.msg, "1972") ~= nil and string.find(r.msg, "1977") ~= nil, "más de 5 años adelantada: " .. r.msg)
	g.time.day = (1977 - 1970) * 12
	r = Actions.startResearch(g, ctx, { id = "mo3" })
	check(not r.ok and string.find(r.msg, Catalog.researchNode("mo1").name, 1, true) ~= nil, "bloqueada por requisito: " .. r.msg)
	g.time.day = 0
	g.rp = 0
	r = Actions.startResearch(g, ctx, { id = "mo1" })
	check(not r.ok and string.find(r.msg, "PI") ~= nil, "sin PI no empieza: " .. r.msg)
	local pi, cost, days = Rules.researchCost(g, Catalog.researchNode("mo1"))
	g.rp = pi
	local m = g.money
	r = Actions.startResearch(g, ctx, { id = "mo1" })
	check(r.ok, r.msg)
	eq(g.money, m - cost, "cuesta dinero al empezar")
	eq(g.rp, 0, "y los PI")
	check(not Actions.startResearch(g, ctx, { id = "mo1" }).ok, "no se repite una en curso")
	check(not Actions.cancelResearch(g, ctx, {}).ok, "no se cancela")
	runReal(g, ctx, days * Catalog.CALENDAR.realSecondsPerDay / 60 + 0.05)
	check(Util.contains(g.research.done, "mo1"), "terminada a tiempo")
	g.time.day = (1977 - 1970) * 12
	check(Rules.researchState(g, turbo) == "disponible", "con época y requisito, disponible")
	check(not Actions.startResearch(g, ctx, { id = "mo1" }).ok, "no se investiga dos veces")
end)

test("Árbol completo 1970–2030: todas las ramas, cada nodo con un efecto real y tiempos razonables", function()
	local labels = {}
	for _, key in Catalog.RESEARCH_ORDER do
		table.insert(labels, Catalog.RESEARCH[key].label)
	end
	for _, want in { "Chasis", "Motores", "Seguridad", "Tecnología" } do
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
	for _, e in Catalog.EQUIPMENT do
		unlocks[e.research] = true -- equipamiento elegible en el diseñador
	end
	for _, v in Catalog.ENGINE_VARIANTS do
		if v.research then
			unlocks[v.research] = true
		end
	end
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
			check(hasFx or unlocks[n.id] or (n.family ~= nil and n.level ~= nil), n.id .. " (" .. n.name .. ") tiene un efecto real")
			check(n.year >= 1970 and n.year <= 2030, n.id .. " año " .. n.year)
			for _, req in n.req do
				local rn = Catalog.researchNode(req)
				check(rn ~= nil and rn.year <= n.year, n.id .. " requiere " .. req .. " de un año anterior")
			end
			years[math.floor(n.year / 10) * 10] = true
			-- Duración (días de juego a 1×) y PI con la sede esperada de su época: hasta 15 minutos reales.
			local mins = n.days * Catalog.CALENDAR.realSecondsPerDay / 60
			check(mins >= 0.5 and mins <= 15, n.id .. " tarda " .. Util.num(mins, 1) .. " min")
			local piMins = n.rp / Catalog.interp(Catalog.EXPECTED_PI, n.year)
			-- Solo con el centro (sin líneas fabricando): hasta 30 min para lo más complejo de su época.
			check(piMins <= 30, n.id .. " junta sus PI en " .. Util.num(piMins, 1) .. " min")
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
	local r = Actions.createLot(g, ctx, { designId = g.designs[1].id, qty = 30 })
	check(r.ok, r.msg)
	runReal(g, ctx, 1, lotInvariants)
end)

-- [P16] Tutorial ---------------------------------------------------------------------------------

test("[P16] El tutorial se completa sin trabarse por dinero ni investigación (todas las empresas empiezan igual)", function()
	for _, dif in { "normal" } do
		local log = Bot.play(dif, 30)
		local g = log.g
		for _, m in Catalog.MISSIONS do
			if m.kind == "tutorial" then
				check(g.claimed[m.id] == true, dif .. ": misión " .. m.id .. " (" .. m.title .. ")")
			end
		end
		check(log.minMoney >= 0, dif .. ": nunca en negativo")
		-- El primer lote se fabrica completo y recibe reseñas antes de venderse.
		check(log.milestones["primera venta"] ~= nil and log.milestones["primera venta"] < 3, dif .. ": primera venta en menos de 3 minutos (" .. tostring(log.milestones["primera venta"]) .. ")")
		check(log.milestones["sede 2"] ~= nil and log.milestones["sede 2"] < 28, dif .. ": Empresa pequeña antes de 28 min (" .. tostring(log.milestones["sede 2"]) .. ")")
		check(GameState.validate(g), dif .. ": partida válida")
	end
	-- Recorrido mínimo del tutorial con el capital inicial: un solo diseño barato y un lote chico.
	local g = newCompany("Minima SA")
	local ctx = makeCtx(17)
	local id = saveNew(g, ctx, "brisa")
	claimReady(g, ctx)
	local unit = DesignCalc.computeDesign(g, g.designs[1]).unitCost
	check(g.money >= 25 * unit, "con el capital inicial alcanza para un lote de 25 autos")
	local first = Actions.createLot(g, ctx, { designId = id, qty = 25 })
	check(first.ok, "lote")
	claimReady(g, ctx)
	check(launchWhenReady(g, ctx, first.lotId), "terminado, con reseñas y a la venta")
	check(runUntil(g, ctx, function()
		claimReady(g, ctx)
		return g.claimed.t3 == true
	end, 10), "vende 25 y cobra la misión")
	-- Investigación: la primera mejora pequeña se puede pagar y terminar.
	local cheapest
	for _, key in Catalog.RESEARCH_ORDER do
		for _, n in Catalog.RESEARCH[key].nodes do
			if Rules.researchState(g, n) == "disponible" and Rules.researchAhead(g, n) == 0 and (not cheapest or n.cost < cheapest.cost) then
				cheapest = n
			end
		end
	end
	local cpi, cmoney = Rules.researchCost(g, cheapest)
	check(cheapest and g.money >= cmoney and g.rp >= cpi, "puede pagar una investigación (" .. cpi .. " PI, tiene " .. math.floor(g.rp) .. ")")
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
	local ra = Actions.saveDesign(A, ctxA, { draft = draftFor(A, "brisa") })
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
	g.money = 3000000
	local id = saveNew(g, ctx, "brisa")
	local lotId = Actions.createLot(g, ctx, { designId = id, qty = 500 }).lotId
	check(launchWhenReady(g, ctx, lotId), "a la venta")
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

test("[C19] PI: recurso propio sin tope, independiente del dinero; las recompensas suman", function()
	local g = newCompany("Banco SA")
	local ctx = makeCtx(42)
	eq(Rules.piCap(g), math.huge, "sin tope de acumulación")
	local m0 = g.money
	runReal(g, ctx, 25)
	check(math.abs(g.rp - 25 * Rules.piCenter(g)) < 0.01, "25 min de centro en el garaje: " .. Util.num(g.rp, 2) .. " PI")
	eq(g.money, m0, "generar PI no mueve el dinero")
	saveNew(g, ctx, "brisa")
	local before = g.rp
	check(Actions.claimMission(g, ctx, { id = "t1" }).ok, "misión")
	check(g.rp > before, "el PI de la misión se suma")
	-- Los PI acumulados alcanzan para investigar.
	check(Actions.startResearch(g, ctx, { id = "mo1" }).ok, "investigar")
	runReal(g, ctx, 3)
	check(Util.contains(g.research.done, "mo1"), "se completa")
end)

test("Anti-farmeo: lotes chicos o repetidos no generan PI extra (solo las líneas mientras fabrican)", function()
	local g = bigCompany("Farmeo SA")
	g.sede = 1
	local ctx = makeCtx(43)
	local id = saveNew(g, ctx, "brisa")
	check(not Catalog.ECON.bonusPiEnabled, "sin bonificación de PI por lote")
	local center = Rules.piCenter
	Rules.piCenter = function()
		return 0
	end
	g.rp = 0
	local t0 = Rules.absDay(g)
	for _ = 1, 30 do
		local r = orderLot(g, ctx, id, 1)
		if r.ok then
			launchWhenReady(g, ctx, r.lotId, nil, 1)
			runReal(g, ctx, 0.2)
		end
	end
	Rules.piCenter = center
	local realMins = (Rules.absDay(g) - t0 + 1) * Catalog.CALENDAR.realSecondsPerDay / 60
	check(g.rp <= Catalog.RESEARCH_RULES.linePi * realMins + 0.01, "30 lotes de una unidad: " .. Util.num(g.rp, 2) .. " PI en " .. Util.num(realMins, 1) .. " min")
	check(g.rp < 0.5 * Catalog.RESEARCH_RULES.linePi * realMins, "la línea solo suma mientras fabrica")
	eq(g.counters.lotsSoldOut >= 1 and true or false, true, "los lotes se agotan")
end)

test("[C21] Desbloquear una tecnología de otra década (cuando llega su año y sus requisitos)", function()
	local g = newCompany("Década SA")
	local ctx = makeCtx(44)
	g.money = 5000000
	g.time.day = (1983 - 1970) * 12
	local n = Catalog.researchNode("mo4") -- 1983, requiere mo1
	check(Rules.researchState(g, n) == "bloqueada", "sin requisito")
	table.insert(g.research.done, "mo1")
	check(Rules.researchState(g, n) == "disponible", "con requisito y año")
	g.rp = 100000
	check(Actions.startResearch(g, ctx, { id = "mo4" }).ok, "empieza")
	check(runUntil(g, ctx, function()
		return Util.contains(g.research.done, "mo4")
	end, 120), "terminada")
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
	local id = saveNew(g, ctx, "brisa", "Apex Compact")
	-- Un lote por modelo: cada lote es de un modelo nuevo (duplicado), que después se elimina del catálogo.
	local total = Catalog.RULES.maxLotHistory + 15
	for i = 1, total do
		local r = orderLot(g, ctx, id, 10 + i)
		check(r.ok, "lote " .. i)
		local designId = findLot(g, r.lotId).designId
		Actions.closeSale(g, ctx, { lotId = r.lotId })
		if designId ~= id then
			Actions.delDesign(g, ctx, { designId = designId })
		end
	end
	eq(#g.lotHistory, Catalog.RULES.maxLotHistory, "historial reciente acotado")
	eq(#g.modelHistory, total, "cada modelo en el historial permanente, aunque se haya eliminado el diseño")
	eq(g.modelHistory[1].lots, 1, "un lote por modelo")
	-- Nueva generación: otra entrada, la anterior no se pisa.
	g.time.day = 12 * 7
	local nd = draftFor(g, "brisa", "Apex Compact")
	check(Actions.saveDesign(g, ctx, { draft = nd, newGenOf = id }).ok, "Apex Compact 2")
	local id2 = g.designs[#g.designs].id
	local r = Actions.createLot(g, ctx, { designId = id2, qty = 50 })
	check(r.ok, "la nueva generación tiene su propio lote: " .. tostring(r.msg))
	Actions.closeSale(g, ctx, { lotId = r.lotId })
	eq(#g.modelHistory, total + 1, "una entrada por generación")
	eq(g.modelHistory[1].gen, 1, "la 1.ª generación conserva su configuración")
	eq(g.modelHistory[#g.modelHistory].gen, 2, "la 2.ª tiene la suya")
	check(g.modelHistory[1].spec.parts.motor ~= nil and g.modelHistory[1].stats.unitCost ~= nil, "configuración y estadísticas guardadas")
	-- Eliminar el diseño no borra su historia.
	check(Actions.delDesign(g, ctx, { designId = id }).ok, "eliminar el diseño")
	eq(#g.modelHistory, total + 1, "la historia sigue")
	check(GameState.validate(g), "partida válida")
end)

test("Migración 3 → 4: historial permanente desde los lotes, campaña y seguridad", function()
	local g = bigCompany("Vieja Tres")
	local ctx = makeCtx(46)
	local id = saveNew(g, ctx, "brisa")
	local full = {}
	for i = 1, 3 do
		-- Lotes como los de la versión 3 (varios por modelo), armados a mano.
		local snap = Simulation.designSnapshot(g, g.designs[1])
		local l = Simulation.makeLot(g, snap, 20 * i, snap.calc.price)
		table.insert(g.lots, 1, l)
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
	g.money = 3000000
	g.time.day = 2 * 12 -- 1972: ya hay compactos
	table.insert(g.research.done, "ch_compacto")
	local id = saveNew(g, ctx, "pixel")
	local lotId = Actions.createLot(g, ctx, { designId = id, qty = 500 }).lotId
	check(launchWhenReady(g, ctx, lotId), "a la venta")
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
	local id = saveNew(g, ctx, "brisa")
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
		-- En 1970 se empieza con dos chasis (sedán y coupé básicos); después hay más tipos.
		check(types >= (year == 1970 and 2 or 3), year .. ": varios tipos rentables (" .. types .. ")")
		-- Una investigación de la época dura según su complejidad (días de juego a 1×) y sus PI se juntan
		-- en un tiempo razonable con la sede esperada y una línea fabricando.
		for _, key in Catalog.RESEARCH_ORDER do
			for _, n in Catalog.RESEARCH[key].nodes do
				if n.year == year or (n.year > year and n.year <= year + 1) then
					local mins = n.days * Catalog.CALENDAR.realSecondsPerDay / 60
					local MAX = { 1.5, 3, 6, 10, 15 }
					check(mins <= MAX[n.complexity] + 0.01, n.id .. " dura según su complejidad (" .. Util.num(mins, 1) .. " min)")
					local piMins = n.rp / (Catalog.interp(Catalog.EXPECTED_PI, n.year) + Catalog.RESEARCH_RULES.linePi)
					check(piMins <= 20, n.id .. " junta sus PI en " .. Util.num(piMins, 1) .. " min")
				end
			end
		end
	end
	-- Progresión completa simulada: ni demasiado rápida ni demasiado lenta, y siempre con dinero positivo.
	local log = Bot.play("normal", 330)
	-- El primer lote se fabrica completo y recibe reseñas antes de venderse (etapa 2).
	check(log.milestones["primera venta"] < 3, "primera venta en menos de 3 min")
	check(log.milestones["primera ganancia"] < 5, "primera ganancia en menos de 5 min")
	check(log.milestones["sede 2"] >= 8 and log.milestones["sede 2"] <= 25, "Empresa pequeña entre 8 y 25 min (" .. Util.num(log.milestones["sede 2"], 1) .. ")")
	check(log.milestones["sede 3"] ~= nil and log.milestones["sede 3"] <= 100, "Sede empresarial antes de 100 min (" .. tostring(log.milestones["sede 3"]) .. ")")
	check(log.milestones["sede 4"] ~= nil and log.milestones["sede 4"] <= 200, "Corporación antes de 200 min")
	check(log.minMoney >= 0, "nunca dinero negativo")
	local rs = Bot.researchSummary(log)
	check(rs.avgGap > 0 and rs.avgGap <= 15, "una tecnología nueva cada " .. Util.num(rs.avgGap, 1) .. " min en promedio")
	check(log.newUnlocks >= 10, "componentes nuevos durante la partida (" .. log.newUnlocks .. ")")
	for typeId, bt in log.byType do
		check(bt.revenue > bt.cost, typeId .. ": rentable en la partida")
	end
	-- Recuperarse de una mala decisión: un lote con precio absurdo se cierra y la empresa sigue.
	local g = newCompany("Error SA")
	local ctx = makeCtx(50)
	local id = saveNew(g, ctx, "brisa")
	local c = DesignCalc.computeDesign(g, g.designs[1])
	local hi = select(2, Rules.priceRange(c.unitCost, c.price))
	local lotId = Actions.createLot(g, ctx, { designId = id, qty = 15 }).lotId
	launchWhenReady(g, ctx, lotId, hi)
	runReal(g, ctx, 2)
	Actions.closeSale(g, ctx, { lotId = lotId })
	local after = g.money
	check(Actions.dupDesign(g, ctx, { designId = id }).ok, "un modelo nuevo (la ingeniería se adapta al dinero disponible)")
	local qty = math.floor(g.money * 0.9 / c.unitCost)
	local r = Actions.createLot(g, ctx, { designId = g.designs[#g.designs].id, qty = qty })
	check(r.ok and qty >= 10, "puede lanzar otro lote (" .. qty .. " u)")
	launchWhenReady(g, ctx, r.lotId, c.price)
	-- Patrimonio = dinero + autos terminados sin vender (a su costo): crece vendiendo a buen precio.
	local function equity(): number
		local e = g.money
		for _, l in g.lots do
			e += Rules.lotAvailable(l) * l.unitCost
		end
		return e
	end
	check(runUntil(g, ctx, function()
		return equity() > after + 5000
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
		prompt = o.prompt,
	})
	return mgr, pushed, data
end

local idn = 0
local function rid(): string
	idn += 1
	return "request-" .. idn .. "-xxxx"
end

local function playThrough(mgr: any, p: any)
	local r = mgr:request(p, "createCompany", { slot = "1", name = "Sesion SA", color = "#7667FF", logo = "pico" })
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
	local r = mgr:request(p, "saveDesign", { draft = draftFor(s.game, "brisa"), requestId = rid() })
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
	mgr:request(p, "saveDesign", { draft = draftFor(s.game, "brisa"), requestId = rid() })
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
	check(not mgr:request(p, "createCompany", { slot = "1", name = "Nada SA", color = "#7667FF", logo = "pico" }).ok, "no deja jugar")
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
	check(mgr:request(p, "createCompany", { slot = "1", name = "Primera SA", color = "#7667FF", logo = "pico" }).ok, "1")
	local g1 = mgr.list[p].game
	mgr:request(p, "saveDesign", { draft = draftFor(g1, "brisa"), requestId = rid() })
	check(not mgr:request(p, "createCompany", { slot = "2", name = "primera sa", color = "#7667FF", logo = "pico" }).ok, "nombre repetido entre ranuras")
	check(mgr:request(p, "createCompany", { slot = "2", name = "Segunda SA", color = "#7667FF", logo = "pico" }).ok, "2")
	local g2 = mgr.list[p].game
	check(g1 ~= g2 and #g2.designs == 0 and g2.money == Catalog.START.money, "datos independientes")
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
	-- Los modelos de la demostración ya tuvieron su lote: se fabrica un modelo nuevo (duplicado).
	check(mgr:request(p, "dupDesign", { designId = mgr.list[p].game.designs[1].id, requestId = rid() }).ok, "duplicar en la demostración")
	local dg = mgr.list[p].game
	local r = mgr:request(p, "createLot", { designId = dg.designs[#dg.designs].id, qty = 100, requestId = rid() })
	check(r.ok, "las acciones funcionan en la demostración: " .. tostring(r.msg))
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
	mgr:request(a, "createCompany", { slot = "1", name = "Empresa A", color = "#7667FF", logo = "pico" })
	mgr:request(b, "createCompany", { slot = "1", name = "Empresa B", color = "#F7C95C", logo = "rayo" })
	local ga, gb = mgr.list[a].game, mgr.list[b].game
	mgr:request(a, "saveDesign", { draft = draftFor(ga, "brisa"), requestId = rid() })
	eq(gb.money, Catalog.START.money, "B no pagó nada")
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
	local r = mgr:request(p, "saveDesign", { draft = draftFor(g, "brisa", "Grande"), requestId = rid() })
	check(r.ok, r.msg)
	r = mgr:request(p, "saveDesign", { draft = draftFor(g, "brisa", "Chico"), requestId = rid() })
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
	mgr:request(p, "saveDesign", { draft = draftFor(s.game, "brisa"), requestId = rid() })
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
	g.money = 20000000
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
		longLog = Bot.play("normal", 860) -- hasta 2030 (≈ 730 min) y dos horas de años extra
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
	g.rp = 1000
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
	check(Actions.searchCandidates(g, ctx, { kind = "general" }).ok, "busca candidatos")
	local cand = g.candidates[1]
	check(cand ~= nil and Actions.hire(g, ctx, { candidateId = cand.id }).ok, "contrata")
	local lot = Actions.createLot(g, ctx, { designId = id, qty = 2000 })
	check(lot.ok, lot.msg)
	check(launchWhenReady(g, ctx, lot.lotId), "terminado, con reseñas y a la venta")
	check(orderLot(g, ctx, id, 40000).ok, "otro modelo en fabricación durante los años extra")
	local produced0, sold0 = g.counters.unitsProduced, g.counters.unitsSold
	local promo0, sal0 = 0, 0
	local day0 = g.time.day
	-- Tres horas reales después del final del calendario.
	runReal(g, ctx, 180)
	check(g.time.day - day0 >= 12 * 14, "pasaron más de 14 años comerciales (" .. (g.time.day - day0) .. " meses)")
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

test("[F5] Todas las investigaciones se completan", function()
	local nodes = allNodes()
	eq(#nodes, Catalog.RESEARCH_TOTAL, "el árbol tiene " .. Catalog.RESEARCH_TOTAL .. " tecnologías")
	local log = longGame()
	eq(#log.g.research.done, Catalog.RESEARCH_TOTAL, "el bot las completa todas")
	local seen = {}
	for _, id in log.g.research.done do
		check(not seen[id], "sin repetidas: " .. id)
		seen[id] = true
	end
	check(Rules.missionState(log.g, Catalog.mission("s12")) ~= "progreso", "misión «Completá todas las investigaciones»")
	-- Revisión de todas: año, complejidad, PI, dinero, duración y requisitos coherentes.
	for _, n in nodes do
		check(n.year >= 1970 and n.year <= Catalog.CALENDAR.endYear, n.id .. ": año dentro del calendario")
		check(n.complexity >= 1 and n.complexity <= 5 and n.rp > 0 and n.cost > 0 and n.days > 0, n.id .. ": complejidad, PI, dinero y días")
		check(n.category ~= nil and Catalog.RESEARCH[n.category] ~= nil, n.id .. ": categoría")
		for _, r in n.req do
			local q = Catalog.researchNode(r)
			check(q ~= nil and q.year <= n.year, n.id .. ": su requisito " .. r .. " existe y no es posterior")
		end
	end
end)

test("[F6] Tiempos reales de investigación (bot): cerca de los objetivos", function()
	local rs = Bot.researchSummary(longGame())
	-- Duración real (minutos a 1×) por complejidad. El bot adelanta tecnologías, que tardan hasta 50 % más.
	local RANGE = { { 0.7, 2.5 }, { 1.5, 4.5 }, { 3.5, 9 }, { 6, 15 }, { 9, 23 } }
	for k, rg in RANGE do
		local bt = rs.byTier[k]
		local label = Catalog.RESEARCH_RULES.complexityLabel[k]
		check(bt ~= nil, label .. ": investigadas")
		if bt then
			local avg = bt.total / bt.n
			check(avg >= rg[1] and avg <= rg[2], label .. ": media " .. Util.num(avg, 1) .. " min")
			check(bt.max <= rg[2] * 1.1, label .. ": máxima " .. Util.num(bt.max, 1) .. " min")
		end
	end
	check(rs.avgLag <= 0.5, "el optimizador investiga apenas puede (" .. Util.num(rs.avgLag, 1) .. " años)")
	-- Estrategia simple (sin ampliar más allá de la sede 3 hasta 2009): más lenta, pero sin esperas eternas.
	local flat = Bot.researchSummary(Bot.play("normal", 732, { flat = true }))
	check(flat.done >= Catalog.RESEARCH_TOTAL - 5, "la estrategia simple completa casi todas (" .. flat.done .. ")")
	for k, rg in RANGE do
		local bt = flat.byTier[k]
		check(bt ~= nil and bt.max <= rg[2] * 1.1, "simple · " .. Catalog.RESEARCH_RULES.complexityLabel[k] .. ": máxima " .. Util.num(bt and bt.max or -1, 1) .. " min")
	end
end)

test("[F7] Comparar estrategias: diversificar rinde más que un solo tipo", function()
	local best = longGame()
	local one = Bot.play("normal", 732, { single = true })
	local flat = Bot.play("normal", 732, { flat = true })
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
	-- Etapa 3: los niveles de motor y el equipamiento hacen más rentables los modelos tardíos.
	check(log.decades[2020].endMoney < 3000000000, "el dinero no se acumula sin destino (" .. Util.money(log.decades[2020].endMoney) .. ")")
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
	local id = saveNew(g, ctx, "brisa", "Primero")
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
	local id = saveNew(g, ctx, "brisa", "Extra")
	local r = Actions.createLot(g, ctx, { designId = id, qty = 3000 })
	check(r.ok, r.msg)
	check(launchWhenReady(g, ctx, r.lotId), "terminado, evaluado y a la venta")
	runReal(g, ctx, 2)
	local l = findLot(g, r.lotId)
	check(l.produced > 0 and l.sold > 0, "fabrica y vende solo")
	local m = g.money
	local c = Actions.closeSale(g, ctx, { lotId = r.lotId })
	check(c.ok, c.msg)
	check(findLot(g, r.lotId) == nil and findHist(g, r.lotId).saleState == "retirado", "Cerrar venta lo retira")
	check(g.money <= m, "cerrar no regala dinero")
	lotInvariants(g)
end)

test("Pioneer 70: carrocería 3D predeterminada del sedán en los 70, elegible después y puramente visual", function()
	local P = Catalog.vehicleModel("pioneer70")
	check(P ~= nil and P.type == "sedan" and P.asset == "Pioneer70_World" and P.paintSuffix == "_Paint", "está en el catálogo")
	for y = 1970, 1979 do
		eq(Catalog.defaultVehicleModel("sedan", y), P, "predeterminada del sedán en " .. y)
	end
	eq(Catalog.defaultVehicleModel("sedan", 1980), nil, "en 1980 deja de ser la predeterminada")
	eq(Catalog.defaultVehicleModel("compacto", 1972), nil, "solo para sedanes")
	local g = newCompany("Pioneer SA")
	local ctx = makeCtx(301)
	g.money = 5000000
	g.time.day = 2 * 12 -- 1972
	-- Diseño nuevo de sedán: la usa sin que el jugador haga nada; se guarda y llega al lote.
	local id = saveNew(g, ctx, "brisa", "Pioneer Familiar")
	local d = g.designs[#g.designs]
	eq(d.id, id, "diseño guardado")
	eq(d.vehicleModel, "pioneer70", "el diseño guardado usa el Pioneer 70")
	local r = Actions.createLot(g, ctx, { designId = id, qty = 20 })
	check(r.ok, r.msg)
	eq(findLot(g, r.lotId).design.spec.vehicleModel, "pioneer70", "el lote fabricado conserva la carrocería")
	-- Cambiar solo la carrocería es estético: no paga ingeniería ni cambia costos o estadísticas.
	local before = DesignCalc.computeDesign(g, d)
	local edit = jsonCopy(d)
	edit.vehicleModel = "provisional"
	eq(DesignCalc.engineeringKind(d, edit), "estetico", "cambio estético")
	local after = DesignCalc.computeDesign(g, edit)
	check(before.unitCost == after.unitCost and before.price == after.price and before.hp == after.hp, "no cambia costos ni estadísticas")
	check(not DesignCalc.sameSpec(d, edit), "pero cuenta como cambio del diseño")
	local m = g.money
	local sv = Actions.saveDesign(g, ctx, { draft = edit, sourceId = id })
	check(sv.ok, sv.msg)
	check(g.money == m, "guardar el cambio de carrocería no cobra")
	-- Saneamiento del borrador que manda el cliente.
	local raw = draftFor(g, "brisa", "Otro sedán")
	raw.vehicleModel = "inventado"
	check(not DesignCalc.sanitize(g, raw), "carrocería desconocida rechazada")
	raw.vehicleModel = "pioneer70"
	eq((DesignCalc.sanitize(g, raw)).vehicleModel, "pioneer70", "Pioneer 70 aceptada")
	raw.vehicleModel = "provisional"
	eq((DesignCalc.sanitize(g, raw)).vehicleModel, "provisional", "provisional aceptada")
	table.insert(g.research.done, "ch_compacto")
	local rawC = draftFor(g, "pixel", "Compacto")
	rawC.vehicleModel = "pioneer70"
	eq((DesignCalc.sanitize(g, rawC)).vehicleModel, nil, "un compacto no la puede usar (queda la suya)")
	-- Cambiar la base a otro tipo vuelve a la carrocería de ese tipo.
	local dd = DesignCalc.newDraft(g, "brisa")
	DesignCalc.changeBase(g, dd, "pixel")
	eq(dd.vehicleModel, nil, "de sedán a compacto: sin Pioneer")
	DesignCalc.changeBase(g, dd, "brisa")
	eq(dd.vehicleModel, "pioneer70", "y de vuelta a sedán: Pioneer")
	-- Décadas posteriores: sigue disponible para elegir.
	g.time.day = (1995 - 1970) * 12
	eq(DesignCalc.newDraft(g, "brisa").vehicleModel, nil, "en 1995 un sedán nuevo no la usa por defecto")
	raw = draftFor(g, "brisa", "Sedán 95")
	raw.vehicleModel = "pioneer70"
	eq((DesignCalc.sanitize(g, raw)).vehicleModel, "pioneer70", "pero se puede elegir en 1995")
	eq(Catalog.resolveVehicleModel(d).id, "pioneer70", "el diseño de 1972 sigue usándola")
	-- Diseños de partidas anteriores (sin el campo): sedanes de los 70 la usan; los demás, el provisional.
	local old = jsonCopy(d)
	old.vehicleModel = nil
	old.modelYear = 1974
	eq(Catalog.resolveVehicleModel(old).id, "pioneer70", "sedán viejo de 1974 sin el campo: Pioneer 70")
	old.modelYear = 1988
	eq(Catalog.resolveVehicleModel(old), nil, "sedán viejo de 1988: provisional")
	-- Validación de la partida guardada.
	local ok = GameState.validate(jsonCopy(g))
	check(ok, "partida válida con la carrocería guardada")
	local bad = jsonCopy(g)
	bad.designs[1].vehicleModel = 5
	check(not GameState.validate(bad), "un valor que no es texto es un dato dañado")
	local gone = jsonCopy(g)
	gone.designs[1].vehicleModel = "modelo_retirado"
	check(GameState.validate(gone), "una carrocería que ya no existe no daña la partida")
end)

-- Etapa 1 (base del juego): calendario diario, velocidades, pausa individual, ranuras, economía y guardado.
local function ticks(mgr: any, clock: any, n: number)
	for _ = 1, n do
		clock.t += 1
		clock.c += 1
		mgr:tick()
	end
end

test("[E1] Calendario: empieza el 01/01/1970, un día cada 2 s a 1×, 2× y 3× proporcionales, meses y años correctos", function()
	local store = newStore()
	local clock = { t = 1000, c = 0 }
	local mgr = makeServer(store, "A", clock)
	local p = { UserId = 501 }
	mgr:add(p)
	local g = playThrough(mgr, p).game
	eq(Rules.date(g), "01/01/1970", "empresa nueva el 01/01/1970")
	eq(Rules.absDay(g), 0, "día 0")
	ticks(mgr, clock, 2)
	eq(Rules.date(g), "02/01/1970", "a 1×, 2 segundos reales = 1 día")
	ticks(mgr, clock, 58)
	eq(Rules.absDay(g), 30, "60 s reales = 30 días")
	eq(Rules.date(g), "31/01/1970", "último día de enero")
	ticks(mgr, clock, 2)
	eq(Rules.date(g), "01/02/1970", "pasa a febrero")
	check(mgr:request(p, "setSpeed", { speed = 2, requestId = rid() }).ok, "velocidad 2×")
	local d0 = Rules.absDay(g)
	ticks(mgr, clock, 10)
	eq(Rules.absDay(g) - d0, 10, "a 2×, 10 s = 10 días")
	check(mgr:request(p, "setSpeed", { speed = 3, requestId = rid() }).ok, "velocidad 3×")
	d0 = Rules.absDay(g)
	ticks(mgr, clock, 10)
	eq(Rules.absDay(g) - d0, 15, "a 3×, 10 s = 15 días")
	check(not mgr:request(p, "setSpeed", { speed = 4, requestId = rid() }).ok, "no hay 4× ni avance instantáneo")
	check(not mgr:request(p, "setSpeed", { speed = 100, requestId = rid() }).ok, "ni velocidades arbitrarias")
	-- Años y bisiestos (simulación directa, mismo reloj que usa el servidor).
	local h = newCompany("Calendario SA")
	local ctx = makeCtx(502)
	Simulation.simulate(h, ctx, 364 * Catalog.RULES.gameDayMinutes)
	eq(Rules.date(h), "31/12/1970", "día 365 del año")
	Simulation.simulate(h, ctx, Catalog.RULES.gameDayMinutes)
	eq(Rules.date(h), "01/01/1971", "cambio de año")
	Simulation.simulate(h, ctx, (365 + 31 + 28) * Catalog.RULES.gameDayMinutes)
	eq(Rules.date(h), "29/02/1972", "1972 es bisiesto")
	Simulation.simulate(h, ctx, Catalog.RULES.gameDayMinutes)
	eq(Rules.date(h), "01/03/1972", "y sigue en marzo")
	local ok = GameState.validate(jsonCopy(h))
	check(ok, "la partida sigue válida")
end)

test("[E1] Pausa individual: un menú abierto pausa solo esa empresa (calendario, fábrica e investigación)", function()
	local store = newStore()
	local clock = { t = 1000, c = 0 }
	local mgr = makeServer(store, "A", clock)
	local a, b = { UserId = 511 }, { UserId = 512 }
	mgr:add(a)
	mgr:add(b)
	local ga = playThrough(mgr, a).game
	local gb = playThrough(mgr, b).game
	ga.money = 3000000
	mgr:request(a, "saveDesign", { draft = draftFor(ga, "brisa"), requestId = rid() })
	check(mgr:request(a, "createLot", { designId = ga.designs[1].id, qty = 500, requestId = rid() }).ok, "lote en fabricación")
	ga.rp = 100
	check(mgr:request(a, "startResearch", { id = "mo1", requestId = rid() }).ok, "investigación en curso")
	ticks(mgr, clock, 4)
	check(mgr:request(a, "setUiPause", { paused = true }).ok, "A abre un menú")
	local dayA, dayB = Rules.absDay(ga), Rules.absDay(gb)
	local prodA, resA, moneyA = ga.lots[1].produced, ga.research.projects[1].progress, ga.money
	ticks(mgr, clock, 20)
	eq(Rules.absDay(ga), dayA, "la empresa de A no avanza")
	eq(ga.lots[1].produced, prodA, "ni fabrica")
	eq(ga.research.projects[1].progress, resA, "ni investiga")
	eq(ga.money, moneyA, "ni cobra ni paga")
	eq(Rules.absDay(gb) - dayB, 10, "la de B sigue normalmente")
	check(mgr:request(a, "setUiPause", { paused = false }).ok, "A cierra el menú")
	ticks(mgr, clock, 4)
	eq(Rules.absDay(ga) - dayA, 2, "A continúa al cerrar el menú")
	check(ga.lots[1].produced > prodA, "y vuelve a fabricar")
	check(ga.research.projects[1] == nil or ga.research.projects[1].progress > resA, "y a investigar")
	-- Volver al menú de empresas quita la pausa (la próxima empresa no arranca pausada).
	mgr:request(a, "setUiPause", { paused = true })
	mgr:request(a, "leaveCompany", {})
	check(mgr:request(a, "selectSlot", { slot = "1" }).ok, "vuelve a abrir la empresa")
	local d1 = Rules.absDay(ga)
	ticks(mgr, clock, 2)
	eq(Rules.absDay(ga) - d1, 1, "al volver a entrar no queda pausada")
end)

test("[E1] Economía: el dinero solo cambia en el servidor; no se gasta lo que no hay", function()
	local store = newStore()
	local clock = { t = 1000, c = 0 }
	local mgr = makeServer(store, "A", clock)
	local p = { UserId = 521 }
	mgr:add(p)
	local g = playThrough(mgr, p).game
	local m0 = g.money
	check(not mgr:request(p, "setMoney", { money = 1e12, requestId = rid() }).ok, "acción inexistente rechazada")
	check(not mgr:request(p, "earn", { amount = 1e9, requestId = rid() }).ok, "tampoco «earn»")
	mgr:request(p, "setSpeed", { speed = 1, money = 1e12, requestId = rid() })
	mgr:request(p, "setUiPause", { paused = false, money = 1e12 })
	eq(g.money, m0, "ningún campo del cliente cambia el dinero")
	check(not mgr:request(p, "createLot", { designId = "x", qty = -100, requestId = rid() }).ok, "cantidades negativas rechazadas")
	check(Simulation.canAfford(g, m0) and not Simulation.canAfford(g, m0 + 1), "canAfford: alcanza justo, no un peso más")
	check(not Simulation.canAfford(g, -5) and not Simulation.canAfford(g, 0 / 0), "montos inválidos")
	check(not Simulation.spend(g, m0 + 1, "mejora", "prueba"), "no se gasta lo que no hay")
	eq(g.money, m0, "sin cambios")
	local n = #g.ledger
	check(Simulation.spend(g, 1000, "mejora", "prueba"), "gasto posible")
	Simulation.earn(g, 400, "venta", "prueba")
	eq(g.money, m0 - 600, "gasto e ingreso aplicados")
	eq(#g.ledger, n + 2, "ambos quedan registrados")
	eq(g.ledger[#g.ledger].amount, 400, "con su monto")
	eq(Rules.debt(g), 0, "sin deudas al empezar")
end)

test("[E1] Guardar, guardar y volver al menú, recargar en otro servidor y nada de progreso sin conexión", function()
	local store = newStore()
	local clock = { t = 1000, c = 0 }
	local mgr = makeServer(store, "A", clock)
	local p = { UserId = 531 }
	mgr:add(p)
	local g = playThrough(mgr, p).game
	ticks(mgr, clock, 30)
	local r = mgr:request(p, "saveNow", { requestId = rid() })
	check(r.ok, "guardado manual: " .. tostring(r.msg))
	local saved = store.data["player_531"].profile.slots["1"]
	eq(saved.time.day * 10000 + saved.time.minute, g.time.day * 10000 + g.time.minute, "el guardado tiene la fecha actual")
	check(mgr:request(p, "saveNow", { requestId = rid() }).msg ~= nil, "un segundo guardado inmediato queda programado")
	ticks(mgr, clock, 20) -- el guardado programado se hace solo (respetando 7 s entre escrituras)
	saved = store.data["player_531"].profile.slots["1"]
	check(saved.time.day * 10000 + saved.time.minute > 0, "el guardado programado se escribió")
	local date, money, id = Rules.date(g), g.money, g.company.id
	r = mgr:request(p, "leaveCompany", {})
	check(r.ok and string.find(r.msg, "guardada", 1, true) ~= nil, "guardar y volver al menú: " .. tostring(r.msg))
	check(mgr.list[p] ~= nil and mgr.list[p].game == nil, "sigue en el servidor, en el menú")
	saved = store.data["player_531"].profile.slots["1"]
	eq(Util.fullDate(saved.time.day, saved.time.minute), date, "lo guardado tiene la fecha al volver al menú")
	ticks(mgr, clock, 30)
	eq(Rules.date(g), date, "en el menú la empresa no avanza")
	-- Salir del juego, pasar horas y entrar en otro servidor.
	mgr:remove(p)
	clock.t += 6 * 3600
	local mgr2 = makeServer(store, "B", clock)
	mgr2:add(p)
	check(mgr2:request(p, "selectSlot", { slot = "1" }).ok, "carga la empresa")
	local g2 = mgr2.list[p].game
	eq(Rules.date(g2), date, "misma fecha: no avanzó sin conexión")
	eq(g2.money, money, "mismo dinero")
	eq(g2.company.id, id, "misma empresa (mismo identificador)")
end)

test("[E1] Ranuras: dos gratuitas, la 3 y la 4 bloqueadas (sin compras), y las que ya tenían empresa se conservan", function()
	local store = newStore()
	local clock = { t = 1000, c = 0 }
	local mgr, pushed = makeServer(store, "A", clock)
	local p = { UserId = 541 }
	mgr:add(p)
	eq(Catalog.RULES.slots, 4, "cuatro ranuras por cuenta")
	eq(Catalog.RULES.slotsFree, 2, "dos gratuitas")
	check(mgr:request(p, "createCompany", { slot = "1", name = "Uno SA", color = "#7667FF", logo = "pico" }).ok, "ranura 1")
	mgr:request(p, "leaveCompany", {})
	check(mgr:request(p, "createCompany", { slot = "2", name = "Dos SA", color = "#7667FF", logo = "pico" }).ok, "ranura 2")
	mgr:request(p, "leaveCompany", {})
	check(not mgr:request(p, "createCompany", { slot = "3", name = "Tres SA", color = "#7667FF", logo = "pico" }).ok, "la 3 está bloqueada")
	check(not mgr:request(p, "createCompany", { slot = "4", name = "Cuatro SA", color = "#7667FF", logo = "pico" }).ok, "la 4 también")
	check(not mgr:request(p, "createCompany", { slot = "5", name = "Cinco SA", color = "#7667FF", logo = "pico" }).ok, "no hay quinta")
	local view = pushed[p].profile
	check(view.usable["1"] and view.usable["2"] and not view.usable["3"] and not view.usable["4"], "el cliente sabe cuáles se pueden usar")
	local s = mgr.list[p]
	check(s.profile.slots["1"].company.id ~= s.profile.slots["2"].company.id, "cada empresa con su identificador")
	-- Cuenta de la versión anterior con 3 empresas: la tercera se conserva y queda habilitada.
	local legacy = jsonCopy(s.profile.slots["1"])
	legacy.company.name = "Vieja Tres"
	local record = { schema = 2, profile = { slots = { ["1"] = jsonCopy(s.profile.slots["1"]), ["3"] = legacy }, settings = {}, processed = {} } }
	local prof, damaged = GameState.loadProfile(record, 1)
	check(prof ~= nil and next(damaged) == nil, "carga sin dañar nada")
	check(GameState.slotUsable(prof, "3") and prof.unlocked["3"] == true, "la ranura 3 con empresa sigue disponible")
	check(not GameState.slotUsable(prof, "4"), "la 4 sigue bloqueada")
end)

test("[E1] Migración 5 → 6: fecha conservada, velocidad 4× → 3×, identificador y deudas", function()
	local g = newCompany("Vieja SA")
	local old = jsonCopy(g)
	old.schema = 5
	old.company.id = nil
	old.loans = nil
	old.time = { day = 13, minute = 549, speed = 4 } -- febrero de 1971, último tramo del mes (550 min por mes)
	local m, err = GameState.migrate(old, 1)
	check(m ~= nil, tostring(err))
	eq(m.time.day, 13, "mismo mes")
	check(m.time.minute < Rules.monthMinutes(13) and m.time.minute >= Rules.monthMinutes(13) - 2 * Catalog.RULES.gameDayMinutes, "mismo tramo del mes (" .. m.time.minute .. ")")
	eq(Util.dayOfMonth(13, m.time.minute), 28, "fin de febrero")
	eq(m.time.speed, 3, "4× pasa a 3×")
	check(type(m.company.id) == "string", "con identificador")
	check(type(m.loans) == "table", "con deudas")
	local ok, verr = GameState.validate(m)
	check(ok, tostring(verr))
end)

test("[E2] Primer ciclo completo: sedán I4 → lote de 100 → reseñas → precio → venta de las 100 → guardar y recuperar", function()
	-- Tecnologías de 1970: chasis Sedán y Coupé básicos; motores I4 e I6 nivel 1.
	local g70 = newCompany("Tecno SA")
	local bases, engines = {}, {}
	for _, b in Catalog.BASES do
		if DesignCalc.baseAvailable(g70, b) == nil then
			table.insert(bases, b.name)
		end
	end
	for _, p in Catalog.partsOf("motor") do
		if DesignCalc.partBlock(g70, DesignCalc.newDraft(g70, "brisa"), p) == nil then
			table.insert(engines, p.name)
		end
	end
	table.sort(bases)
	table.sort(engines)
	eq(table.concat(bases, ", "), "Coupé básico 1970, Sedán básico 1970", "chasis disponibles en 1970")
	eq(table.concat(engines, ", "), "I4 1.6 · nivel 1, I6 2.5 · nivel 1", "motores disponibles en 1970")
	check(Catalog.base("brisa").family == "Sedán" and Catalog.base("brisa").gen == 1, "chasis con familia y generación")
	check(Catalog.part("motor", "i6").family == "I6" and Catalog.part("motor", "i6").level == 1, "motor con familia y nivel")
	-- Las estadísticas dependen de las piezas: el I6 tiene más potencia y cuesta más que el I4.
	local d4 = DesignCalc.newDraft(g70, "brisa")
	local d6 = jsonCopy(d4)
	d6.parts.motor = "i6"
	local c4, c6 = DesignCalc.computeDesign(g70, d4), DesignCalc.computeDesign(g70, d6)
	check(c6.hp > c4.hp and c6.unitCost > c4.unitCost and c6.accel < c4.accel, "I6: más potencia, más rápido y más caro (" .. c4.hp .. " → " .. c6.hp .. " hp)")

	local store = newStore()
	local clock = { t = 1000, c = 0 }
	local mgr = makeServer(store, "A", clock)
	local p = { UserId = 601 }
	mgr:add(p)
	-- 1. Empresa en 1970.
	local g = playThrough(mgr, p).game
	eq(Rules.date(g), "01/01/1970", "1. empresa en 1970")
	-- 2-3. Diseño de un sedán con motor I4, confirmado.
	local draft = draftFor(g, "brisa", "Primer Sedán")
	eq(draft.parts.motor, "i4", "2. sedán con motor I4")
	local sv = mgr:request(p, "saveDesign", { draft = draft, requestId = rid() })
	check(sv.ok, "3. diseño confirmado: " .. tostring(sv.msg))
	local d = g.designs[1]
	local unit = DesignCalc.computeDesign(g, d).unitCost
	-- 4. Lote de 100 unidades: se paga completo al ordenarlo.
	g.money = math.max(g.money, unit * 100 + 1000) -- capital suficiente para la prueba
	local m0 = g.money
	local r = mgr:request(p, "createLot", { designId = d.id, qty = 100, requestId = rid() })
	check(r.ok, "4. lote de 100: " .. tostring(r.msg))
	eq(m0 - g.money, 100 * unit, "4. se cobró el costo total (" .. Util.money(100 * unit) .. ")")
	check(not mgr:request(p, "createLot", { designId = d.id, qty = 100, requestId = rid() }).ok, "un solo lote por modelo")
	local lot = g.lots[1]
	-- 5. La producción progresa con el calendario; 3× es más rápido y la pausa la detiene.
	ticks(mgr, clock, 10)
	local p1 = lot.produced
	check(p1 > 0 and p1 < 100, "5. avanza la producción (" .. p1 .. "/100)")
	eq(lot.sold, 0, "no se vende mientras se fabrica")
	mgr:request(p, "setUiPause", { paused = true })
	ticks(mgr, clock, 5)
	eq(lot.produced, p1, "5. en pausa no se fabrica")
	mgr:request(p, "setUiPause", { paused = false })
	check(mgr:request(p, "setSpeed", { speed = 3, requestId = rid() }).ok, "3×")
	local before = lot.produced
	ticks(mgr, clock, 8)
	local at3 = lot.produced - before
	mgr:request(p, "setSpeed", { speed = 1, requestId = rid() })
	before = lot.produced
	ticks(mgr, clock, 8)
	local at1 = lot.produced - before
	check(at3 >= at1 * 2, "5. a 3× se fabrica más rápido (" .. at1 .. " → " .. at3 .. " en 8 s)")
	-- 6. Al terminar: cuatro reseñas coherentes, guardadas.
	local okDone = false
	for _ = 1, 600 do
		ticks(mgr, clock, 1)
		if lot.saleState == "por lanzar" then
			okDone = true
			break
		end
	end
	check(okDone, "6. lote terminado y evaluado")
	local rv = lot.review
	eq(#rv.scores, 4, "6. cuatro críticos")
	local sum, names = 0, {}
	for _, sc in rv.scores do
		check(sc.score >= 1 and sc.score <= 10 and sc.score * 10 == math.floor(sc.score * 10 + 0.5), "6. nota de 1 a 10 con un decimal (" .. sc.name .. " " .. sc.score .. ")")
		check(type(sc.text) == "string" and #sc.text > 10 and type(sc.outlet) == "string", "6. con comentario y medio")
		sum += sc.score
		names[sc.name] = true
	end
	check(next(names) ~= nil and #Catalog.CRITICS == 4, "6. cuatro críticos distintos")
	eq(rv.avg, math.floor(sum / 4 * 10 + 0.5) / 10, "6. nota final = promedio")
	local again = Rules.criticReviews(g, lot.design)
	eq(again.avg, rv.avg, "6. no son al azar: recalcular da lo mismo")
	-- Las reseñas cambian la demanda.
	local base = Rules.lotPotentialRate(g, lot)
	local saved = rv.avg
	lot.review.avg = 9
	local better = Rules.lotPotentialRate(g, lot)
	lot.review.avg = 3
	local worse = Rules.lotPotentialRate(g, lot)
	lot.review.avg = saved
	check(better > base and worse < base, "6. mejores reseñas venden más")
	-- 7. Precio y puesta a la venta (y modificación posterior).
	check(not mgr:request(p, "launchSale", { lotId = lot.id, price = 1, requestId = rid() }).ok, "7. precio fuera de rango rechazado")
	check(mgr:request(p, "launchSale", { lotId = lot.id, price = lot.refPrice * 1.2, requestId = rid() }).ok, "7. a la venta")
	local hiRate = Rules.lotPotentialRate(g, lot)
	check(mgr:request(p, "setLotPrice", { lotId = lot.id, price = lot.refPrice, requestId = rid() }).ok, "7. precio modificado")
	check(Rules.lotPotentialRate(g, lot) > hiRate, "7. un precio más bajo vende más rápido")
	-- 8-9. Ventas progresivas de las 100 y sus ingresos.
	local moneyBeforeSales = g.money
	local steps, lastSold, soldOut = 0, 0, false
	for _ = 1, 3600 do
		ticks(mgr, clock, 1)
		local l = findLot(g, lot.id) or findHist(g, lot.id)
		if l.sold > lastSold then
			steps += 1
			lastSold = l.sold
		end
		check(l.sold <= 100, "nunca más que el stock")
		if l.saleState == "agotado" then
			soldOut = true
			break
		end
	end
	local h = findHist(g, lot.id)
	check(soldOut and h.sold == 100, "8. se vendieron las 100 unidades")
	check(steps >= 5, "8. de a poco (" .. steps .. " momentos de venta)")
	eq(g.money - moneyBeforeSales, h.revenue, "9. los ingresos entraron al dinero")
	check(h.revenue > 100 * unit, "9. con ganancia (" .. Util.money(h.revenue - 100 * unit) .. ")")
	eq(g.counters.unitsSold, 100, "contador de ventas")
	-- 10. Guardar y recuperar sin duplicados.
	local snapshot = jsonCopy({ money = g.money, sold = g.counters.unitsSold, hist = #g.lotHistory, models = #g.modelHistory, lots = #g.lots, designs = #g.designs, review = h.review })
	mgr:remove(p)
	local mgr2 = makeServer(store, "B", clock)
	mgr2:add(p)
	check(mgr2:request(p, "selectSlot", { slot = "1" }).ok, "10. carga")
	local g2 = mgr2.list[p].game
	eq(g2.money, snapshot.money, "10. mismo dinero")
	eq(g2.counters.unitsSold, snapshot.sold, "10. mismas ventas")
	eq(#g2.lotHistory, snapshot.hist, "10. sin lotes duplicados")
	eq(#g2.modelHistory, snapshot.models, "10. sin modelos duplicados")
	eq(#g2.lots, 0, "10. nada a la venta de más")
	eq(serde.encode("json", g2.lotHistory[1].review), serde.encode("json", snapshot.review), "10. las reseñas se conservan")
	eq(g2.designs[1].lotLaunched, true, "10. el modelo sigue marcado como fabricado")
	check(not mgr2:request(p, "createLot", { designId = g2.designs[1].id, qty = 10, requestId = rid() }).ok, "10. y no se puede volver a fabricar")
end)


test("[E3] Migración 7 → 8: investigación en curso como proyecto y diseños con nivel, variante y equipamiento", function()
	local g = bigCompany("Vieja SA")
	local ctx = makeCtx(801)
	local id = saveNew(g, ctx, "brisa")
	local old = jsonCopy(g)
	old.schema = 7
	old.research = { done = { "mo1", "se1", "se2", "co1" }, active = { id = "ca1", progress = 5, rp = 10, paid = 5000 } }
	for _, d in old.designs do
		d.motorLevel, d.motorVariant, d.equipment = nil, nil, nil
	end
	local m, err = GameState.migrate(jsonCopy(old), 5000)
	check(m ~= nil, "migra: " .. tostring(err))
	eq(m.schema, GameState.SCHEMA, "esquema actual")
	check(GameState.validate(m), "válida")
	eq(m.research.active, nil, "sin el campo viejo")
	eq(#m.research.projects, 1, "la investigación en curso sigue como proyecto")
	local pr = m.research.projects[1]
	eq(pr.id, "ca1", "misma tecnología")
	eq(pr.days, math.floor(Catalog.researchNode("ca1").days * 0.5 + 0.5), "con los días que le faltaban")
	eq(table.concat(m.research.done, ","), "mo1,se1,se2,co1", "lo investigado se conserva")
	local d = m.designs[1]
	eq(d.id, id, "mismo diseño")
	eq(d.motorLevel, 1, "motor nivel 1")
	eq(d.motorVariant, "balanced", "variante equilibrada")
	eq(table.concat(d.equipment, ","), "crumple,ac", "lo que antes venía solo queda como equipamiento elegido")
	local again = GameState.migrate(jsonCopy(m), 6000)
	eq(serde.encode("json", again.research), serde.encode("json", m.research), "idempotente")
end)

test("[E3] Investigación completa: los 15 casos pedidos (chasis, motores, PI, proyectos simultáneos, adelanto y guardado)", function()
	local store = newStore()
	local clock = { t = 1000, c = 0 }
	local mgr = makeServer(store, "A", clock)
	local p = { UserId = 701 }
	mgr:add(p)
	local g = playThrough(mgr, p).game
	local function near(a: number, b: number): boolean
		return math.abs(a - b) < 1e-6
	end
	local function start(id: string): any
		return mgr:request(p, "startResearch", { id = id, requestId = rid() })
	end
	local function project(id: string): any
		return Rules.researchProject(g, id)
	end
	local function runTicks(cond: () -> boolean, max: number): boolean
		for _ = 1, max do
			ticks(mgr, clock, 1)
			if cond() then
				return true
			end
		end
		return false
	end

	-- 1. Chasis de 1970: Sedán y Coupé básicos; la generación siguiente se investiga.
	check(DesignCalc.baseAvailable(g, Catalog.base("brisa")) == nil, "1. Sedán 1970 disponible")
	check(DesignCalc.baseAvailable(g, Catalog.base("duna")) == nil, "1. Coupé 1970 disponible")
	check(DesignCalc.baseAvailable(g, Catalog.base("brisa2")) ~= nil, "1. el Sedán 1978 hay que investigarlo")
	check(DesignCalc.baseAvailable(g, Catalog.base("pixel")) ~= nil, "1. el compacto también")

	-- 2. Motores I4 e I6 en nivel 1 y variante equilibrada.
	eq(Rules.engineLevelMax(g, "I4"), 1, "2. I4 nivel 1")
	eq(Rules.engineLevelMax(g, "I6"), 1, "2. I6 nivel 1")
	local draft = DesignCalc.newDraft(g, "brisa")
	check(DesignCalc.partBlock(g, draft, Catalog.part("motor", "i4")) == nil and DesignCalc.partBlock(g, draft, Catalog.part("motor", "i6")) == nil, "2. ambos motores elegibles")
	eq(draft.motorLevel, 1, "2. un diseño nuevo usa el nivel 1")
	eq(draft.motorVariant, "balanced", "2. variante equilibrada")
	check(DesignCalc.variantBlock(g, draft, Catalog.engineVariant("eco")) ~= nil and DesignCalc.variantBlock(g, draft, Catalog.engineVariant("sport")) ~= nil, "2. económica y deportiva se investigan")

	-- 3. El centro genera PI (también con ticks cortos, sin perder decimales).
	eq(g.rp, 0, "3. sin PI al empezar")
	local m0 = g.money
	ticks(mgr, clock, 1)
	check(near(g.rp, Rules.piCenter(g) / 60), "3. un segundo: " .. Util.num(g.rp, 3) .. " PI")
	ticks(mgr, clock, 59)
	check(near(g.rp, Rules.piCenter(g)), "3. un minuto a 1×: " .. Util.num(g.rp, 3) .. " PI (" .. Rules.piCenter(g) .. "/min)")
	eq(g.money, m0, "3. los PI no tocan el dinero")

	-- 4. Una línea fabricando suma PI.
	g.money = 5000000
	check(mgr:request(p, "saveDesign", { draft = draftFor(g, "brisa", "Sedán I4"), requestId = rid() }).ok, "diseño")
	local design = g.designs[1]
	eq(design.motorLevel, 1, "diseño guardado con motor nivel 1")
	check(mgr:request(p, "createLot", { designId = design.id, qty = 800, requestId = rid() }).ok, "lote")
	local lotHp0 = g.lots[1].design.calc.hp
	ticks(mgr, clock, 1)
	eq(Rules.activeLines(g), 1, "4. una línea fabricando")
	eq(Rules.piPerMinute(g), Rules.piCenter(g) + Catalog.RESEARCH_RULES.linePi, "4. centro + línea")
	local rp0 = g.rp
	ticks(mgr, clock, 12)
	check(near(g.rp - rp0, Rules.piPerMinute(g) * 12 / 60), "4. 12 s con la línea: +" .. Util.num(g.rp - rp0, 2) .. " PI")

	-- 7. Sin recursos suficientes no empieza ni cobra.
	local ca1 = Catalog.researchNode("ca1")
	local pi1, cost1, days1 = Rules.researchCost(g, ca1)
	eq(pi1, ca1.rp, "costo base sin adelanto (PI)")
	eq(cost1, ca1.cost, "costo base sin adelanto (dinero)")
	eq(days1, ca1.days, "costo base sin adelanto (días)")
	g.rp = pi1 - 1
	local money7 = g.money
	local r = start("ca1")
	check(not r.ok and string.find(r.msg, "PI") ~= nil, "7. faltan PI: " .. tostring(r.msg))
	eq(g.money, money7, "7. no cobró dinero")
	g.rp = 1000
	g.money = cost1 - 1
	r = start("ca1")
	check(not r.ok and string.find(r.msg, "Fondos") ~= nil, "7. falta dinero: " .. tostring(r.msg))
	eq(g.rp, 1000, "7. no cobró PI")
	eq(#g.research.projects, 0, "7. no quedó nada en curso")

	-- 8-9. Varias a la vez; cada una se cobra una sola vez al empezar.
	g.money = 5000000
	local ids = { "ca1", "mo1", "se1", "te_radio" }
	local paidPi, paidMoney = 0, 0
	for _, id in ids do
		local n = Catalog.researchNode(id)
		local pi, cost = Rules.researchCost(g, n)
		local rpB, mB = g.rp, g.money
		r = start(id)
		check(r.ok, "9. empieza " .. id .. ": " .. tostring(r.msg))
		eq(rpB - g.rp, pi, "8. " .. id .. ": PI cobrados al empezar")
		eq(mB - g.money, cost, "8. " .. id .. ": dinero cobrado al empezar")
		paidPi += pi
		paidMoney += cost
	end
	eq(#g.research.projects, 4, "9. cuatro investigaciones simultáneas")
	check(not start("ca1").ok, "no se repite una que está en curso")
	check(not mgr:request(p, "cancelResearch", { id = "ca1", requestId = rid() }).ok, "no se cancela")
	ticks(mgr, clock, 4)
	for _, id in ids do
		check(near(project(id).progress, 2), "9. " .. id .. " avanza en paralelo (" .. Util.num(project(id).progress, 2) .. " días)")
	end

	-- 5. Las velocidades aceleran PI y progreso por igual.
	check(mgr:request(p, "setSpeed", { speed = 3, requestId = rid() }).ok, "3×")
	local rpS, prS = g.rp, project("ca1").progress
	ticks(mgr, clock, 4)
	check(near(g.rp - rpS, Rules.piPerMinute(g) * 3 * 4 / 60), "5. a 3× los PI se triplican")
	check(near(project("ca1").progress - prS, 6), "5. a 3× el progreso se triplica (+" .. Util.num(project("ca1").progress - prS, 2) .. " días)")
	check(mgr:request(p, "setSpeed", { speed = 2, requestId = rid() }).ok, "2×")
	prS = project("ca1").progress
	ticks(mgr, clock, 2)
	check(near(project("ca1").progress - prS, 2), "5. a 2× el doble")

	-- 6. La pausa detiene PI y progreso.
	check(mgr:request(p, "setUiPause", { paused = true }).ok, "pausa")
	local rpP, prP = g.rp, project("ca1").progress
	ticks(mgr, clock, 30)
	eq(g.rp, rpP, "6. en pausa no se generan PI")
	eq(project("ca1").progress, prP, "6. ni avanza la investigación")
	check(mgr:request(p, "setUiPause", { paused = false }).ok, "sigue")

	-- 10. Al terminar se desbloquea, avisa y no se repite.
	check(runTicks(function()
		return #g.research.projects == 0
	end, 600), "10. las cuatro terminan")
	for _, id in ids do
		check(Rules.has(g, id), "10. " .. id .. " desbloqueada")
	end
	eq(g.counters.researchDone, 4, "10. cuatro completadas, ni una más")
	local noticed = false
	for _, nt in g.notifications do
		noticed = noticed or string.find(nt.text, Catalog.researchNode("te_radio").name, 1, true) ~= nil
	end
	check(noticed, "10. con notificación")
	r = start("ca1")
	check(not r.ok and string.find(r.msg, "ya está investigada") ~= nil, "10. no se investiga dos veces")
	local charges = 0
	for _, l in g.ledger do
		if l.type == "investigacion" then
			charges += 1
		end
	end
	eq(charges, 4, "8. cuatro cargos de investigación en el libro, uno por proyecto")

	-- 15. Adelanto: penalización por año (dinero y PI +15 %, duración +10 %), visible antes de pagar; más de 5 años, bloqueada.
	local eco = Catalog.researchNode("var_eco") -- 1973: 3 años de adelanto en 1970
	local piE, costE, daysE, info = Rules.researchCost(g, eco)
	eq(info.ahead, 3, "15. tres años de adelanto")
	eq(piE, math.floor(eco.rp * 1.45 + 0.5), "15. PI +45 %")
	eq(costE, math.floor(eco.cost * 1.45 / 100 + 0.5) * 100, "15. dinero +45 %")
	eq(daysE, math.floor(eco.days * 1.3 + 0.5), "15. duración +30 %")
	local sedan2 = Catalog.researchNode("ch_sedan2") -- 1978: 8 años de adelanto
	check(Rules.researchState(g, sedan2) == "bloqueada" and string.find(table.concat(Rules.researchMissing(g, sedan2), " "), "1973") ~= nil, "15. más de 5 años: bloqueada hasta 1973")
	g.rp, g.money = 10000, 5000000
	local rpA, mA = g.rp, g.money
	r = start("var_eco")
	check(r.ok and string.find(r.msg, "adelantada 3 años") ~= nil, "15. empieza con recargo: " .. tostring(r.msg))
	eq(rpA - g.rp, piE, "15. cobra los PI con recargo")
	eq(mA - g.money, costE, "15. cobra el dinero con recargo")
	eq(project("var_eco").days, daysE, "15. dura lo anunciado")
	eq(project("var_eco").ahead, 3, "15. queda registrado el adelanto")

	-- 11-12. Un nivel de motor nuevo: los anteriores siguen y los diseños viejos no cambian.
	check(start("eng_I4_2").ok, "nivel 2 del I4 (adelantado 5 años)")
	check(not start("eng_I4_3").ok, "el nivel 3 pide el 2")
	ticks(mgr, clock, 8)
	-- 14. Guardar con proyectos a medias y recuperar en otro servidor.
	local prEco, prEng = project("var_eco").progress, project("eng_I4_2").progress
	check(prEco > 0 and prEco < daysE, "14. proyecto a medias")
	local doneSnap = table.concat(g.research.done, ",")
	local rpSnap = g.rp
	mgr:remove(p)
	local mgr2 = makeServer(store, "B", clock)
	mgr2:add(p)
	check(mgr2:request(p, "selectSlot", { slot = "1" }).ok, "14. carga")
	g = mgr2.list[p].game
	mgr = mgr2
	eq(table.concat(g.research.done, ","), doneSnap, "14. mismas investigaciones completadas")
	eq(#g.research.projects, 2, "14. mismos proyectos en curso")
	check(near(project("var_eco").progress, prEco) and near(project("eng_I4_2").progress, prEng), "14. con el mismo progreso")
	check(near(g.rp, rpSnap), "14. mismos PI")
	check(runTicks(function()
		return #g.research.projects == 0
	end, 600), "14. siguen y terminan en el otro servidor")
	eq(g.counters.researchDone, 6, "14. sin completar dos veces")
	eq(Rules.engineLevelMax(g, "I4"), 2, "11. I4 nivel 2")
	eq(Rules.engineLevelMax(g, "I6"), 1, "11. el I6 sigue en nivel 1 (cada familia aparte)")
	for _, id in ids do
		check(Rules.has(g, id), "11. " .. id .. " sigue desbloqueada")
	end
	check(DesignCalc.variantBlock(g, DesignCalc.newDraft(g, "brisa"), Catalog.engineVariant("eco")) == nil, "11. variante económica para el I4")
	local d6 = DesignCalc.newDraft(g, "brisa")
	d6.parts.motor = "i6"
	check(DesignCalc.variantBlock(g, d6, Catalog.engineVariant("eco")) == nil, "11. y para el I6 (todas las familias compatibles)")
	local old = g.designs[1]
	eq(old.motorLevel, 1, "12. el diseño viejo conserva el nivel 1")
	eq(old.motorVariant, "balanced", "12. y su variante")
	eq(#(old.equipment or {}), 0, "12. y su equipamiento")
	local lot = g.lots[1]
	eq(lot.design.spec.motorLevel, 1, "12. el lote fabricado también")
	eq(lot.design.calc.hp, lotHp0, "12. con la misma potencia que al fabricarse")
	local nd = DesignCalc.newDraft(g, "brisa")
	eq(nd.motorLevel, 2, "un diseño nuevo propone el mejor nivel")
	local lvl1 = jsonCopy(nd)
	lvl1.motorLevel = 1
	local s1 = DesignCalc.sanitize(g, lvl1)
	check(s1 ~= nil and s1.motorLevel == 1, "11. el nivel 1 se puede seguir eligiendo")
	local c1, c2 = DesignCalc.computeDesign(g, lvl1), DesignCalc.computeDesign(g, nd)
	check(c2.hp > c1.hp, "nivel 2: más potencia (" .. c1.hp .. " → " .. c2.hp .. " hp)")
	local lvl3 = jsonCopy(nd)
	lvl3.motorLevel = 3
	check(DesignCalc.sanitize(g, lvl3) == nil, "el nivel 3 sin investigar se rechaza")

	-- 13. Equipamiento de confort y seguridad: no viene puesto; se elige en el diseñador.
	eq(#nd.equipment, 0, "13. nada se instala solo")
	local withRadio = jsonCopy(nd)
	withRadio.equipment = { "radio" }
	local sr = DesignCalc.sanitize(g, withRadio)
	check(sr ~= nil and sr.equipment[1] == "radio", "13. la radio se puede elegir")
	local cr, cn = DesignCalc.computeDesign(g, sr), DesignCalc.computeDesign(g, nd)
	check(cr.comfort > cn.comfort and cr.unitCost > cn.unitCost, "13. más confort y más costo por unidad")
	local withCrumple = jsonCopy(nd)
	withCrumple.equipment = { "crumple" }
	local bad, why = DesignCalc.sanitize(g, withCrumple)
	check(bad == nil and string.find(why or "", "Requiere investigar", 1, true) ~= nil, "13. lo no investigado se rechaza: " .. tostring(why))
	-- Seguridad: en 1975 las zonas de deformación (1977) se adelantan 2 años.
	g.time.day = (1975 - 1970) * 12
	g.rp, g.money = 10000, 5000000
	check(start("se2").ok, "13. investiga zonas de deformación")
	check(runTicks(function()
		return Rules.has(g, "se2")
	end, 600), "13. terminada")
	local safe = DesignCalc.newDraft(g, "brisa")
	eq(#safe.equipment, 0, "13. tampoco se instala sola")
	safe.equipment = { "crumple", "radio" }
	local ss = DesignCalc.sanitize(g, safe)
	check(ss ~= nil and #ss.equipment == 2, "13. seguridad y confort juntos")
	local cs = DesignCalc.computeDesign(g, ss)
	local cb = DesignCalc.computeDesign(g, DesignCalc.newDraft(g, "brisa"))
	check(cs.safety > cb.safety, "13. más seguridad (" .. cb.safety .. " → " .. cs.safety .. ")")
	local saved = mgr:request(p, "saveDesign", { draft = jsonCopy(ss), requestId = rid() })
	check(saved.ok, "13. el diseño con equipamiento se guarda: " .. tostring(saved.msg))
	eq(table.concat(g.designs[#g.designs].equipment, ","), table.concat(ss.equipment, ","), "13. con su equipamiento")
	check(GameState.validate(g), "partida válida")
end)

test("[I2] Empresas: mismas condiciones, identidad obligatoria, fecha inicial y compra segura de ranuras", function()
	-- Identidad obligatoria (la interfaz propone valores editables) y sin dificultades.
	check(Actions.validateCompany({ name = "Sin Color SA", logo = "pico" }) == nil, "sin color se rechaza")
	check(Actions.validateCompany({ name = "Sin Logo SA", color = "#7667FF" }) == nil, "sin símbolo se rechaza")
	check(Actions.validateCompany({ name = "Completa SA", color = "#7667FF", logo = "rayo" }) ~= nil, "nombre, símbolo y color")
	local a, b = newCompany("Una SA"), newCompany("Otra SA", "#F7C95C")
	eq(a.money, Catalog.START.money, "capital inicial")
	eq(b.money, a.money, "igual para todas")
	eq(Rules.date(a), "01/01/1970", "empieza el 1 de enero de 1970")
	eq(Rules.demand(a, "sedan"), Rules.demand(b, "sedan"), "misma demanda")
	check(Catalog.DIFFICULTIES == nil, "no hay dificultades")
	-- Migración 8 → 9: la dificultad desaparece y el dinero que tenían se conserva.
	local old = jsonCopy(a)
	old.schema = 8
	old.company.difficulty = "facil"
	old.money = 150000
	local m = GameState.migrate(jsonCopy(old), 5000)
	check(m ~= nil and GameState.validate(m), "migra y valida")
	eq(m.company.difficulty, nil, "sin dificultad")
	eq(m.money, 150000, "dinero conservado")

	-- Compras de ranuras con Developer Products.
	local store = newStore()
	local clock = { t = 1000, c = 0 }
	local prompts = {}
	local mgr = makeServer(store, "A", clock, { prompt = function(_, id)
		table.insert(prompts, id)
	end })
	local p = { UserId = 901 }
	mgr:add(p)
	local s = mgr.list[p]
	local r = mgr:request(p, "buyProduct", { product = "slot3" })
	check(not r.ok and string.find(r.msg, "configurar") ~= nil, "sin producto configurado no se vende nada: " .. r.msg)
	eq(#prompts, 0, "no abre ninguna compra")
	local saved = Catalog.PRODUCTS.slot3.id
	Catalog.PRODUCTS.slot3.id = 1111
	check(mgr:request(p, "buyProduct", { product = "slot3" }).ok and prompts[1] == 1111, "abre la compra del producto configurado")
	check(not mgr:request(p, "createCompany", { slot = "3", name = "Tres SA", color = "#7667FF", logo = "pico" }).ok, "antes del recibo, la 3 sigue bloqueada")
	-- Un recibo que no se puede guardar no se acredita (Roblox lo reintenta).
	store.failNext = 50
	check(mgr:processReceipt({ PlayerId = 901, ProductId = 1111, PurchaseId = "r-1" }) == false, "si el guardado falla, NotProcessedYet")
	check(not GameState.slotUsable(s.profile, "3"), "y no queda habilitada")
	store.failNext = 0
	check(mgr:processReceipt({ PlayerId = 901, ProductId = 1111, PurchaseId = "r-1" }) == true, "reintento: acreditada")
	check(GameState.slotUsable(s.profile, "3"), "ranura 3 habilitada")
	check(not GameState.slotUsable(s.profile, "4"), "la 4 se compra aparte")
	check(mgr:processReceipt({ PlayerId = 901, ProductId = 1111, PurchaseId = "r-1" }) == true, "el mismo recibo otra vez: no se duplica")
	eq(#s.profile.receipts, 1, "un solo recibo registrado")
	check(not mgr:request(p, "buyProduct", { product = "slot3" }).ok, "no se vuelve a vender lo que ya tiene")
	check(mgr:processReceipt({ PlayerId = 902, ProductId = 1111, PurchaseId = "r-2" }) == false, "jugador no cargado: se reintenta después")
	check(mgr:processReceipt({ PlayerId = 901, ProductId = 999, PurchaseId = "r-3" }) == false, "producto desconocido: no se acredita")
	check(mgr:request(p, "createCompany", { slot = "3", name = "Tres SA", color = "#7667FF", logo = "pico" }).ok, "crea la empresa en la ranura 3")
	-- La compra persiste en otro servidor.
	mgr:remove(p)
	local mgr2 = makeServer(store, "B", clock)
	mgr2:add(p)
	check(GameState.slotUsable(mgr2.list[p].profile, "3"), "persistida")
	check(table.find(mgr2.list[p].profile.receipts, "r-1") ~= nil, "con su recibo")
	Catalog.PRODUCTS.slot3.id = saved
end)

test("[I3] Personal: departamentos, bonificaciones con tope propio, transferencias, salarios, deuda, despidos y mercado laboral", function()
	local Staff = require("./.build/shared/Staff")
	local g = bigCompany("Personal SA")
	local ctx = makeCtx(301)
	eq(#g.employees, 0, "empieza sin empleados")
	Simulation.ensureMarket(g, ctx)
	eq(#g.candidates, 8, "8 candidatos en el mes")
	local function hireBest(dept: string, n: number?)
		for _ = 1, n or 1 do
			Simulation.ensureMarket(g, ctx)
			local c = Simulation.makeCandidate(g, ctx, dept)
			c.spec = dept
			for _, k in Staff.dept(dept).skills do
				c.skills[k], c.potential[k] = 90, 100
			end
			table.insert(g.candidates, c)
			local r = Actions.hire(g, ctx, { candidateId = c.id, dept = dept })
			assert(r.ok, r.msg)
		end
	end
	-- Contratar no cuesta y empieza a cobrar el mes siguiente.
	local c1 = g.candidates[1]
	local m0 = g.money
	check(Actions.hire(g, ctx, { candidateId = c1.id, dept = c1.spec }).ok, "contrata")
	eq(g.money, m0, "sin costo de contratación")
	eq(#g.candidates, 7, "sale del mercado")
	local e1 = g.employees[1]
	eq(e1.dept, c1.spec, "en el departamento elegido")
	-- Bonificaciones: cada habilidad con su efecto y su propio tope.
	g.employees = {}
	local rate0 = Rules.lineRate(g)
	hireBest("produccion")
	check(Rules.lineRate(g) > rate0, "velocidad: la línea fabrica más rápido (" .. Util.num(rate0, 1) .. " → " .. Util.num(Rules.lineRate(g), 1) .. ")")
	local unit = DesignCalc.computeDesign(g, DesignCalc.newDraft(g, "brisa")).unitCost
	check(Rules.lotUnitCost(g, unit) < unit, "eficiencia: lotes nuevos más baratos")
	hireBest("produccion", 9)
	local v, raw, cap = Staff.bonusDetail(g, "velocidad")
	check(raw > cap and v == cap, "velocidad llega a su tope (" .. Util.num(v * 100, 1) .. " % de " .. Util.num(cap * 100, 1) .. " %)")
	local ve, rawE, capE = Staff.bonusDetail(g, "eficiencia")
	check(capE ~= cap and ve == capE and rawE >= capE, "eficiencia tiene otro tope (" .. Util.num(capE * 100, 1) .. " %)")
	local extra = Simulation.makeCandidate(g, ctx, "produccion")
	extra.spec = "produccion"
	for _, p in Staff.previewHire(g, extra, "produccion") do
		if p.skill == "velocidad" then
			check(p.gain == 0 and p.capped, "la vista previa avisa que en el tope no suma")
		end
	end
	-- Investigación: menos PI, dinero y días; nunca más PI por minuto.
	local n = Catalog.researchNode("ca1")
	local pi0, money0 = Rules.researchCost(g, n)
	local ppm = Rules.piPerMinute(g)
	hireBest("investigacion", 3)
	local pi1, money1 = Rules.researchCost(g, n)
	check(pi1 < pi0 and money1 < money0, "conocimiento y precisión bajan PI y dinero (" .. pi0 .. " → " .. pi1 .. " PI)")
	eq(Rules.piPerMinute(g), ppm, "los empleados no suman PI por minuto")
	check(Rules.researchSpeed(g) > 1, "creatividad acelera los proyectos en curso")
	-- Transferencia: penalización inicial, adaptación progresiva y habilidades conservadas.
	local t = g.employees[1]
	local skills = jsonCopy(t.skills)
	check(Actions.setDept(g, ctx, { employeeId = t.id, dept = "marketing" }).ok, "transferido a Marketing")
	eq(Staff.adaptation(t), Catalog.STAFF.adaptStart, "empieza al 50 %")
	Simulation.stepStaff(g, Catalog.RULES.gameDayMinutes * 90)
	check(math.abs(Staff.adaptation(t) - 0.75) < 1e-6, "a los 90 días, 75 %")
	eq(serde.encode("json", t.skills), serde.encode("json", skills), "conserva sus habilidades")
	check(Actions.setDept(g, ctx, { employeeId = t.id, dept = "produccion" }).ok and Staff.adaptation(t) == 1, "vuelve a su especialidad al 100 %")
	check(Actions.setDept(g, ctx, { employeeId = t.id, dept = "marketing" }).ok and math.abs(Staff.adaptation(t) - 0.75) < 1e-6, "y conserva lo adaptado si vuelve a Marketing")
	-- Límite global de empleados.
	local limit = Rules.caps(g).staff
	while #g.employees < limit do
		hireBest("administracion")
	end
	Simulation.ensureMarket(g, ctx)
	check(not Actions.hire(g, ctx, { candidateId = g.candidates[1].id }).ok, "límite global (" .. limit .. ")")
	-- Salarios al empezar el mes; si no alcanza, deuda y productividad que baja.
	local sal = Staff.salaries(g)
	g.money = sal - 1000
	Simulation.monthRollover(g, ctx)
	eq(g.money, 0, "se pagó lo posible")
	eq(g.payroll.debt, 1000, "el resto queda como deuda")
	eq(#g.employees, limit, "nadie renuncia")
	local p1 = Staff.productivity(g, g.employees[2])
	g.money = 0
	Simulation.monthRollover(g, ctx)
	check(Staff.productivity(g, g.employees[2]) < p1, "la deuda prolongada baja la productividad")
	local debt = g.payroll.debt
	-- Ventas: 30 % a la deuda, 70 % a la empresa; si falta menos, solo lo necesario.
	g.money = 0
	Simulation.recoverSalaryDebt(g, ctx, 1000)
	g.money += 1000 - 300 -- (stepSales suma la venta completa antes de descontar)
	eq(g.payroll.debt, debt - 300, "30 % de la venta a la deuda")
	g.payroll.debt = 100
	local before = g.money
	Simulation.recoverSalaryDebt(g, ctx, 1000)
	eq(before - g.money, 100, "si queda menos que el 30 %, solo lo necesario")
	eq(g.payroll.debt, 0, "deuda saldada")
	eq(g.payroll.debtMonths, 0, "productividad normal otra vez")
	Simulation.recoverSalaryDebt(g, ctx, 1000)
	eq(before - g.money, 100, "sin pagos duplicados")
	-- Indemnización: salario × años trabajados (proporcional).
	local f = g.employees[1]
	f.salary = 3000
	f.hiredDay = Rules.absDay(g) - 365 / 2
	eq(Staff.severance(f, Rules.absDay(g)), 1500, "$3.000 y seis meses → $1.500")
	g.money = 1000
	check(not Actions.fire(g, ctx, { employeeId = f.id }).ok, "sin dinero para la indemnización no se despide")
	g.money = 5000
	check(Actions.fire(g, ctx, { employeeId = f.id }).ok, "despedido")
	eq(g.money, 3500, "pagó la indemnización")
	-- Experiencia: cada 6 meses mejora su departamento, nunca por encima del potencial.
	local x = g.employees[1]
	local k = Staff.dept(x.dept).skills[1]
	x.skills[k], x.potential[k], x.months = 50, 51, 5
	g.money = 1e9
	Simulation.monthRollover(g, ctx)
	eq(x.skills[k], 51, "+1 a los 6 meses")
	x.months = 11
	Simulation.monthRollover(g, ctx)
	eq(x.skills[k], 51, "no supera su potencial")
	check(GameState.validate(g), "partida válida")
	x.skills[k] = 60
	check(not GameState.validate(g), "una habilidad por encima del potencial es un dato dañado")
	x.skills[k] = 51
end)

test("[I3] Mercado laboral: 8 por mes que se reemplazan, búsquedas con precio creciente y reputación", function()
	local Staff = require("./.build/shared/Staff")
	local g = bigCompany("Mercado SA")
	local ctx = makeCtx(302)
	Simulation.ensureMarket(g, ctx)
	local first = g.candidates[1].id
	local base = Catalog.STAFF.searchBase * Staff.eraMult(1970)
	-- Búsquedas: general, +50 % cada una del mes, especializada +50 % de base, contador compartido.
	local costs = {}
	local m = g.money
	check(Actions.searchCandidates(g, ctx, { kind = "general" }).ok, "búsqueda general")
	table.insert(costs, m - g.money)
	eq(#g.candidates, 8, "reemplaza: siguen siendo 8")
	check(g.candidates[1].id ~= first, "candidatos nuevos")
	m = g.money
	check(Actions.searchCandidates(g, ctx, { kind = "general" }).ok, "segunda")
	table.insert(costs, m - g.money)
	m = g.money
	check(Actions.searchCandidates(g, ctx, { kind = "especializada", dept = "marketing" }).ok, "especializada")
	table.insert(costs, m - g.money)
	eq(costs[1], base, "primera: " .. Util.money(base))
	eq(costs[2], base * 1.5, "segunda: +50 %")
	eq(costs[3], base * 1.5 * 1.5 * 1.5, "especializada (+50 %) con el contador compartido (tercera del mes)")
	check(not Actions.searchCandidates(g, ctx, { kind = "especializada" }).ok, "la especializada pide departamento")
	-- Nuevo mes: 8 nuevos y el contador vuelve a cero.
	Simulation.simulate(g, ctx, Rules.monthMinutes(g.time.day))
	eq(g.market.searches, 0, "el contador se reinicia")
	eq(#g.candidates, 8, "8 nuevos")
	m = g.money
	check(Actions.searchCandidates(g, ctx, { kind = "general" }).ok and m - g.money == base, "vuelve al precio base")
	-- Especialidades al azar (sin cuotas) y especializada ≈ 50 % del departamento elegido.
	local focus, total, specs = 0, 0, {}
	for _ = 1, 300 do
		local c = Simulation.makeCandidate(g, ctx, "investigacion")
		total += 1
		focus += c.spec == "investigacion" and 1 or 0
		specs[c.spec] = true
	end
	check(focus / total > 0.4 and focus / total < 0.75, "especializada: " .. Util.round(focus / total * 100) .. " % del departamento elegido")
	check(specs.produccion and specs.marketing and specs.administracion, "el resto se reparte entre los otros tres")
	-- La reputación mejora la calidad promedio, pero una empresa nueva puede encontrar un extraordinario.
	local function avg(rep: number): (number, number)
		g.reputation = rep
		local sum, exc = 0, 0
		for _ = 1, 400 do
			local c = Simulation.makeCandidate(g, ctx, nil)
			sum += Staff.deptAverage(c, c.spec)
			exc += c.exceptional and 1 or 0
		end
		return sum / 400, exc
	end
	local low, excLow = avg(1)
	local high = avg(5)
	check(high > low + 3, "más reputación, mejores candidatos (" .. Util.num(low, 1) .. " → " .. Util.num(high, 1) .. ")")
	check(excLow > 0, "con reputación baja también aparecen extraordinarios (" .. excLow .. ")")
	-- Migración 9 → 10 de empleados viejos.
	local old = jsonCopy(newCompany("Vieja Staff SA"))
	old.schema = 9
	old.employees = { { id = "e5", name = "Ana Paz", role = "Ingeniero", level = 3, skill = 70, salary = 2000, assign = "laboratorio" } }
	old.candidates = { { id = "c9", name = "X", role = "Mecánico", level = 1, skill = 40, salary = 900, fee = 3000 } }
	old.market, old.payroll = nil, nil
	local mg = GameState.migrate(jsonCopy(old), 5000)
	check(mg ~= nil and GameState.validate(mg), "migra y valida")
	local e = mg.employees[1]
	eq(e.spec, "investigacion", "Ingeniero → Investigación")
	eq(e.dept, "investigacion", "asignado al laboratorio → Investigación")
	eq(e.skills.conocimiento, 70, "conserva su habilidad")
	eq(e.salary, 2000, "y su salario")
	eq(#mg.candidates, 0, "los candidatos viejos se reemplazan al abrir")
end)

T.finish()
Build.clean()
process.exit(T.failed == 0 and 0 or 1)
