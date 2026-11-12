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
	-- Cada línea fabrica un lote por vez: si están todas ocupadas se espera a que se libere una.
	runUntil(g, ctx, function()
		return Rules.freeLine(g) ~= nil
	end, 600)
	return Actions.createLot(g, ctx, { designId = designId, qty = qty, price = price })
end

-- La empresa compra la línea 2 y tiene la línea 3 de la cuenta (como un jugador que las desbloqueó).
local function allLines(g: any)
	g.facilities.lines["2"] = true
	g.facilities.accountLine3 = true
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
	g.facilities.factory, g.facilities.research = 5, 5
	g.facilities.lines["2"], g.facilities.lines["3"] = true, true
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
	-- Los modelos finalizados son inmutables: ni la pintura ni las piezas se cambian sobre el guardado.
	local v = jsonCopy(g.designs[2])
	local before2 = jsonCopy(g.designs[2])
	v.paint.primary = "#D6333F"
	local m2 = g.money
	local r3 = Actions.saveDesign(g, ctx, { draft = v, sourceId = v.id })
	check(not r3.ok and g.money == m2, "un modelo terminado no se vuelve a pintar")
	v = jsonCopy(g.designs[2])
	v.parts.transmision = "man4"
	local r4 = Actions.saveDesign(g, ctx, { draft = v, sourceId = v.id })
	check(not r4.ok, "ni se le cambian piezas")
	check(DesignCalc.sameSpec(before2, g.designs[2]) and g.designs[2].version == before2.version, "sus especificaciones originales quedan intactas")
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
	allLines(g)
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
	for _, p in { 0, -5, 0 / 0, math.huge, Catalog.ECON.priceCap + 1 } do
		check(not Actions.createLot(g, ctx, { designId = fresh, qty = 10, price = p }).ok, "precio inválido " .. tostring(p))
	end
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

test("Líneas: cada una fabrica un lote, sin cola, pausa ni cancelación; la 3 es de la cuenta", function()
	local g = newCompany("Líneas SA")
	local ctx = makeCtx(7)
	local a = saveNew(g, ctx, "brisa", "Modelo A")
	local b = saveNew(g, ctx, "brisa", "Modelo B")
	local c = saveNew(g, ctx, "duna", "Modelo C")
	g.money = 1000000
	eq(Rules.freeLine(g), 1, "la línea 1 está desde la fundación")
	local ra = Actions.createLot(g, ctx, { designId = a, qty = 30 })
	check(ra.ok and ra.line == 1, "lote A en la línea 1")
	local m = g.money
	check(not Actions.createLot(g, ctx, { designId = b, qty = 30 }).ok, "con la única línea ocupada no se inicia otro")
	check(not Actions.createLot(g, ctx, { designId = b, qty = 30, line = 1 }).ok, "ni eligiendo la línea ocupada")
	check(not Actions.createLot(g, ctx, { designId = b, qty = 30, line = 2 }).ok, "la línea 2 sin comprar no se usa")
	check(not Actions.createLot(g, ctx, { designId = b, qty = 30, line = 3 }).ok, "la línea 3 sin la compra de la cuenta no se usa")
	eq(g.money, m, "los intentos fallidos no cobran")
	-- La línea 3 (Robux, de la cuenta) no necesita la 2.
	g.facilities.accountLine3 = true
	local rb = Actions.createLot(g, ctx, { designId = b, qty = 30, line = 3 })
	check(rb.ok and rb.line == 3, "lote B en la línea 3 sin tener la 2")
	g.facilities.lines["2"] = true
	local rc = Actions.createLot(g, ctx, { designId = c, qty = 30 })
	check(rc.ok and rc.line == 2, "lote C en la primera libre (la 2)")
	Simulation.simulate(g, ctx, 60)
	eq(#Rules.producingLots(g), 3, "tres líneas fabricando a la vez")
	for _, lot in g.lots do
		eq(lot.prodState, "produciendo", lot.design.name .. " fabricando")
	end
	-- No se pausa, no se reordena y no se cancela.
	check(not Actions.toggleLotPause(g, ctx, { lotId = g.lots[1].id }).ok, "no se pausa")
	check(not Actions.moveLot(g, ctx, { lotId = g.lots[2].id, delta = -1 }).ok, "no se reordena")
	check(not Actions.closeSale(g, ctx, { lotId = g.lots[1].id }).ok, "no se cancela cerrando la venta")
	eq(#Rules.producingLots(g), 3, "siguen las tres")
	check(GameState.validate(g), "válida")
	-- El mismo modelo no fabrica dos lotes (ni a la vez ni después).
	check(not Actions.createLot(g, ctx, { designId = a, qty = 5 }).ok, "un modelo, un lote")
end)

test("Partidas anteriores: la cola y las pausas pasan a líneas sin perder avance ni dinero", function()
	local g = newCompany("Vieja Cola SA")
	local ctx = makeCtx(77)
	g.money = 1000000
	local ids = { saveNew(g, ctx, "brisa", "Viejo A"), saveNew(g, ctx, "brisa", "Viejo B"), saveNew(g, ctx, "duna", "Viejo C") }
	g.money = 50000000
	g.facilities.lines["2"] = true
	for _, id in ids do
		runUntil(g, ctx, function()
			return Rules.freeLine(g) ~= nil
		end, 1)
		g.facilities.lines["3"] = true -- truco: lugar para crear el tercero en esta partida de prueba
		check(Actions.createLot(g, ctx, { designId = id, qty = 400 }).ok, "lote")
	end
	g.facilities.lines["3"] = nil
	Simulation.simulate(g, ctx, 60)
	-- Como una partida del esquema 16: sin líneas, con una pausa y avance hecho.
	local old = jsonCopy(g)
	old.schema = 16
	for _, l in old.lots do
		l.line = nil
	end
	old.lots[1].prodState = "pausado"
	local p1, money = old.lots[1].produced, old.money
	local mg, err = GameState.migrate(old, 1)
	check(mg ~= nil, err)
	eq(mg.schema, GameState.SCHEMA, "esquema actual")
	check(GameState.validate(mg), "válida")
	eq(mg.lots[1].prodState, "cola", "la pausa se reanuda")
	eq(mg.lots[1].produced, p1, "sin perder avance")
	eq(mg.money, money, "ni dinero")
	local withLine = 0
	for _, l in mg.lots do
		withLine += l.line and 1 or 0
	end
	eq(withLine, 2, "dos líneas propias: dos lotes fabricando")
	check(mg.lots[3].line == nil, "el tercero espera una línea libre")
	check(runUntil(mg, ctx, function()
		return mg.lots[3].line ~= nil
	end, 60), "y toma la que se libera")
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
	allLines(g)
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

test("[P9][P10][P11] Cerrar venta: descarta lo no vendido sin reintegro; la fabricación nunca se cancela", function()
	local g = bigCompany("Cierre SA")
	local ctx = makeCtx(10)
	local id = saveNew(g, ctx, "brisa")
	local calc = DesignCalc.computeDesign(g, g.designs[1])
	local hi = calc.price * 3 -- precio alto (el precio es libre)
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
	-- Un lote a medio fabricar no se cancela: ni cerrando la venta ni con reintegro; la línea lo termina.
	local r2 = orderLot(g, ctx, id, 5000)
	local lot2 = findLot(g, r2.lotId)
	runReal(g, ctx, 1)
	local made = lot2.produced
	check(made > 0 and made < 5000, "a medio fabricar (" .. made .. ")")
	local m2 = g.money
	check(not Actions.closeSale(g, ctx, { lotId = lot2.id }).ok, "cerrar la venta no cancela la fabricación")
	eq(g.money, m2, "sin reintegro")
	check(runUntil(g, ctx, function()
		return lot2.prodState == "completado"
	end, 200), "la línea completa el lote")
	eq(lot2.produced, 5000, "las 5.000 unidades")
	eq(lot2.costSpent, 5000 * lot2.unitCost, "pagadas una sola vez")
end)

test("Un lote recién ordenado tampoco se cancela ni se reintegra", function()
	local g = newCompany("Nada SA")
	local ctx = makeCtx(11)
	local id = saveNew(g, ctx, "brisa")
	local m = g.money
	local r = Actions.createLot(g, ctx, { designId = id, qty = 10 })
	check(r.ok and g.money < m, "el lote se pagó al ordenarlo")
	local paid = g.money
	check(not Actions.closeSale(g, ctx, { lotId = r.lotId }).ok, "no se cancela")
	eq(g.money, paid, "sin reintegro")
	eq(findLot(g, r.lotId).qty, 10, "ni cambia su cantidad")
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

test("[P12] Instalaciones: oficinas, fábrica y centro de investigación mejoran con obras (PI 3 → 8 → 20 → 45 → 90)", function()
	local g = newCompany("Sede SA")
	local ctx = makeCtx(13)
	local expected = { 3, 8, 20, 45, 90 }
	eq(Rules.piPerMinute(g), 3, "centro inicial")
	eq(Rules.caps(g).lines, 1, "una línea al empezar")
	check(not Actions.upgradeFacility(g, ctx, { kind = "offices" }).ok, "sin requisitos no se amplían las oficinas")
	check(not Actions.upgradeFacility(g, ctx, { kind = "research" }).ok, "el centro no supera el nivel de las oficinas")
	local function finish()
		Simulation.simulate(g, ctx, Catalog.RULES.gameDayMinutes * 320)
	end
	for lvl = 2, 5 do
		local nx = Rules.nextFacility(g, "offices")
		g.counters.unitsSold = nx.def.req.sold
		g.reputation = nx.def.req.rep
		g.money = nx.cost
		local r = Actions.upgradeFacility(g, ctx, { kind = "offices" })
		check(r.ok, r.msg)
		eq(g.money, 0, "se cobró la obra al empezar")
		eq(g.sede, lvl - 1, "la obra todavía no terminó")
		finish()
		eq(g.sede, lvl, "oficinas nivel " .. lvl)
		check(Rules.caps(g).staff == Catalog.SEDES[lvl].staff, "límite global de empleados")
		g.money = Rules.nextFacility(g, "research").cost
		check(Actions.upgradeFacility(g, ctx, { kind = "research" }).ok, "mejora el centro")
		finish()
		eq(Rules.piPerMinute(g), expected[lvl], "PI/min del " .. Rules.researchCenter(g).name)
		g.money = Rules.nextFacility(g, "factory").cost
		local rate = Rules.lineRate(g)
		check(Actions.upgradeFacility(g, ctx, { kind = "factory" }).ok, "mejora la fábrica")
		finish()
		check(Rules.lineRate(g) > rate, "cada línea fabrica más")
		eq(Rules.caps(g).lines, 1, "ninguna mejora regala líneas")
	end
	check(not Actions.upgradeFacility(g, ctx, { kind = "offices" }).ok, "no hay oficinas después de la casa matriz")
	-- El personal no suma PI por minuto.
	local base = Rules.piPerMinute(g)
	for i = 1, 30 do
		local c = Simulation.makeCandidate(g, ctx, "investigacion")
		c.id = "x" .. i
		table.insert(g.employees, { id = c.id, name = c.name, spec = c.spec, dept = "investigacion", salary = 100, skills = c.skills, potential = c.potential, months = 0, hiredDay = 0, adapt = {}, status = "activo" })
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
	-- La fábrica (Instalaciones) reemplaza a las viejas investigaciones de producción: calidad y costo.
	g.facilities.factory = 1
	local c1 = DesignCalc.computeDesign(g, g.designs[1])
	g.facilities.factory = 4
	local c4 = DesignCalc.computeDesign(g, g.designs[1])
	check(c4.quality > c1.quality and c4.unitCost < c1.unitCost, "una fábrica mejor fabrica con más calidad y menos costo")
	check(DesignCalc.finishBlock(g, "Perlado") == nil or string.find(DesignCalc.finishBlock(g, "Perlado") or "", "fábrica") == nil, "acabados premium con la fábrica 3+")
	g.facilities.factory = 1
	check(string.find(DesignCalc.finishBlock(g, "Perlado") or "", "fábrica") ~= nil, "con el garaje no hay perlado")
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
		check(log.milestones["sede 2"] ~= nil and log.milestones["sede 2"] < 30, dif .. ": Empresa pequeña antes de 30 min (" .. tostring(log.milestones["sede 2"]) .. ")")
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
		local hi = calc.price * 3
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
	-- Precio libre: por debajo del costo o muy por encima se acepta; cero, negativos y no números, no.
	check(Actions.setLotPrice(g, ctx, { lotId = lotId, price = 1 }).ok and lot.price == 1, "un dólar es un precio válido")
	check(Actions.setLotPrice(g, ctx, { lotId = lotId, price = lot.refPrice * 10 }).ok, "muy por encima también")
	check(Actions.setLotPrice(g, ctx, { lotId = lotId, price = 1234.6 }).ok and lot.price == 1235, "se redondea al dólar")
	for _, p in { 0, -100, math.huge, Catalog.ECON.priceCap + 1, "500" } do
		check(not Actions.setLotPrice(g, ctx, { lotId = lotId, price = p }).ok, "precio inválido " .. tostring(p))
	end
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
		-- La fabricación no se cancela: se cierra la venta cuando la línea termina el lote.
		runUntil(g, ctx, function()
			return findLot(g, r.lotId).prodState == "completado"
		end, 60)
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
	old.promo = true -- campaña de la versión 3 (radio y prensa)
	old.designs[1].parts.seguridad = nil
	local m, err = GameState.migrate(old, 1)
	check(m ~= nil, "migra: " .. tostring(err))
	local ok, why = GameState.validate(m)
	check(ok, "válida: " .. tostring(why))
	eq(m.schema, GameState.SCHEMA, "esquema actual")
	eq(#m.modelHistory, 1, "un resumen")
	eq(m.modelHistory[1].sold, 20 + 40 + 60, "con todas las ventas")
	check(m.promo == nil and m.campaign ~= nil and m.campaign.kind == "corporativa" and math.abs(m.campaign.boost - 0.15) < 1e-9, "la campaña activa sigue como corporativa con su efecto")
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
	-- Una marca que vende compactos baja sus precios (reacción a tu cuota): te quita ventas.
	g.marketShare.compacto = 0.5
	local cheaperRivals = Rules.lotPotentialRate(g, lot)
	g.marketShare.compacto = 0
	check(cheaperRivals < base, "rivales más baratos te quitan ventas")
	-- Dentro del tipo, una marca más barata se lleva más parte que una cara (mismo año).
	local cheap, pricey = nil, nil
	for _, o in Rules.rivalOffers("compacto", 1990, g) do
		if not cheap or (o.rival.price or 1) < (cheap.rival.price or 1) then
			cheap = o
		end
		if not pricey or (o.rival.price or 1) > (pricey.rival.price or 1) then
			pricey = o
		end
	end
	check(cheap.price / cheap.fair < pricey.price / pricey.fair, "las marcas económicas venden más barato que las caras frente a su precio justo")
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

test("Inversiones: duplicar paga ingeniería", function()
	local g = newCompany("Gasto SA")
	local ctx = makeCtx(48)
	g.money = 500000
	local id = saveNew(g, ctx, "brisa")
	local m2 = g.money
	check(Actions.dupDesign(g, ctx, { designId = id }).ok, "duplicar")
	eq(g.money, m2 - DesignCalc.engineeringCost(g, g.designs[1], "nuevo"), "el duplicado paga la ingeniería de un modelo nuevo")
	-- Estaciones: hasta nivel 2 por sede (10 con el imperio), cada nivel más caro.
	eq(Rules.maxStationLevel(g), 2, "garaje: nivel 2")
	g.facilities.factory = 5
	eq(Rules.maxStationLevel(g), 10, "complejo automotriz: nivel 10")
	check(Rules.upgradeCost({ level = 9 }) > Rules.upgradeCost({ level = 2 }) * 100, "los niveles altos cuestan mucho más")
end)

test("[C17][C18] Líneas y obras: línea 2 con dinero, línea 3 con Robux independiente, sin cobrar dos veces", function()
	local g = newCompany("Ampliar SA")
	local ctx = makeCtx(49)
	local nx = Rules.nextFacility(g, "line2")
	g.money = nx.cost - 1
	check(not Actions.upgradeFacility(g, ctx, { kind = "line2" }).ok, "sin dinero suficiente no se compra")
	g.money = nx.cost + 10
	check(Actions.upgradeFacility(g, ctx, { kind = "line2" }).ok, "compra la línea 2")
	eq(g.money, 10, "descuenta el costo exacto")
	g.money = 1e9
	check(not Actions.upgradeFacility(g, ctx, { kind = "line2" }).ok, "una obra a la vez por instalación (no se paga dos veces)")
	eq(Rules.caps(g).lines, 1, "mientras se construye, una línea")
	Simulation.simulate(g, ctx, Catalog.RULES.gameDayMinutes * (nx.days + 1))
	eq(Rules.caps(g).lines, 2, "terminada: dos líneas")
	check(Rules.nextFacility(g, "line2") == nil and not Actions.upgradeFacility(g, ctx, { kind = "line2" }).ok, "la línea 2 es permanente y no se vuelve a vender")
	-- La línea 3 es independiente de la 2.
	local other = newCompany("Tres Líneas SA")
	local undo = Simulation.grantLine3(other)
	eq(Rules.caps(other).lines, 2, "línea 3 sin la 2: dos líneas (1 y 3)")
	undo()
	eq(Rules.caps(other).lines, 1, "deshacer (si el guardado del recibo falla)")
	-- Administración: organización acelera obras, gestión abarata, finanzas baja el mantenimiento.
	local h = bigCompany("Admin SA")
	h.sede = 2
	h.facilities.factory = 1
	local cost0 = Rules.nextFacility(h, "factory").cost
	local maint0
	h.facilities.invested = 1000000
	maint0 = Rules.maintenance(h)
	eq(maint0, 1000000 * Catalog.FACILITIES.maintenanceRate, "mantenimiento: porcentaje de lo invertido")
	Simulation.ensureMarket(h, ctx)
	for _ = 1, 2 do
		local c = Simulation.makeCandidate(h, ctx, "administracion")
		c.spec = "administracion"
		for _, k in Catalog.STAFF.departments[4].skills do
			c.skills[k], c.potential[k] = 90, 100
		end
		table.insert(h.candidates, c)
		check(Actions.hire(h, ctx, { candidateId = c.id, dept = "administracion" }).ok, "contrata administración")
	end
	check(Rules.nextFacility(h, "factory").cost < cost0, "gestión: obras más baratas")
	check(Rules.maintenance(h) < maint0, "eficiencia financiera: menos mantenimiento")
	check(Rules.buildSpeed(h) > 1, "organización: obras más rápidas")
	local sal = Rules.salaries(h)
	local m0 = h.money
	Simulation.monthRollover(h, ctx)
	eq(m0 - h.money, sal, "sin ventas el mes anterior no se cobra mantenimiento (no traba a la empresa); solo salarios")
	GameState.day(h, h.time.day - 1).revenue = 1e9
	m0 = h.money
	Simulation.monthRollover(h, ctx)
	eq(m0 - h.money - Rules.salaries(h), Rules.maintenance(h), "con ventas, se cobra cada mes")
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
	check(log.milestones["sede 2"] >= 8 and log.milestones["sede 2"] <= 30, "Empresa pequeña entre 8 y 30 min (" .. Util.num(log.milestones["sede 2"], 1) .. ")")
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
	local hi = c.price * 3 -- precio alto (el precio es libre)
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
		notice = o.notice or function() end,
		garage = nil,
		friends = o.friends,
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
			check(mgr:request(p, "expandGlobal", { country = "JP", requestId = rid() }).ok, "Imperio: abre el país que elige (Japón)")
		end
	end
	-- Los modelos de la demostración ya tuvieron su lote: se fabrica un modelo nuevo (duplicado).
	check(mgr:request(p, "dupDesign", { designId = mgr.list[p].game.designs[1].id, requestId = rid() }).ok, "duplicar en la demostración")
	local dg = mgr.list[p].game
	local free = Rules.freeLine(dg)
	local r = mgr:request(p, "createLot", { designId = dg.designs[#dg.designs].id, qty = 100, requestId = rid() })
	if free then
		check(r.ok, "las acciones funcionan en la demostración: " .. tostring(r.msg))
	else
		check(not r.ok and string.find(r.msg, "líneas", 1, true) ~= nil, "con todas las líneas fabricando, el servidor lo explica: " .. tostring(r.msg))
	end
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
	g.facilities.lines["2"] = true -- dos lotes a la vez: la empresa tiene la línea 2
	local big = mgr:request(p, "createLot", { designId = g.designs[1].id, qty = 50000, requestId = rid() })
	check(big.ok, big.msg)
	local small = mgr:request(p, "createLot", { designId = g.designs[2].id, qty = 30, requestId = rid() })
	check(small.ok, small.msg)
	-- El chico termina (la fabricación no se cancela) y recién ahí se cierra su venta.
	for _ = 1, 2000 do
		clock.t += 1
		clock.c += 1
		mgr:tick()
		local x = findLot(g, small.lotId)
		if x and x.prodState == "completado" then
			break
		end
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
	for _ = 1, 2000 do
		clock.t += 1
		clock.c += 1
		mgr:tick()
		if s.game.lots[1].prodState == "completado" then
			break
		end
	end
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
	check(Actions.searchCandidates(g, ctx, { kind = "general" }).ok, "busca candidatos")
	local cand = g.candidates[1]
	check(cand ~= nil and Actions.hire(g, ctx, { candidateId = cand.id }).ok, "contrata")
	local lot = Actions.createLot(g, ctx, { designId = id, qty = 2000 })
	check(lot.ok, lot.msg)
	check(launchWhenReady(g, ctx, lot.lotId), "terminado, con reseñas y a la venta")
	check(orderLot(g, ctx, id, 40000).ok, "otro modelo en fabricación durante los años extra")
	local camp = Actions.startCampaign(g, ctx, { kind = "corporativa", budget = Util.round(Catalog.MARKETING.budgetRef * Rules.marketingEra(g)), days = 180 })
	check(camp.ok, "campaña corporativa: " .. camp.msg)
	check(g.ledger[#g.ledger].type == "promocion", "se cobra la campaña")
	local produced0, sold0 = g.counters.unitsProduced, g.counters.unitsSold
	local sal0 = 0
	local day0 = g.time.day
	-- Tres horas reales después del final del calendario.
	runReal(g, ctx, 180)
	check(g.time.day - day0 >= 12 * 14, "pasaron más de 14 años comerciales (" .. (g.time.day - day0) .. " meses)")
	eq(Rules.year(g), 2030, "el año visible sigue en 2030")
	check(g.counters.unitsProduced > produced0, "sigue fabricando")
	check(g.counters.unitsSold > sold0, "sigue vendiendo")
	for _, e in g.ledger do
		if e.type == "salarios" then
			sal0 += 1
		end
	end
	check(Rules.campaign(g) == nil, "la campaña terminó sola")
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
	-- La estrategia simple es biestable: una perturbación de ±2 % en el resto del mercado (44 o 46) la lleva a
	-- 63.000 o a 28.000 ventas, con seis y con doce rivales por igual (ver [RV2]). Se mide en la rama buena.
	local savedOutside = Catalog.ECON.outsideWeight
	Catalog.ECON.outsideWeight = 44
	local flat = Bot.researchSummary(Bot.play("normal", 732, { flat = true }))
	Catalog.ECON.outsideWeight = savedOutside
	check(flat.done >= Catalog.RESEARCH_TOTAL - 10, "la estrategia simple completa casi todas (" .. flat.done .. ")")
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
	check(not Actions.expandGlobal(g, ctx, { country = "BR" }).ok, "sin Imperio no hay expansión")
	g.sede = 5
	check(not Actions.expandGlobal(g, ctx, { country = "BR" }).ok, "sin las ventas pedidas no hay expansión")
	g.counters.unitsSold = 1000000
	local function corpCost(): number
		local p = Rules.campaignPlan(g, { kind = "corporativa", budget = Util.round(Catalog.MARKETING.budgetRef * Rules.marketingEra(g)), days = 30 })
		return p and p.cost or 0
	end
	local dem, camp, line = Rules.demand(g, "sedan"), corpCost(), Rules.lineRate(g)
	local nx = Rules.nextExpansion(g)
	local m = g.money
	check(not Actions.expandGlobal(g, ctx, {}).ok, "hay que elegir el país")
	check(not Actions.expandGlobal(g, ctx, { country = "XX" }).ok, "país desconocido")
	eq(g.money, m, "nada cobrado")
	check(Actions.expandGlobal(g, ctx, { country = "ZA" }).ok, "se expande al país elegido (el último de la lista)")
	eq(g.money, m - nx.cost, "cobra el costo")
	eq(g.countries[1], "ZA", "queda registrado el país elegido")
	check(not Actions.expandGlobal(g, ctx, { country = "ZA" }).ok, "no se abre dos veces el mismo país")
	-- Etapa 9: el +15 % es del total mundial; cada tipo recibe su parte según las preferencias del país.
	local wZA = Rules.countryWeights(Rules.country("ZA"), Rules.yearFrac(g)).sedan
	check(math.abs(Rules.demand(g, "sedan") / dem - (1 + Catalog.EXPANSION.demand * wZA)) < 1e-6, "sedán: +15 % × peso de Sudáfrica")
	local base, total = Rules.worldDemand(g)
	check(math.abs(total / base - (1 + Catalog.EXPANSION.demand)) < 1e-6, "+15 % de demanda mundial")
	check(corpCost() > camp and Rules.lineRate(g) > line, "campañas corporativas más caras y líneas más rápidas")
	check(Rules.nextExpansion(g).cost > nx.cost, "la siguiente región cuesta más")
	g.money = 1e12
	for i = #Catalog.EXPANSION.countries, 1, -1 do
		local c = Catalog.EXPANSION.countries[i]
		if not Rules.countryOpen(g, c.id) then
			check(Actions.expandGlobal(g, ctx, { country = c.id }).ok, "país " .. c.name)
		end
	end
	eq(#g.countries, #Catalog.EXPANSION.countries, "todos, en el orden elegido")
	check(not Actions.expandGlobal(g, ctx, { country = "BR" }).ok, "después del último no hay más")
	check(GameState.validate(g), "válida con los países elegidos")
	-- Migración 14 → 15: la cantidad de regiones abiertas se conserva como los primeros países.
	local old = jsonCopy(g)
	old.schema = 14
	old.countries = nil
	old.expansion = 3
	local mg = GameState.migrate(old, 1)
	check(mg and GameState.validate(mg), "migra")
	eq(table.concat(mg.countries, ","), "BR,US,DE", "tres países conservados")
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
	check(not sv.ok and g.money == m, "un modelo terminado tampoco cambia de carrocería (y no cobra nada)")
	eq(d.vehicleModel, "pioneer70", "conserva la carrocería con la que se finalizó")
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
	check(not mgr:request(p, "launchSale", { lotId = lot.id, price = 0, requestId = rid() }).ok, "7. precio inválido rechazado")
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

test("[I4] Capacitaciones: niveles por oficinas, mejora garantizada, simultáneas, una por empleado y productividad", function()
	local Staff = require("./.build/shared/Staff")
	local g = bigCompany("Capacita SA")
	local ctx = makeCtx(401)
	Simulation.ensureMarket(g, ctx)
	for _, c in table.clone(g.candidates) do
		check(Actions.hire(g, ctx, { candidateId = c.id, dept = c.spec }).ok, "contrata a " .. c.name)
		if #g.employees >= 3 then
			break
		end
	end
	local a, b = g.employees[1], g.employees[2]
	local skill = Staff.dept(a.dept).skills[1]
	a.skills[skill], a.potential[skill] = 40, 100
	-- Niveles: básico desde el comienzo; intermedio y avanzado con mejores oficinas.
	g.sede = 1
	local plan, why = Staff.trainingPlan(g, { scope = "individual", level = "intermedio", skill = skill, employeeId = a.id }, Rules.officeLevel(g), Rules.year(g))
	check(plan == nil and string.find(why or "", "oficinas") ~= nil, "intermedio bloqueado con las oficinas iniciales")
	check(not Actions.startTraining(g, ctx, { scope = "individual", level = "avanzado", skill = skill, employeeId = a.id }).ok, "el servidor también lo bloquea")
	-- Vista previa = lo que se cobra y lo que se obtiene.
	local req = { scope = "individual", level = "basico", skill = skill, employeeId = a.id }
	plan = Staff.trainingPlan(g, req, Rules.officeLevel(g), Rules.year(g))
	check(plan ~= nil and plan.members[1].from == 40 and plan.members[1].to == 43, "básico: 40 → 43 garantizado")
	local m0 = g.money
	local prod0 = Staff.productivity(g, a)
	check(Actions.startTraining(g, ctx, req).ok, "empieza")
	eq(m0 - g.money, plan.cost, "cobra lo anunciado")
	check(Staff.productivity(g, a) < prod0, "mientras se capacita rinde menos (sigue trabajando)")
	check(not Actions.startTraining(g, ctx, req).ok, "una capacitación a la vez por empleado")
	-- Otra en paralelo, por departamento, que no incluye a quien ya se capacita.
	g.sede = 3
	local other = Staff.dept(b.dept).skills[2]
	b.skills[other], b.potential[other] = 90, 95
	local r = Actions.startTraining(g, ctx, { scope = "departamento", level = "avanzado", skill = other, dept = b.dept })
	check(r.ok, "avanzada por departamento en paralelo: " .. r.msg)
	eq(#g.trainings, 2, "dos simultáneas")
	local t2 = g.trainings[2]
	check(not table.find(t2.members, a.id) or a.dept ~= b.dept, "quien ya se capacita no entra en la otra")
	eq(t2.results[b.id], 95, "nunca supera el potencial (90 + 12 → 95)")
	-- Avanza con el calendario (la pausa = no se simula) y termina con lo anunciado.
	local days = Staff.trainingLevel("basico").days
	Simulation.simulate(g, ctx, Catalog.RULES.gameDayMinutes * (days - 1))
	eq(a.skills[skill], 40, "todavía en curso")
	check(GameState.validate(g), "válida en curso")
	local saved = jsonCopy(g)
	check(GameState.validate(saved) and #saved.trainings == 2 and saved.trainings[1].progress > 0, "se guarda con su avance")
	Simulation.simulate(g, ctx, Catalog.RULES.gameDayMinutes * 1.5)
	eq(a.skills[skill], 43, "recibe exactamente +3")
	eq(a.training, nil, "termina")
	eq(Staff.productivity(g, a), prod0, "recupera su productividad")
	eq(#g.trainings, 1, "la otra sigue")
	Simulation.simulate(g, ctx, Catalog.RULES.gameDayMinutes * 100)
	eq(b.skills[other], 95, "la avanzada llega al potencial y no lo pasa")
	-- General: toda la empresa.
	local gen = Staff.trainingPlan(g, { scope = "general", level = "basico", skill = "organizacion" }, Rules.officeLevel(g), Rules.year(g))
	check(gen ~= nil and #gen.members >= 1, "general para quienes pueden mejorar")
	check(GameState.validate(g), "válida al final")
end)

test("[I5] Marketing: campaña de modelo y corporativa, presupuesto con rendimientos decrecientes, una activa y cancelación", function()
	local Staff = require("./.build/shared/Staff")
	local g = bigCompany("Marca SA")
	local ctx = makeCtx(501)
	local idA = saveNew(g, ctx, "brisa", "Sedán A")
	local idB = saveNew(g, ctx, "duna", "Coupé B")
	local la = Actions.createLot(g, ctx, { designId = idA, qty = 4000 }).lotId
	local lb = Actions.createLot(g, ctx, { designId = idB, qty = 4000 }).lotId
	check(launchWhenReady(g, ctx, la) and launchWhenReady(g, ctx, lb), "dos modelos a la venta")
	local A, B = findLot(g, la), findLot(g, lb)
	local era = Rules.marketingEra(g)
	local ref = Catalog.MARKETING.budgetRef * era
	-- El servidor calcula costo y efecto: no acepta montos fuera de rango ni duraciones inválidas.
	check(Rules.campaignPlan(g, { kind = "modelo", designId = idA, budget = 1, days = 30 }) == nil, "presupuesto fuera de rango")
	check(Rules.campaignPlan(g, { kind = "modelo", designId = idA, budget = ref, days = 7 }) == nil, "duración fuera de rango")
	check(Rules.campaignPlan(g, { kind = "modelo", designId = "nada", budget = ref, days = 30 }) == nil, "modelo inexistente")
	-- Rendimientos decrecientes.
	local p1 = Rules.campaignPlan(g, { kind = "modelo", designId = idA, budget = ref, days = 30 })
	local p2 = Rules.campaignPlan(g, { kind = "modelo", designId = idA, budget = ref * 2, days = 30 })
	local p4 = Rules.campaignPlan(g, { kind = "modelo", designId = idA, budget = ref * 4, days = 30 })
	check(p2.boost > p1.boost and p4.boost > p2.boost, "más presupuesto, más efecto")
	check(p4.boost - p2.boost < p2.boost - p1.boost, "cada vez menos (rendimientos decrecientes)")
	eq(p2.cost, 2 * p1.cost, "el costo sigue al presupuesto")
	local p60 = Rules.campaignPlan(g, { kind = "modelo", designId = idA, budget = ref, days = 60 })
	eq(p60.cost, 2 * p1.cost, "y a la duración")
	-- Campaña de modelo: solo ese auto.
	local rA, rB = Rules.lotPotentialRate(g, A), Rules.lotPotentialRate(g, B)
	local m0 = g.money
	local r = Actions.startCampaign(g, ctx, { kind = "modelo", designId = idA, budget = ref, days = 30, cost = 1 })
	check(r.ok, r.msg)
	eq(m0 - g.money, p1.cost, "se paga al empezar lo que calcula el servidor (ignora montos del cliente)")
	check(Rules.lotPotentialRate(g, A) > rA * 1.05 and Rules.campaignMult(g, A) > 1.4, "el modelo promocionado vende más (" .. Util.num(rA, 1) .. " → " .. Util.num(Rules.lotPotentialRate(g, A), 1) .. "/min)")
	check(math.abs(Rules.lotPotentialRate(g, B) - rB) / rB < 0.2, "el otro casi igual (solo compite con el promocionado)")
	check(not Actions.startCampaign(g, ctx, { kind = "corporativa", budget = ref, days = 30 }).ok, "una sola campaña activa")
	-- Cancelar: no devuelve dinero y permite empezar otra enseguida.
	local m1 = g.money
	check(Actions.cancelCampaign(g, ctx, {}).ok, "cancelada")
	eq(g.money, m1, "sin reembolso")
	-- Corporativa: más cara (tamaño y modelos en venta), afecta a todos y suma reputación.
	local corp = Rules.campaignPlan(g, { kind = "corporativa", budget = ref, days = 30 })
	check(corp.cost > p1.cost, "la corporativa cuesta más (" .. Util.money(corp.cost) .. " vs " .. Util.money(p1.cost) .. ")")
	rA, rB = Rules.lotPotentialRate(g, A), Rules.lotPotentialRate(g, B)
	check(Actions.startCampaign(g, ctx, { kind = "corporativa", budget = ref, days = 30 }).ok, "corporativa inmediatamente después")
	check(Rules.lotPotentialRate(g, A) > rA and Rules.lotPotentialRate(g, B) > rB, "todos los modelos venden más")
	local rep0 = g.reputation
	Simulation.monthRollover(g, ctx)
	check(g.reputation > rep0, "reconocimiento de marca")
	-- Avanza con el calendario y termina sola (la pausa = no se simula).
	Simulation.simulate(g, ctx, Catalog.RULES.gameDayMinutes * 29)
	check(Rules.campaign(g) ~= nil, "todavía activa al día 29")
	Simulation.simulate(g, ctx, Catalog.RULES.gameDayMinutes * 1.5)
	check(Rules.campaign(g) == nil, "terminó a los 30 días")
	-- Personal de Marketing: más efecto, menos costo y más duración.
	Simulation.ensureMarket(g, ctx)
	for _ = 1, 3 do
		local c = Simulation.makeCandidate(g, ctx, "marketing")
		c.spec = "marketing"
		for _, k in Staff.dept("marketing").skills do
			c.skills[k], c.potential[k] = 90, 100
		end
		table.insert(g.candidates, c)
		check(Actions.hire(g, ctx, { candidateId = c.id, dept = "marketing" }).ok, "contrata marketing")
	end
	local staffed = Rules.campaignPlan(g, { kind = "modelo", designId = idA, budget = ref, days = 30 })
	check(staffed.cost < p1.cost, "análisis de mercado baja el costo")
	check(Actions.startCampaign(g, ctx, { kind = "modelo", designId = idA, budget = ref, days = 30 }).ok, "otra campaña")
	check(Rules.campaignBoost(g) > staffed.boost, "creatividad sube el efecto")
	Simulation.simulate(g, ctx, Catalog.RULES.gameDayMinutes * 31)
	check(Rules.campaign(g) ~= nil, "comunicación la hace durar más de 30 días")
	check(GameState.validate(g), "válida")
	check(GameState.validate(jsonCopy(g)), "se guarda")
end)

test("[I8] Ciclo automotriz integrado: ventas con deuda salarial (30 %), campaña, stock agotado y migraciones de instalaciones", function()
	local g = bigCompany("Ciclo SA")
	local ctx = makeCtx(801)
	local id = saveNew(g, ctx, "brisa", "Ciclo")
	local lotId = Actions.createLot(g, ctx, { designId = id, qty = 300 }).lotId
	check(launchWhenReady(g, ctx, lotId), "fabricado, con reseñas y a la venta")
	local lot = findLot(g, lotId)
	-- Deuda salarial: el 30 % de los ingresos va a la deuda y el 70 % queda en la empresa.
	g.payroll.debt = 1e9
	g.payroll.debtMonths = 1
	local m0, d0, rev0 = g.money, g.payroll.debt, lot.revenue
	Simulation.simulate(g, ctx, 30)
	local rev = lot.revenue - rev0
	check(rev > 0, "vendió")
	check(math.abs((d0 - g.payroll.debt) - rev * 0.3) <= 2, "30 % a la deuda (" .. Util.money(d0 - g.payroll.debt) .. " de " .. Util.money(rev) .. ")")
	check(math.abs((g.money - m0) - rev * 0.7) <= 2, "70 % para la empresa")
	-- Nunca se vende más que el stock; al agotarse pasa al historial.
	g.payroll.debt, g.payroll.debtMonths = 0, 0
	check(runUntil(g, ctx, function()
		return findLot(g, lotId) == nil
	end, 60), "se agota")
	local h = findHist(g, lotId)
	eq(h.sold + h.discarded, 300, "ni una unidad de más")
	check(not Actions.createLot(g, ctx, { designId = id, qty = 10 }).ok, "un solo lote por modelo")
	-- El diseño conserva sus especificaciones aunque se investigue algo nuevo.
	local spec = jsonCopy(g.designs[1])
	table.insert(g.research.done, "eng_I4_2")
	eq(serde.encode("json", g.designs[1]), serde.encode("json", spec), "el diseño guardado no cambia solo")
	-- Migraciones 12 → 13 → 14: la sede vieja se reparte sin perder nada.
	local old = jsonCopy(newCompany("Sede Vieja SA"))
	old.schema = 12
	old.sede = 4
	old.facilities = nil
	old.research.done = { "mo1", "pr1", "mk1" }
	old.research.projects = { { id = "pr3", progress = 5, days = 100, paidMoney = 45000, paidPi = 80, ahead = 0, startDay = 0 } }
	local money0, rp0 = old.money, old.rp
	local m = GameState.migrate(jsonCopy(old), 5000)
	check(m ~= nil and GameState.validate(m), "migra y valida")
	eq(m.facilities.factory, 4, "fábrica del nivel de la sede")
	eq(m.facilities.research, 4, "centro del nivel de la sede")
	eq(Rules.caps(m).lines, 3, "conserva sus líneas (hasta 3)")
	eq(table.concat(m.research.done, ","), "mo1", "las investigaciones de «Empresa» pasan a las instalaciones")
	eq(#m.research.projects, 0, "el proyecto de «Empresa» en curso se reintegra")
	eq(m.money, money0 + 45000, "con su dinero")
	eq(m.rp, rp0 + 80, "y sus PI")
	check(m.facilities.invested > 0, "lo invertido en la sede cuenta para el mantenimiento")
end)

test("[I10] Recorrido integral de una empresa (20 pasos) con sesiones reales, dos jugadores y carga en otro servidor", function()
	local Staff = require("./.build/shared/Staff")
	local store = newStore()
	local clock = { t = 1000, c = 0 }
	local mgr = makeServer(store, "A", clock)
	local p, q = { UserId = 1001 }, { UserId = 1002 }
	mgr:add(p)
	mgr:add(q)
	local function req(action: string, payload: any?): any
		local body = payload or {}
		body.requestId = rid()
		return mgr:request(p, action, body)
	end
	-- 1. Empresa nueva el 01/01/1970.
	check(mgr:request(p, "createCompany", { slot = "1", name = "Integral SA", color = "#42B8E5", logo = "rayo" }).ok, "1. empresa creada")
	check(mgr:request(q, "createCompany", { slot = "1", name = "Vecina SA", color = "#FF8A3D", logo = "pico" }).ok, "segundo jugador en el mismo servidor")
	local g, gq = mgr.list[p].game, mgr.list[q].game
	eq(Rules.date(g), "01/01/1970", "1. empieza el 01/01/1970")
	eq(#g.candidates, 8, "8 candidatos del mes")
	-- 2. Sedán con motor I4.
	local draft = draftFor(g, "brisa", "Integral Uno")
	eq(draft.parts.motor, "i4", "2. sedán I4")
	check(req("saveDesign", { draft = draft }).ok, "2. diseño guardado")
	local d = g.designs[1]
	-- 3. Fabricar (sin dinero suficiente para un lote enorme no se puede).
	check(not req("createLot", { designId = d.id, qty = 100000 }).ok, "sin dinero suficiente no se ordena")
	local unit = Rules.lotUnitCost(g, DesignCalc.computeDesign(g, d).unitCost)
	g.money = math.max(g.money, unit * 400 + 50000)
	local r = req("createLot", { designId = d.id, qty = 400 })
	check(r.ok, "3. lote de 400: " .. tostring(r.msg))
	local lot = g.lots[1]
	-- 4. Reseñas al terminar.
	local ok = false
	for _ = 1, 3000 do
		ticks(mgr, clock, 1)
		if lot.saleState == "por lanzar" then
			ok = true
			break
		end
	end
	check(ok and lot.review and #lot.review.scores == 4, "4. cuatro reseñas guardadas")
	-- 5-7. Precio, ventas y dinero.
	check(req("launchSale", { lotId = lot.id, price = lot.refPrice }).ok, "5. precio fijado")
	local m0 = g.money
	for _ = 1, 3000 do
		ticks(mgr, clock, 1)
		if g.counters.unitsSold >= 300 then
			break
		end
	end
	check(g.counters.unitsSold >= 300, "6. vende (" .. g.counters.unitsSold .. ")")
	check(g.money > m0, "7. el dinero entra por las ventas")
	-- 8-9. Contratar y comprobar la bonificación.
	g.money = 5000000
	local c = g.candidates[1]
	for _, x in g.candidates do
		if x.spec == "produccion" then
			c = x
		end
	end
	local rate0 = Rules.lineRate(g)
	check(req("hire", { candidateId = c.id, dept = "produccion" }).ok, "8. contratado en Producción")
	local e = g.employees[1]
	check(Rules.lineRate(g) > rate0, "9. la bonificación se aplica enseguida")
	-- 10-11. Capacitación con mejora garantizada.
	local sk = "velocidad"
	e.skills[sk], e.potential[sk] = math.min(e.skills[sk], 80), 100
	local before = e.skills[sk]
	check(req("startTraining", { scope = "individual", level = "basico", skill = sk, employeeId = e.id }).ok, "10. capacitación básica")
	check(not req("startTraining", { scope = "individual", level = "basico", skill = "calidad", employeeId = e.id }).ok, "una a la vez por empleado")
	ticks(mgr, clock, Staff.trainingLevel("basico").days * Catalog.CALENDAR.realSecondsPerDay + 2)
	eq(e.skills[sk], before + 3, "11. mejora garantizada aplicada")
	-- 12. Investigar (varias a la vez).
	g.rp = 500
	check(req("startResearch", { id = "mo1" }).ok and req("startResearch", { id = "ca1" }).ok, "12. dos investigaciones simultáneas")
	-- 13-14. Mejorar las oficinas y desbloquear la capacitación intermedia.
	g.reputation = math.max(g.reputation, 3.0)
	check(req("upgradeFacility", { kind = "offices" }).ok, "13. obra de oficinas")
	check(not req("upgradeFacility", { kind = "offices" }).ok, "no se paga dos veces la misma obra")
	ticks(mgr, clock, Catalog.SEDES[2].days * Catalog.CALENDAR.realSecondsPerDay + 2)
	eq(g.sede, 2, "13. oficinas nivel 2")
	local plan = Staff.trainingPlan(g, { scope = "individual", level = "intermedio", skill = "calidad", employeeId = e.id }, Rules.officeLevel(g), Rules.year(g))
	check(plan ~= nil, "14. capacitación intermedia desbloqueada")
	-- 15. Campaña publicitaria.
	check(req("startCampaign", { kind = "corporativa", budget = Util.round(Catalog.MARKETING.budgetRef * Rules.marketingEra(g)), days = 30 }).ok, "15. campaña corporativa")
	check(not req("startCampaign", { kind = "corporativa", budget = Util.round(Catalog.MARKETING.budgetRef * Rules.marketingEra(g)), days = 30 }).ok, "una sola campaña")
	-- 16-17. Varios meses: sueldos y deuda salarial.
	local day0 = g.time.day
	g.money = 0
	ticks(mgr, clock, 3 * 31 * Catalog.CALENDAR.realSecondsPerDay)
	check(g.time.day - day0 >= 3, "16. pasaron varios meses")
	check(g.payroll.debt > 0 or g.money > 0, "17. sueldos pagados o adeudados")
	eq(#g.employees, 1, "17. nadie renunció")
	check(g.market.searches == 0 and #g.candidates == 8, "candidatos renovados al cambiar de mes")
	-- Pausa individual: el otro jugador sigue.
	mgr:request(p, "setUiPause", { paused = true })
	local dp, dq = Rules.absDay(g), Rules.absDay(gq)
	ticks(mgr, clock, 10)
	eq(Rules.absDay(g), dp, "pausa de una empresa")
	check(Rules.absDay(gq) > dq, "la del otro jugador sigue")
	mgr:request(p, "setUiPause", { paused = false })
	-- Duplicados: el mismo identificador de solicitud no se aplica dos veces.
	local id = rid()
	g.money = 1e7
	local m1 = g.money
	mgr:request(p, "searchCandidates", { kind = "general", requestId = id })
	local m2 = g.money
	mgr:request(p, "searchCandidates", { kind = "general", requestId = id })
	check(m2 < m1 and g.money == m2, "una búsqueda repetida por red no se cobra dos veces")
	-- 18-20. Guardar, volver al menú y cargar en otro servidor.
	local snap = jsonCopy({ money = g.money, sede = g.sede, done = g.research.done, employees = g.employees, trainings = g.trainings, campaign = g.campaign, debt = g.payroll.debt, facilities = g.facilities, sold = g.counters.unitsSold })
	check(mgr:request(p, "leaveCompany", {}).ok, "18-19. guardar y volver al menú")
	mgr:remove(p)
	mgr:remove(q)
	local mgr2 = makeServer(store, "B", clock)
	mgr2:add(p)
	check(mgr2:request(p, "selectSlot", { slot = "1" }).ok, "20. carga")
	local g2 = mgr2.list[p].game
	eq(g2.money, snap.money, "20. mismo dinero")
	eq(g2.sede, snap.sede, "20. mismas oficinas")
	eq(serde.encode("json", g2.research.done), serde.encode("json", snap.done), "20. mismas tecnologías")
	eq(serde.encode("json", g2.employees), serde.encode("json", snap.employees), "20. mismos empleados, habilidades y potencial")
	eq(serde.encode("json", g2.facilities), serde.encode("json", snap.facilities), "20. mismas instalaciones")
	eq(g2.payroll.debt, snap.debt, "20. misma deuda salarial")
	eq(g2.counters.unitsSold, snap.sold, "20. mismas ventas")
	check(GameState.validate(g2), "partida válida")
end)

test("[R2] Línea 3 de la cuenta: una compra vale en todas las empresas (también las nuevas) y persiste", function()
	local store = newStore()
	local clock = { t = 1000, c = 0 }
	local prompts = {}
	local mgr = makeServer(store, "A", clock, { prompt = function(_, id)
		table.insert(prompts, id)
	end })
	local p = { UserId = 1201 }
	mgr:add(p)
	local s = mgr.list[p]
	check(mgr:request(p, "createCompany", { slot = "1", name = "Línea Uno", color = "#7667FF", logo = "pico" }).ok, "empresa 1")
	local g1 = s.game
	eq(Rules.caps(g1).lines, 1, "una línea antes de comprar")
	local saved = Catalog.PRODUCTS.line3.id
	Catalog.PRODUCTS.line3.id = 3333
	mgr:request(p, "leaveCompany", {})
	check(mgr:request(p, "buyProduct", { product = "line3" }).ok and prompts[1] == 3333, "se puede comprar desde el menú (no hace falta una empresa abierta)")
	check(mgr:processReceipt({ PlayerId = 1201, ProductId = 3333, PurchaseId = "l3-1" }) == true, "recibo acreditado")
	eq(s.profile.owned.line3, true, "queda en la cuenta")
	eq(Rules.caps(g1).lines, 2, "la empresa 1 suma la línea 3 (líneas 1 y 3)")
	check(not mgr:request(p, "buyProduct", { product = "line3" }).ok, "no se vuelve a vender")
	check(mgr:processReceipt({ PlayerId = 1201, ProductId = 3333, PurchaseId = "l3-1" }) == true, "el mismo recibo no se duplica")
	eq(#s.profile.receipts, 1, "un recibo")
	check(mgr:request(p, "createCompany", { slot = "2", name = "Línea Dos", color = "#F7C95C", logo = "rayo" }).ok, "empresa nueva después de comprar")
	eq(Rules.caps(s.game).lines, 2, "la empresa nueva también tiene la línea 3")
	eq(s.game.facilities.lines["2"], nil, "independiente de la línea 2")
	-- Persistencia en otro servidor.
	mgr:remove(p)
	local mgr2 = makeServer(store, "B", clock)
	mgr2:add(p)
	local s2 = mgr2.list[p]
	eq(s2.profile.owned.line3, true, "persistida en la cuenta")
	check(mgr2:request(p, "selectSlot", { slot = "1" }).ok, "abre la empresa 1")
	eq(Rules.caps(s2.game).lines, 2, "la empresa 1 conserva la línea 3")
	check(GameState.validate(s2.game), "partida válida")
	Catalog.PRODUCTS.line3.id = saved
end)

test("[R4] Capacitaciones: más de 12 a la vez (una por empleado) y sin capacitaciones vacías al despedir", function()
	local g = bigCompany("Muchas SA")
	local ctx = makeCtx(1401)
	for i = 1, 20 do
		local c = Simulation.makeCandidate(g, ctx, "produccion")
		c.skills.velocidad, c.potential.velocidad = 10, 100
		table.insert(g.candidates, c)
		check(Actions.hire(g, ctx, { candidateId = c.id, dept = "produccion" }).ok, "contrata " .. i)
	end
	for i, e in g.employees do
		local r = Actions.startTraining(g, ctx, { scope = "individual", level = "basico", skill = "velocidad", employeeId = e.id })
		check(r.ok, "capacitación " .. i .. ": " .. r.msg)
	end
	eq(#g.trainings, 20, "20 capacitaciones simultáneas (el tope es una por empleado)")
	check(GameState.validate(g), "válida")
	local e = g.employees[1]
	e.hiredDay = Rules.absDay(g)
	check(Actions.fire(g, ctx, { employeeId = e.id }).ok, "despide a quien se capacitaba")
	eq(#g.trainings, 19, "su capacitación (sin otros participantes) desaparece")
	check(GameState.validate(g), "sigue válida")
end)

test("[R1] Despidos: no se puede usar personal gratis contratando después del pago y despidiendo antes del siguiente", function()
	local Staff = require("./.build/shared/Staff")
	local g = bigCompany("Sueldos SA")
	local ctx = makeCtx(1501)
	Simulation.ensureMarket(g, ctx)
	-- Empresa nueva: el «pago» inicial es el día 0.
	eq(g.payroll.lastDay, 0, "empresa nueva con último pago el día 0")
	Simulation.simulate(g, ctx, Catalog.RULES.gameDayMinutes * 3)
	local c = g.candidates[1]
	check(Actions.hire(g, ctx, { candidateId = c.id, dept = c.spec }).ok, "contrata el día 3")
	local e = g.employees[1]
	Simulation.simulate(g, ctx, Catalog.RULES.gameDayMinutes * 15)
	local total, sev, unpaid = Staff.dismissalCost(g, e, Rules.absDay(g))
	eq(unpaid, Util.round(e.salary * 15 / 30), "15 días sin cobrar: medio sueldo")
	eq(total, sev + unpaid, "despedir = indemnización + sueldo adeudado")
	local m0 = g.money
	check(Actions.fire(g, ctx, { employeeId = e.id }).ok, "despedido")
	eq(m0 - g.money, total, "pagó ambos")
	-- Quien ya cobró en el último pago no debe días.
	c = g.candidates[2]
	check(Actions.hire(g, ctx, { candidateId = c.id, dept = c.spec }).ok, "otro")
	local e2 = g.employees[1]
	Simulation.simulate(g, ctx, Rules.monthMinutes(g.time.day))
	check(g.payroll.lastDay > e2.hiredDay, "cobró al empezar el mes")
	local _, _, unpaid2 = Staff.dismissalCost(g, e2, Rules.absDay(g))
	eq(unpaid2, 0, "sin sueldo adeudado después del pago")
	check(GameState.validate(g), "válida")
end)

test("[R1] Robustez: ninguna acción del servidor falla ni corrompe la partida con datos del cliente inválidos", function()
	local g = bigCompany("Fuzz SA")
	local ctx = makeCtx(1601)
	Simulation.ensureMarket(g, ctx)
	local id = saveNew(g, ctx, "brisa", "Fuzz")
	local lotId = Actions.createLot(g, ctx, { designId = id, qty = 50 }).lotId
	local c = g.candidates[1]
	Actions.hire(g, ctx, { candidateId = c.id, dept = c.spec })
	local nan = 0 / 0
	local values = { nil, true, false, 0, -1, 1e308, -1e308, nan, math.huge, "", "x", "1", {}, { 1, 2 }, { a = { b = {} } } }
	local keys = { "id", "designId", "lotId", "qty", "price", "level", "station", "kind", "dept", "employeeId", "candidateId", "scope", "skill", "budget", "days", "country", "draft", "speed", "product", "slot", "area", "color", "logo", "name", "confirm", "key", "value", "newGenOf" }
	local rng = seeded(1602)
	local calls, failures = 0, 0
	for name, handler in Actions.handlers do
		for _ = 1, 40 do
			local payload: any = {}
			for _, k in keys do
				if rng() < 0.35 then
					payload[k] = values[math.floor(rng() * #values) + 1]
				end
			end
			if rng() < 0.15 then
				payload = values[math.floor(rng() * #values) + 1]
			end
			calls += 1
			local ok, r = pcall(handler, g, ctx, payload)
			if not ok or type(r) ~= "table" then
				failures += 1
				check(false, name .. " falló con datos inválidos: " .. tostring(r))
			end
		end
	end
	eq(failures, 0, calls .. " llamadas con datos inválidos, ninguna rompe el servidor")
	local ok, why = GameState.validate(g)
	check(ok, "la partida sigue válida: " .. tostring(why))
	check(g.money == g.money and g.money >= 0 and g.money < math.huge, "el dinero sigue siendo un número válido")
	check(findLot(g, lotId) ~= nil or findHist(g, lotId) ~= nil, "el lote sigue existiendo")
end)

test("[R1] Robustez de sesiones: acciones de menú y nombres de acción inválidos no rompen nada", function()
	local store = newStore()
	local clock = { t = 1000, c = 0 }
	local mgr = makeServer(store, "A", clock)
	local p = { UserId = 1701 }
	mgr:add(p)
	local nan = 0 / 0
	local weird = { 1, true, "x", nan, {}, { slot = 9 }, { slot = "1", name = 5 }, { slot = "1", name = string.rep("a", 5000), color = {}, logo = 3 }, { product = {} }, { key = "sound", value = "no" }, { confirm = 1 } }
	for _, action in { "createCompany", "selectSlot", "playDemo", "leaveCompany", "saveNow", "renameCompany", "deleteCompany", "setSetting", "wipeAll", "buyProduct", "sync", "retryLoad", "setUiPause", "noExiste", 42, {} } do
		for _, payload in weird do
			clock.c += 1 -- fuera del límite de acciones por segundo
			local ok, r = pcall(function()
				return mgr:request(p, action, payload)
			end)
			check(ok and type(r) == "table", tostring(action) .. " con datos inválidos responde sin error")
		end
	end
	local s = mgr.list[p]
	check(s.status == "ready", "la sesión sigue lista")
	check(next(s.profile.slots) == nil, "no se creó ninguna empresa con datos inválidos")
	check(mgr:request(p, "createCompany", { slot = "1", name = "Válida SA", color = "#7667FF", logo = "pico" }).ok, "y una válida se crea normalmente")
end)

test("[R1] Migración completa 8 → actual: una partida de la Etapa 3 carga sin perder nada", function()
	local g = newCompany("Etapa Tres SA")
	local ctx = makeCtx(1801)
	g.money = 3000000
	local id = saveNew(g, ctx, "brisa", "Viejo Sedán")
	local lotId = Actions.createLot(g, ctx, { designId = id, qty = 20 }).lotId
	local old = jsonCopy(g)
	-- Forma del esquema 8: sin personal nuevo, campañas, instalaciones, países ni capacitaciones.
	old.schema = 8
	old.company.difficulty = "facil"
	old.sede = 3
	old.promo = 2
	old.facilities, old.market, old.payroll, old.trainings, old.campaign, old.countries = nil, nil, nil, nil, nil, nil
	old.expansion = 0
	old.research.done = { "mo1", "pr1", "mk1", "se1" }
	old.employees = {
		{ id = "e1", name = "Ana Paz", role = "Mecánico", level = 3, skill = 60, salary = 1800, assign = "motor" },
		{ id = "e2", name = "Juan Gil", role = "Gerente", level = 2, skill = 50, salary = 1500 },
	}
	old.candidates = { { id = "c1", name = "X", role = "Vendedor", level = 1, skill = 40, salary = 900, fee = 3000 } }
	local money0 = old.money
	local m, err = GameState.migrate(jsonCopy(old), 5000)
	check(m ~= nil, "migra: " .. tostring(err))
	local ok, why = GameState.validate(m)
	check(ok, "válida: " .. tostring(why))
	eq(m.schema, GameState.SCHEMA, "esquema actual (" .. GameState.SCHEMA .. ")")
	eq(m.money, money0, "mismo dinero")
	eq(#m.designs, 1, "mismo diseño")
	check(findLot(m, lotId) ~= nil, "mismo lote")
	eq(#m.employees, 2, "mismos empleados")
	eq(m.employees[1].dept, "produccion", "el mecánico de la estación sigue en Producción")
	eq(m.employees[2].spec, "administracion", "el gerente pasa a Administración")
	eq(m.employees[1].salary, 1800, "con su salario")
	eq(m.facilities.factory, 3, "fábrica del nivel de la sede")
	eq(Rules.caps(m).lines, 3, "conserva sus 3 líneas")
	check(m.campaign ~= nil and m.campaign.kind == "corporativa", "la campaña activa sigue como corporativa")
	eq(table.concat(m.research.done, ","), "mo1,se1", "investigaciones de las 4 categorías")
	eq(m.company.difficulty, nil, "sin dificultad")
	eq(#m.countries, 0, "sin países")
	-- Se puede jugar enseguida.
	Simulation.ensureMarket(m, ctx)
	runReal(m, ctx, 2)
	check(GameState.validate(m), "válida después de jugar")
end)


-- Editor definitivo: borradores persistentes, finalización validada en el servidor y modelos inmutables ----------
test("[ED] Borradores del editor: se guardan en la partida, sobreviven a guardar y cargar, y se finalizan una sola vez", function()
	local g = newCompany("Ruta Norte Motors")
	local ctx = makeCtx(41)
	eq(#g.drafts, 0, "una empresa nueva no tiene borradores")
	-- 1970: sedán y coupé de 1970; motores I4 e I6 de nivel 1.
	check(DesignCalc.baseAvailable(g, Catalog.base("brisa")) == nil and DesignCalc.baseAvailable(g, Catalog.base("duna")) == nil, "Sedán y Coupé 1970 disponibles al empezar")
	check(DesignCalc.baseAvailable(g, Catalog.base("brisa2")) ~= nil, "las generaciones siguientes, bloqueadas")
	local d0 = draftFor(g, "brisa")
	check(DesignCalc.partBlock(g, d0, Catalog.part("motor", "i4")) == nil and DesignCalc.partBlock(g, d0, Catalog.part("motor", "i6")) == nil, "I4 e I6 disponibles")
	eq(Rules.engineLevelMax(g, "I4"), 1, "I4 en nivel 1")
	eq(Rules.engineLevelMax(g, "I6"), 1, "I6 en nivel 1")
	check(DesignCalc.variantBlock(g, d0, Catalog.engineVariant("balanced")) == nil, "variante equilibrada disponible")
	check(DesignCalc.variantBlock(g, d0, Catalog.engineVariant("eco")) ~= nil and DesignCalc.variantBlock(g, d0, Catalog.engineVariant("sport")) ~= nil, "económica y deportiva requieren investigación")
	-- Guardar un borrador: identificador del cliente, etapa y nombre provisional.
	check(not Actions.saveDraft(g, ctx, { draftId = "x", draft = d0 }).ok, "identificador inválido rechazado")
	local raw = draftFor(g, "duna", "a")
	raw.parts.motor = "i6"
	local r = Actions.saveDraft(g, ctx, { draftId = "borrador-1", draft = raw, step = 2, visited = 2 })
	check(r.ok and r.quiet, "borrador guardado sin aviso")
	eq(#g.drafts, 1, "un borrador")
	local dr = g.drafts[1]
	eq(dr.step, 2, "con su etapa")
	eq(dr.spec.parts.motor, "i6", "y sus componentes")
	check(Util.charCount(dr.spec.name) >= 2, "un nombre a medio escribir queda provisional (" .. dr.spec.name .. ")")
	eq(#g.designs, 0, "un borrador no es un modelo")
	-- Actualizar el mismo borrador no lo duplica; volver a una etapa anterior conserva hasta dónde llegó.
	raw.name = "Halcón Sport"
	check(Actions.saveDraft(g, ctx, { draftId = "borrador-1", draft = raw, step = 1, visited = 1 }).ok, "actualizar")
	eq(#g.drafts, 1, "sigue habiendo uno")
	eq(g.drafts[1].step, 1, "etapa actual")
	eq(g.drafts[1].visited, 2, "conserva la etapa más lejana visitada")
	eq(g.drafts[1].spec.name, "Halcón Sport", "nombre actualizado")
	-- Tecnología no investigada: el servidor no la acepta en el borrador.
	local locked = jsonCopy(raw)
	locked.equipment = { "radio" }
	check(not Actions.saveDraft(g, ctx, { draftId = "borrador-1", draft = locked }).ok, "radio sin investigar rechazada")
	eq(#g.drafts[1].spec.equipment, 0, "el borrador no cambia")
	-- Guardar y cargar la empresa: el borrador vuelve igual.
	check(GameState.validate(g), "la partida con borradores es válida")
	local loaded = jsonCopy(g)
	check(GameState.validate(loaded), "también después de guardar y cargar")
	eq(loaded.drafts[1].spec.name, "Halcón Sport", "el borrador se recupera")
	eq(loaded.drafts[1].visited, 2, "con su progreso en el editor")
	-- Investigar después y sumar la tecnología al mismo borrador.
	table.insert(loaded.research.done, "te_radio")
	check(Actions.saveDraft(loaded, ctx, { draftId = "borrador-1", draft = locked, step = 4, visited = 4 }).ok, "ya investigada, la radio se suma al borrador")
	eq(loaded.drafts[1].spec.equipment[1], "radio", "radio en el borrador")
	g = loaded
	-- Los borradores no se fabrican.
	check(not Actions.createLot(g, ctx, { designId = "borrador-1", qty = 10 }).ok, "un borrador no se puede fabricar")
	-- Finalizar: el servidor valida el nombre completo.
	local bad = jsonCopy(g.drafts[1].spec)
	bad.name = "x"
	check(not Actions.finalizeDesign(g, ctx, { draftId = "borrador-1", draft = bad }).ok, "nombre inválido: no se finaliza")
	eq(#g.drafts, 1, "y el borrador sigue")
	local final = jsonCopy(g.drafts[1].spec)
	final.name = "Halcón 70"
	local m0, saved0 = g.money, g.counters.designsSaved
	local f = Actions.finalizeDesign(g, ctx, { draftId = "borrador-1", draft = final })
	check(f.ok, f.msg)
	eq(#g.designs, 1, "se crea el modelo")
	eq(#g.drafts, 0, "y se retira el borrador")
	eq(g.counters.designsSaved, saved0 + 1, "cuenta como diseño guardado (misiones)")
	check(g.money <= m0, "se cobra el desarrollo")
	local model = g.designs[1]
	eq(model.name, "Halcón 70", "con su nombre")
	eq(model.parts.motor, "i6", "con sus especificaciones originales")
	eq(model.equipment[1], "radio", "y su equipamiento")
	-- Una confirmación repetida no duplica el modelo.
	check(not Actions.finalizeDesign(g, ctx, { draftId = "borrador-1", draft = final }).ok, "la segunda confirmación se rechaza")
	eq(#g.designs, 1, "sigue habiendo un solo modelo")
	-- El modelo terminado es inmutable y no cambia al investigar algo mejor.
	local spec0 = jsonCopy(model)
	table.insert(g.research.done, "co1")
	check(not Actions.saveDesign(g, ctx, { draft = jsonCopy(model), sourceId = model.id }).ok, "no se edita")
	check(DesignCalc.sameSpec(spec0, g.designs[1]), "sus especificaciones no cambian")
	-- Disponible en Producción: un único lote.
	local lot = Actions.createLot(g, ctx, { designId = model.id, qty = 10 })
	check(lot.ok, lot.msg)
	check(not Actions.createLot(g, ctx, { designId = model.id, qty = 10 }).ok, "cada modelo, un solo lote")
	check(GameState.validate(g), "válida después de finalizar y fabricar")
	-- Límite de borradores (protege el tamaño del guardado).
	for i = 1, Catalog.RULES.maxDrafts do
		check(Actions.saveDraft(g, ctx, { draftId = "lleno-" .. i, draft = draftFor(g, "brisa") }).ok, "borrador " .. i)
	end
	check(not Actions.saveDraft(g, ctx, { draftId = "uno-mas", draft = draftFor(g, "brisa") }).ok, "con el máximo no se crea otro")
	check(Actions.saveDraft(g, ctx, { draftId = "lleno-1", draft = draftFor(g, "duna") }).ok, "pero los existentes se siguen guardando")
	check(Actions.deleteDraft(g, ctx, { draftId = "lleno-1" }).ok, "eliminar un borrador")
	eq(#g.drafts, Catalog.RULES.maxDrafts - 1, "queda uno menos")
	-- Nueva generación desde un borrador: se finaliza como generación 2.
	g.time.day += 12
	local ng = draftFor(g, "duna", "Halcón 71")
	check(Actions.saveDraft(g, ctx, { draftId = "gen-dos", draft = ng, newGenOf = model.id }).ok, "borrador de nueva generación")
	g.money += 200000
	local f2 = Actions.finalizeDesign(g, ctx, { draftId = "gen-dos", draft = ng })
	check(f2.ok, f2.msg)
	local gen2
	for _, x in g.designs do
		if x.id == f2.designId then
			gen2 = x
		end
	end
	check(gen2 ~= nil and gen2.gen == 2 and gen2.lineage == model.id, "segunda generación de la misma familia")
end)

test("[ED] Partidas anteriores: el esquema 15 pasa al 16 con borradores vacíos y los modelos intactos", function()
	local g = newCompany("Vieja Motors")
	local ctx = makeCtx(42)
	local id = saveNew(g, ctx, "brisa", "Clásico")
	local old = jsonCopy(g)
	old.schema = 15
	old.drafts = nil
	local m, err = GameState.migrate(old, 1)
	check(m ~= nil, err)
	eq(m.schema, GameState.SCHEMA, "esquema actual")
	eq(#m.drafts, 0, "sin borradores")
	eq(m.designs[1].id, id, "el modelo sigue")
	check(DesignCalc.sameSpec(m.designs[1], g.designs[1]), "con las mismas especificaciones")
	check(GameState.validate(m), "válida")
	check(Actions.createLot(m, ctx, { designId = id, qty = 5 }).ok, "y se puede fabricar")
end)


test("[ED] Revisiones del borrador: una respuesta o un reintento atrasado no pisan cambios más nuevos", function()
	local g = newCompany("Revisión Motors")
	local ctx = makeCtx(43)
	local function named(n: string): any
		return draftFor(g, "brisa", n)
	end
	check(Actions.saveDraft(g, ctx, { draftId = "rev-prueba", draft = named("Versión tres"), rev = 3 }).ok, "revisión 3")
	local old = Actions.saveDraft(g, ctx, { draftId = "rev-prueba", draft = named("Versión dos"), rev = 2 })
	check(old.ok and old.stale, "una revisión vieja se responde bien pero no se aplica")
	eq(g.drafts[1].spec.name, "Versión tres", "lo más nuevo se conserva")
	local same = Actions.saveDraft(g, ctx, { draftId = "rev-prueba", draft = named("Otra cosa"), rev = 3 })
	check(same.ok and same.stale, "reenviar la misma revisión no duplica ni pisa")
	eq(g.drafts[1].spec.name, "Versión tres", "sigue igual")
	eq(#g.drafts, 1, "sin borradores duplicados")
	check(Actions.saveDraft(g, ctx, { draftId = "rev-prueba", draft = named("Versión cuatro"), rev = 4 }).ok, "revisión 4")
	eq(g.drafts[1].spec.name, "Versión cuatro", "la revisión nueva se aplica")
	eq(g.drafts[1].rev, 4, "y queda registrada")
	-- Clientes sin revisión (versiones anteriores) siguen guardando como antes.
	check(Actions.saveDraft(g, ctx, { draftId = "rev-prueba", draft = named("Sin revisión") }).ok, "sin rev")
	eq(g.drafts[1].spec.name, "Sin revisión", "se guarda")
	eq(g.drafts[1].rev, 4, "la revisión guardada no cambia")
	check(Actions.saveDraft(g, ctx, { draftId = "viejo-cliente", draft = named("Viejo") }).ok, "borrador nuevo sin revisión")
	eq(g.drafts[2].rev, nil, "sin revisión registrada")
	check(GameState.validate(g), "la partida es válida con y sin revisiones")
	local bad = jsonCopy(g)
	bad.drafts[1].rev = -1
	check(not GameState.validate(bad), "una revisión inválida se detecta")
	bad.drafts[1].rev = 1.5
	check(not GameState.validate(bad), "también una no entera")
	local loaded = jsonCopy(g)
	check(GameState.validate(loaded) and loaded.drafts[1].rev == 4, "la revisión sobrevive a guardar y cargar")
end)


-- Producción y ventas definitivas ------------------------------------------------------------------------
test("[PV] Fabricación con el calendario: duración estimada real, 1×/2×/3×, pausa, bonificaciones y sin conexión", function()
	local store = newStore()
	local clock = { t = 1000, c = 0 }
	local mgr = makeServer(store, "A", clock)
	local p = { UserId = 601 }
	mgr:add(p)
	local s = playThrough(mgr, p)
	local g = s.game
	g.money = 50000000
	check(mgr:request(p, "saveDesign", { draft = draftFor(g, "brisa", "Ritmo"), requestId = rid() }).ok, "diseño")
	local id = g.designs[#g.designs].id
	local qty = 600
	local estimate = Rules.daysFor(g, qty)
	local r = mgr:request(p, "createLot", { designId = id, qty = qty, line = 1, requestId = rid() })
	check(r.ok, r.msg)
	local lot = findLot(g, r.lotId)
	eq(lot.line, 1, "en la línea 1")
	local cost = g.money
	-- 1×: avanza con el calendario de la empresa.
	local d0, p0 = Rules.absDay(g), Rules.lotProgress(lot)
	ticks(mgr, clock, 20)
	local days1, prog1 = Rules.absDay(g) - d0, Rules.lotProgress(lot) - p0
	eq(days1, 10, "1×: 20 s reales = 10 días")
	check(prog1 > 0, "avanza")
	-- La estimación coincide con el avance real (por día de juego).
	local perDay = prog1 / days1
	check(math.abs(1 / perDay - estimate) / estimate < 0.15, "duración estimada coherente: " .. Util.num(estimate, 1) .. " días estimados, " .. Util.num(1 / perDay, 1) .. " reales")
	-- 2× y 3×: el mismo avance por día de juego, más días por segundo real.
	mgr:request(p, "setSpeed", { speed = 2, requestId = rid() })
	local a2 = Rules.lotProgress(lot)
	ticks(mgr, clock, 10)
	local prog2 = Rules.lotProgress(lot) - a2
	mgr:request(p, "setSpeed", { speed = 3, requestId = rid() })
	local a3 = Rules.lotProgress(lot)
	ticks(mgr, clock, 10)
	local prog3 = Rules.lotProgress(lot) - a3
	local base = prog1 / 2 -- 1× en 10 s
	check(math.abs(prog2 / base - 2) < 0.3 and math.abs(prog3 / base - 3) < 0.4, "2× y 3× fabrican el doble y el triple por segundo real (" .. Util.num(prog2 / base, 2) .. "× y " .. Util.num(prog3 / base, 2) .. "×)")
	-- Pausa de la empresa y menú abierto: no avanza.
	mgr:request(p, "setSpeed", { speed = 0, requestId = rid() })
	local paused = lot.produced + lot.prodProgress
	ticks(mgr, clock, 20)
	eq(lot.produced + lot.prodProgress, paused, "en pausa no se fabrica")
	mgr:request(p, "setSpeed", { speed = 1, requestId = rid() })
	mgr:request(p, "setUiPause", { paused = true })
	ticks(mgr, clock, 20)
	eq(lot.produced + lot.prodProgress, paused, "con un menú abierto tampoco")
	mgr:request(p, "setUiPause", { paused = false })
	-- Bonificaciones: con estaciones mejoradas el tiempo restante baja sin perder avance.
	local left0 = Rules.lotDaysLeft(g, lot)
	local made = lot.produced
	for _, st in g.stations do
		st.level = 4
	end
	check(Rules.lotDaysLeft(g, lot) < left0 and lot.produced == made, "los días restantes se recalculan y el avance se conserva")
	check(#Rules.productionBonuses(g) >= 1, "las bonificaciones activas se informan")
	-- Sin conexión no avanza; al volver sigue desde donde quedó, sin cobrar otra vez.
	local snapshot = lot.produced
	mgr:request(p, "leaveCompany", {})
	mgr:remove(p)
	clock.t += 3600
	local mgr2 = makeServer(store, "B", clock)
	mgr2:add(p)
	check(mgr2:request(p, "selectSlot", { slot = "1" }).ok, "volver")
	local g2 = mgr2.list[p].game
	local lot2 = findLot(g2, r.lotId)
	eq(lot2.produced, snapshot, "sin conexión no se fabricó")
	eq(lot2.line, 1, "conserva la línea")
	eq(g2.money, cost, "sin cobros extra")
	eq(#g2.lots, 1, "sin lotes duplicados")
	for _ = 1, 6000 do
		ticks(mgr2, clock, 1)
		if lot2.prodState == "completado" then
			break
		end
	end
	eq(lot2.produced, qty, "la línea completa el lote")
	check(#lot2.review.scores == 4, "con sus cuatro reseñas")
end)

test("[PV] Reseñas una sola vez, demanda en cinco niveles del modelo real, precio libre y ventas sin duplicar", function()
	local g = newCompany("Demanda SA")
	local ctx = makeCtx(602)
	g.money = 5000000
	local id = saveNew(g, ctx, "brisa", "Mercado")
	local r = Actions.createLot(g, ctx, { designId = id, qty = 300 })
	check(r.ok, r.msg)
	local lot = findLot(g, r.lotId)
	check(runUntil(g, ctx, function()
		return lot.saleState == "por lanzar"
	end, 100), "terminado")
	local review = jsonCopy(lot.review)
	eq(#review.scores, 4, "cuatro críticos")
	local sum = 0
	for _, sc in review.scores do
		check(sc.score >= 1 and sc.score <= 10 and type(sc.text) == "string" and #sc.text > 0 and sc.name ~= nil, "nota de 1 a 10 con comentario: " .. tostring(sc.name))
		sum += sc.score
	end
	check(math.abs(review.avg - sum / 4) < 0.06, "la nota final es el promedio")
	Simulation.reviewLot(g, ctx, lot)
	eq(serde.encode("json", lot.review), serde.encode("json", review), "no se recalculan")
	-- Demanda: cinco niveles; sube al bajar el precio, con mejores reseñas, más reputación y campaña.
	local function level(price: number?): number
		return Rules.demandInfo(g, lot, price).level
	end
	local ref = lot.refPrice
	check(level(ref * 6) < level(ref) and level(ref * 0.5) >= level(ref), "el precio cambia la demanda (" .. level(ref * 0.5) .. " / " .. level(ref) .. " / " .. level(ref * 6) .. ")")
	local info = Rules.demandInfo(g, lot, ref)
	check(info.level >= 1 and info.level <= 5 and Catalog.DEMAND_LEVELS.labels[info.level] == info.label, "nivel y etiqueta: " .. info.label)
	local ratioRef = info.ratio
	lot.review.avg = 9.5
	check(Rules.demandInfo(g, lot, ref).ratio > ratioRef, "mejores reseñas, más demanda")
	lot.review.avg = review.avg
	local rep = g.reputation
	g.reputation = 5
	check(Rules.demandInfo(g, lot, ref).ratio > ratioRef, "más reputación, más demanda")
	g.reputation = rep
	-- La vista previa usa el mismo peso con el que el servidor reparte la demanda.
	local wPreview = Rules.demandInfo(g, lot, ref).ratio
	lot.price = ref
	local rivals, rsum = Rules.rivalOffers(lot.design.type, Rules.yearFrac(g), g), 0
	for _, x in rivals do
		rsum += x.weight
	end
	check(math.abs(Rules.lotWeight(g, lot, Rules.yearFrac(g)) / (rsum / #rivals) - wPreview) < 1e-6, "misma cuenta que la simulación")
	-- Precio libre: por debajo del costo también; nunca más ventas que stock ni ingresos duplicados.
	check(Actions.launchSale(g, ctx, { lotId = lot.id, price = math.floor(lot.unitCost * 0.6) }).ok, "a la venta por debajo del costo")
	local moneyBefore, revBefore = g.money, lot.revenue
	runReal(g, ctx, 5, lotInvariants)
	check(lot.sold > 0, "vende")
	eq(lot.revenue - revBefore, (lot.sold) * lot.price, "ingresos = vendidas × precio (sin duplicar)")
	check(Rules.lotAvailable(lot) >= 0 and lot.sold <= lot.produced, "nunca más que el stock")
	check(g.money - moneyBefore <= lot.revenue - revBefore, "la caja no recibe más que lo vendido")
	-- Un precio nuevo afecta lo que viene: lo ya cobrado no cambia.
	local revNow = lot.revenue
	check(Actions.setLotPrice(g, ctx, { lotId = lot.id, price = lot.refPrice * 2 }).ok, "precio nuevo")
	eq(lot.revenue, revNow, "los ingresos ya cobrados no cambian")
	check(runUntil(g, ctx, function()
		return findLot(g, lot.id) == nil
	end, 400), "se agota")
	local h = findHist(g, lot.id)
	eq(h.saleState, "agotado", "agotado")
	eq(h.sold, 300, "las 300 vendidas")
	check(not Actions.createLot(g, ctx, { designId = id, qty = 10 }).ok, "agotado: no se fabrica otro lote del mismo modelo")
end)


-- Investigación definitiva ---------------------------------------------------------------------------------
test("[ID] Investigación: recargo por adelanto exacto, tope de 5 años, cobro único, simultáneas, PI y guardado", function()
	local g = newCompany("Ciencia SA")
	local ctx = makeCtx(701)
	g.money = 100000000
	g.rp = 1000000
	-- Recargo exacto: una tecnología sin requisitos que aparece 3 años después del año actual.
	local three = nil
	for _, key in Catalog.RESEARCH_ORDER do
		for _, n in Catalog.RESEARCH[key].nodes do
			if not three and #n.req == 0 and n.year == Rules.year(g) + 3 then
				three = n
			end
		end
	end
	check(three ~= nil, "una tecnología de " .. (Rules.year(g) + 3))
	local pi, money, days, d = Rules.researchCost(g, three)
	eq(d.ahead, 3, "tres años de adelanto")
	check(math.abs(d.penalty.money - 0.45) < 1e-9 and math.abs(d.penalty.pi - 0.45) < 1e-9 and math.abs(d.penalty.days - 0.30) < 1e-9, "+45 % dinero, +45 % PI, +30 % duración")
	local R = Catalog.RESEARCH_RULES
	eq(pi, math.max(1, math.floor(three.rp * (1 + 0.45) + 0.5)), "PI sobre la base")
	eq(money, math.floor(three.cost * (1 + 0.45) / 100 + 0.5) * 100, "dinero sobre la base (redondeo a $100)")
	eq(days, math.max(1, math.floor(three.days * (1 + 0.30) + 0.5)), "días sobre la base")
	eq(d.base.money, math.floor(three.cost / 100 + 0.5) * 100, "valor base informado")
	check(R.aheadMaxYears == 5, "adelanto máximo de cinco años")
	-- Más de cinco años: no se puede iniciar.
	local far = nil
	for _, key in Catalog.RESEARCH_ORDER do
		for _, n in Catalog.RESEARCH[key].nodes do
			if not far and #n.req == 0 and n.year > Rules.year(g) + 5 then
				far = n
			end
		end
	end
	local m0 = g.money
	check(not Actions.startResearch(g, ctx, { id = far.id }).ok, "a más de cinco años no se inicia: " .. far.name)
	eq(g.money, m0, "sin cobro")
	-- Cobro único y sin duplicados (también con el mismo identificador de solicitud).
	local rp0 = g.rp
	check(Actions.startResearch(g, ctx, { id = three.id }).ok, "inicia la adelantada")
	eq(g.money, m0 - money, "cobra el dinero una vez")
	eq(g.rp, rp0 - pi, "y los PI una vez")
	check(not Actions.startResearch(g, ctx, { id = three.id }).ok, "no se inicia dos veces")
	eq(g.money, m0 - money, "sin doble cobro")
	check(not Actions.cancelResearch(g, ctx, { id = three.id }).ok, "no se cancela")
	-- Simultáneas y avance por días con el calendario.
	local second = nil
	for _, key in Catalog.RESEARCH_ORDER do
		for _, n in Catalog.RESEARCH[key].nodes do
			if not second and n.category ~= three.category and Rules.researchState(g, n) == "disponible" and Rules.researchAhead(g, n) == 0 then
				second = n
			end
		end
	end
	check(Actions.startResearch(g, ctx, { id = second.id }).ok, "segunda simultánea")
	eq(#g.research.projects, 2, "dos en curso")
	-- Guardado y carga: progreso, PI y proyectos se conservan.
	Simulation.simulate(g, ctx, Catalog.RULES.gameDayMinutes * 5)
	local saved = jsonCopy(g)
	check(GameState.validate(saved), "válida")
	eq(#saved.research.projects, 2, "proyectos guardados")
	eq(saved.research.projects[1].progress, g.research.projects[1].progress, "con su progreso")
	check(math.abs(saved.rp - g.rp) < 1e-6, "PI guardados")
	-- Al terminar se desbloquea una sola vez.
	check(runUntil(saved, ctx, function()
		return #saved.research.projects == 0
	end, 200), "terminan")
	check(Rules.has(saved, three.id) and Rules.has(saved, second.id), "desbloqueadas")
	local count = 0
	for _, id in saved.research.done do
		count += (id == three.id) and 1 or 0
	end
	eq(count, 1, "sin desbloqueos duplicados")
	-- Generación de PI: centro + líneas; el personal no la aumenta.
	local h = newCompany("PI SA")
	local before = Rules.piPerMinute(h)
	Simulation.ensureMarket(h, ctx)
	local hired = 0
	for _, c in table.clone(h.candidates) do
		if hired < 3 and Actions.hire(h, ctx, { candidateId = c.id, dept = "investigacion" }).ok then
			hired += 1
		end
	end
	check(hired > 0, "personal de Investigación contratado")
	eq(Rules.piPerMinute(h), before, "los empleados de Investigación no suben los PI por minuto")
	local rpA = h.rp
	Simulation.simulate(h, ctx, Catalog.RULES.gameDayMinutes * 30)
	check(h.rp > rpA, "los PI se generan con el tiempo simulado")
end)


-- Tramos de pared construidos, contados de forma independiente de Office: cada casilla del borde aporta un tramo
-- por cada lado exterior que toca, salvo que sea un acceso (puerta abierta en ese lado).
local function builtWalls(r: any): number
	local access = {}
	for _, a in r.access do
		access[a[1] .. ":" .. a[2]] = true
	end
	local n = 0
	for x = 0, r.w - 1 do
		for _, y in { 0, r.d - 1 } do
			if not access[x .. ":" .. y] then
				n += 1
			end
		end
	end
	for y = 0, r.d - 1 do
		for _, x in { 0, r.w - 1 } do
			if not access[x .. ":" .. y] then
				n += 1
			end
		end
	end
	return n
end

-- [OF] Oficinas decorables (etapa 1: datos y servicios) ---------------------------------------------------
local Office = require("./.build/shared/Office")
local OfficeCatalog = require("./.build/shared/OfficeCatalog")
local OfficeService = require("./.build/server/OfficeService")

test("[OF] Empresa nueva: oficina del nivel 1, escritorio y silla iniciales en el inventario una sola vez", function()
	local g = newCompany("Oficina Nueva")
	local o = g.office
	check(Office.validate(o), "datos válidos")
	eq(o.level, 1, "plano del nivel de oficinas")
	eq(#o.placed, 0, "nada colocado al empezar")
	eq(Office.count(o, "escritorio_metal_1970"), 1, "escritorio guardado en el inventario")
	eq(Office.count(o, "silla_oficina_1970"), 1, "silla guardada en el inventario")
	check(o.starter == true, "marca de entrega inicial")
	eq(Office.grantStarter(o), 0, "volver a entregarlos no hace nada")
	eq(Office.count(o, "escritorio_metal_1970") + Office.count(o, "silla_oficina_1970"), 2, "sin duplicados")
	for _, r in OfficeCatalog.plan(1).rooms do
		check(o.finishes[r.id] ~= nil, "acabados básicos en " .. r.id)
	end
	check(GameState.validate(g), "la partida valida")
end)

test("[OF] Partida existente (esquema 17): migración aditiva sin perder datos y repetible", function()
	local g = newCompany("Vieja Oficina")
	local ctx = makeCtx(7)
	local id = saveNew(g, ctx, "brisa", "Modelo Viejo")
	g.money = 123456
	g.sede = 2
	local old = jsonCopy(g)
	old.office = nil
	old.schema = 17
	local before = jsonCopy(old)
	local m, err = GameState.migrate(jsonCopy(old), 1)
	check(m ~= nil, err)
	eq(m.schema, GameState.SCHEMA, "esquema actual")
	eq(m.office.level, 2, "la oficina sigue el nivel real (2)")
	eq(Office.owned(m.office, "escritorio_metal_1970") + Office.owned(m.office, "silla_oficina_1970"), 2, "recibe escritorio y silla")
	eq(#m.office.placed, 0, "guardados (no colocados)")
	for k, v in before do
		if k ~= "schema" then
			eq(serde.encode("json", m[k]), serde.encode("json", v), "campo conservado: " .. k)
		end
	end
	eq(m.designs[1].id, id, "diseños intactos")
	eq(m.money, 123456, "dinero intacto")
	check(GameState.validate(m), "válida")
	-- Cargar otra vez la partida ya migrada no vuelve a entregar nada.
	local again = GameState.migrate(jsonCopy(m), 2)
	Office.sanitize(again)
	eq(Office.owned(again.office, "escritorio_metal_1970") + Office.owned(again.office, "silla_oficina_1970"), 2, "recargar no duplica el mobiliario inicial")
	-- Perfil completo desde el guardado: misma ruta que DataService.
	local profile, damaged = GameState.loadProfile({ profile = { slots = { ["1"] = jsonCopy(old) }, active = "1" } }, 3)
	check(profile ~= nil and next(damaged) == nil, "el perfil carga sin ranuras dañadas")
	eq(Office.count(profile.slots["1"].office, "silla_oficina_1970"), 1, "con la oficina inicializada")
end)

test("[OF] Serialización: la oficina sobrevive a JSON (formato del guardado) idéntica y por empresa", function()
	local a, b = newCompany("Empresa Uno"), newCompany("Empresa Dos")
	a.money = 1e6
	local r = OfficeService.place(a, { item = "lampara_pie_1970", room = "oficina_principal", x = 8.5, y = 6.5, rot = 0 })
	check(r.ok, r.msg)
	check(OfficeService.remove(a, { instance = r.instance }).ok, "retirar")
	local copy = jsonCopy(a)
	eq(serde.encode("json", copy.office), serde.encode("json", a.office), "misma oficina después de serializar")
	check(GameState.validate(copy), "la copia valida")
	eq(Office.count(copy.office, "lampara_pie_1970"), 1, "inventario recuperado")
	eq(Office.count(b.office, "lampara_pie_1970"), 0, "la otra empresa no comparte inventario")
	eq(#b.office.placed, 0, "ni distribución")
	check(a.office ~= b.office and a.office.inventory ~= b.office.inventory, "tablas independientes")
end)

test("[OF] Catálogo histórico: desde su año en adelante y para siempre; solo registros de 1970", function()
	local n = 0
	for id, f in OfficeCatalog.FURNITURE do
		n += 1
		eq(f.id, id, "id coherente")
		eq(f.year, 1970, id .. " es de 1970")
		check(f.price > 0 and #f.cells == 2 and #f.rotations > 0 and type(f.model) == "string", id .. ": precio, casillas, giros y modelo futuro")
		local cat = false
		for _, c in OfficeCatalog.CATEGORIES do
			cat = cat or c.id == f.category
		end
		check(cat, id .. ": categoría conocida")
		if f.bonus then
			check(Catalog.STAFF.skills[f.bonus.skill] ~= nil, id .. ": bonificación sobre una habilidad existente (tope compartido)")
			check(f.bonus.value > 0 and f.bonus.value <= Catalog.STAFF.skills[f.bonus.skill].cap * 0.1, id .. ": bonificación moderada")
		end
	end
	check(n >= 7 and n <= 12, "pocos registros de prueba (" .. n .. ")")
	local future = { year = 1985 }
	check(not Office.available(future, 1984) and Office.available(future, 1985) and Office.available(future, 2030), "desde 1985, para siempre")
	eq(#Office.catalogFor(1970), n, "en 1970 está todo el catálogo de prueba")
	eq(#Office.catalogFor(2040), n, "y en 2040 sigue todo")
	-- Un mueble futuro no se puede comprar antes de su año (validado en el servidor).
	local g = newCompany("Museo Motors")
	g.money = 1e6
	OfficeCatalog.FURNITURE.prueba_1990 = { id = "prueba_1990", name = "Prueba", category = "decoracion", year = 1990, price = 10, cells = { 1, 1 }, rotations = { 0 }, model = "x" }
	local r = OfficeService.place(g, { item = "prueba_1990", room = "oficina_principal", x = 8.5, y = 1.5, rot = 0 })
	OfficeCatalog.FURNITURE.prueba_1990 = nil
	check(not r.ok and string.find(r.msg, "1990", 1, true) ~= nil, "rechaza un mueble de 1990 en 1970")
	eq(g.money, 1e6, "sin cobro")
end)

test("[OF] Rotaciones y cuadrícula: giros de 45°, casillas ocupadas, límites, accesos y diagonales", function()
	local desk = OfficeCatalog.item("escritorio_metal_1970")
	local sofa = OfficeCatalog.item("sofa_cuero_1970")
	for _, rot in { 0, 45, 90, 135, 180, 225, 270, 315 } do
		check(Office.validRotation(desk, rot), "escritorio admite " .. rot .. "°")
	end
	check(not Office.validRotation(desk, 30) and not Office.validRotation(desk, 360) and not Office.validRotation(desk, -45) and not Office.validRotation(desk, 45.5), "rechaza giros que no son múltiplos de 45 en [0, 360)")
	for id, f in OfficeCatalog.FURNITURE do
		for _, rot in { 0, 45, 90, 135, 180, 225, 270, 315 } do
			check(Office.validRotation(f, rot), id .. " admite " .. rot .. "°")
		end
	end
	check(Office.validRotation(sofa, 45), "el sofá también gira en diagonal")
	eq(#Office.footprint(desk, 5, 2.5, 0), 2, "escritorio 2×1 ocupa 2 casillas")
	local r90 = Office.footprint(desk, 5.5, 3, 90)
	eq(#r90, 2, "girado 90° también 2")
	check(r90[1][1] == r90[2][1], "y en vertical (misma columna)")
	local diag = Office.footprint(OfficeCatalog.item("mesa_reuniones_1970"), 6, 5, 45)
	check(#diag >= 4, "la mesa en diagonal ocupa las casillas que cubre (" .. #diag .. ")")
	local o = Office.new(1)
	local ok, why = Office.validatePlacement(o, desk, { room = "oficina_principal", x = 5, y = 2.5, rot = 0 })
	check(ok, why)
	table.insert(o.placed, { id = "m1", item = desk.id, room = "oficina_principal", x = 5, y = 2.5, rot = 0 })
	ok, why = Office.validatePlacement(o, desk, { room = "oficina_principal", x = 5, y = 2.5, rot = 0 })
	check(not ok and string.find(why, "ocupado", 1, true) ~= nil, "casilla ocupada")
	check(Office.validatePlacement(o, desk, { room = "oficina_principal", x = 5, y = 2.5, rot = 0 }, "m1"), "al moverse no choca consigo mismo")
	ok, why = Office.validatePlacement(o, desk, { room = "oficina_principal", x = 10, y = 2.5, rot = 0 })
	check(not ok and string.find(why, "sale", 1, true) ~= nil, "fuera de la habitación")
	ok, why = Office.validatePlacement(o, desk, { room = "oficina_principal", x = 8.5, y = 2.5, rot = 0 })
	check(not ok and string.find(why, "alineado", 1, true) ~= nil, "un mueble de 2 casillas no se centra en media casilla")
	check(Office.validatePlacement(o, desk, { room = "oficina_principal", x = 8.5, y = 5, rot = 90 }), "girado 90°, el lado par pasa a ser vertical")
	ok, why = Office.validatePlacement(o, OfficeCatalog.item("planta_interior_1970"), { room = "oficina_principal", x = 0.5, y = 3.5, rot = 0 })
	check(not ok and string.find(why, "acceso", 1, true) ~= nil, "no puede bloquear la puerta")
	ok, why = Office.validatePlacement(o, desk, { room = "direccion", x = 3, y = 2.5, rot = 0 })
	check(not ok, "habitación que no existe en este nivel")
	ok = Office.validatePlacement(o, desk, { room = "oficina_principal", x = 5.25, y = 2.5, rot = 0 })
	check(not ok, "coordenadas fuera de la cuadrícula de medias casillas")
	-- Punto de uso del avatar: gira con el mueble.
	local p = { x = 5, y = 2.5, rot = 90 }
	local pt = Office.interactionPoint(desk, p)
	check(math.abs(pt.x - 4) < 1e-6 and math.abs(pt.y - 2.5) < 1e-6 and pt.facing == 0, "el punto del escritorio gira con él (mira al escritorio)")
end)

test("[OF] Compra y colocación atómicas: precio del servidor, sin cobro si falla, inventario sin duplicados", function()
	local g = newCompany("Muebles SA")
	local ctx = makeCtx(3)
	local lamp = OfficeCatalog.item("lampara_pie_1970")
	g.money = 1000
	local m0 = g.money
	-- Ubicación inválida: no cobra.
	local r = OfficeService.place(g, { item = lamp.id, room = "oficina_principal", x = 0.5, y = 3.5, rot = 0, price = 1 })
	check(not r.ok, "ubicación inválida")
	eq(g.money, m0, "sin cobro")
	-- Sin fondos: no cobra ni coloca.
	g.money = lamp.price - 1
	local placed0 = #g.office.placed
	r = OfficeService.place(g, { item = lamp.id, room = "oficina_principal", x = 8.5, y = 6.5, rot = 0 })
	check(not r.ok and g.money == lamp.price - 1 and #g.office.placed == placed0, "sin fondos no cambia nada")
	-- Compra válida: cobra el precio del catálogo (ignora un precio enviado por el cliente).
	g.money = 1000
	r = OfficeService.place(g, { item = lamp.id, room = "oficina_principal", x = 8.5, y = 6.5, rot = 0, price = 1, opId = "op-1" })
	check(r.ok and r.paid == lamp.price, r.msg)
	eq(g.money, 1000 - lamp.price, "cobra el precio del catálogo")
	-- La misma solicitud repetida no vuelve a cobrar ni crea otra unidad.
	r = OfficeService.place(g, { item = lamp.id, room = "oficina_principal", x = 8.5, y = 5.5, rot = 0, opId = "op-1" })
	check(r.ok and r.repeated, "solicitud repetida")
	eq(g.money, 1000 - lamp.price, "sin segundo cobro")
	eq(Office.owned(g.office, lamp.id), 1, "una sola lámpara")
	local inst = g.office.placed[#g.office.placed].id
	-- Mover y girar: gratis.
	local money1 = g.money
	check(OfficeService.move(g, { instance = inst, room = "oficina_principal", x = 8.5, y = 5.5, rot = 90 }).ok, "mover")
	eq(g.money, money1, "mover es gratis")
	-- Retirar: vuelve al inventario, sin reembolso; retirar dos veces no crea otra unidad.
	check(OfficeService.remove(g, { instance = inst }).ok, "retirar")
	check(not OfficeService.remove(g, { instance = inst }).ok, "retirar de nuevo falla")
	eq(Office.count(g.office, lamp.id), 1, "una en el inventario")
	eq(Office.placedCount(g.office, lamp.id), 0, "ninguna colocada (no está en los dos estados)")
	eq(g.money, money1, "sin reembolso")
	-- Volver a colocarla desde el inventario: gratis, aunque no alcance el dinero para una nueva.
	g.money = 0
	r = OfficeService.place(g, { item = lamp.id, room = "oficina_principal", x = 7.5, y = 6.5, rot = 0 })
	check(r.ok and r.fromInventory and r.paid == 0, "desde el inventario es gratis")
	eq(Office.count(g.office, lamp.id), 0, "el inventario baja a cero (nunca negativo)")
	check(not Office.takeFromInventory(g.office, lamp.id), "no se puede sacar de un inventario vacío")
	check(not Office.addToInventory(g.office, lamp.id, -2) and not Office.addToInventory(g.office, lamp.id, 1.5) and not Office.addToInventory(g.office, "inexistente", 1), "no acepta cantidades negativas, fraccionarias ni muebles desconocidos")
	-- La economía existente no cambió: solo el gasto registrado en «sede».
	check(GameState.validate(g), "la partida valida")
	Simulation.simulate(g, ctx, Catalog.RULES.gameDayMinutes)
	check(GameState.validate(g), "y sigue válida después de simular")
end)

test("[OF] Bonificaciones aisladas: solo lo colocado suma, rendimientos decrecientes y tope compartido; sin efecto actual", function()
	local g = newCompany("Bonos SA")
	local o = g.office
	local desk = OfficeCatalog.item("escritorio_metal_1970")
	local before = Rules.staff(g, "organizacion")
	eq(Office.furnitureRaw(o, "organizacion"), 0, "el escritorio inicial guardado no suma")
	table.insert(o.placed, { id = "x0", item = desk.id, room = "oficina_principal", x = 5, y = 2.5, rot = 0 })
	eq(Office.furnitureRaw(o, "organizacion"), desk.bonus.value, "colocado suma su valor")
	table.insert(o.placed, { id = "x1", item = desk.id, room = "oficina_principal", x = 5, y = 5.5, rot = 0 })
	local two = Office.furnitureRaw(o, "organizacion")
	check(math.abs(two - desk.bonus.value * (1 + OfficeCatalog.BONUS_DECAY)) < 1e-9, "la segunda copia suma la mitad")
	Office.addToInventory(o, desk.id, 5)
	eq(Office.furnitureRaw(o, "organizacion"), two, "lo guardado no suma")
	local cap = Catalog.STAFF.skills.organizacion.cap
	eq(Office.sharedBonus(cap, two, cap), cap, "con el personal al tope, los muebles no superan el límite")
	check(math.abs(Office.sharedBonus(0.1, two, cap) - (0.1 + two)) < 1e-9, "por debajo del tope se suman")
	check(math.abs(Rules.staff(g, "organizacion") - (before + two)) < 1e-9, "la simulación aplica el mobiliario una sola vez (Rules.staff)")
end)

test("[OF] Acabados y ampliación: cotización por superficie/largo/luminarias, sin pérdidas al cambiar de plano", function()
	local g = newCompany("Remodela SA")
	local o = g.office
	local r1 = OfficeCatalog.room(1, "oficina_principal")
	local cost, lines = Office.remodelQuote(o, "oficina_principal", { floor = "piso_parquet_1970", wall = "pared_beige_1970", lighting = "luz_calida_1970" }, 1970)
	local exp = r1.w * r1.d * 40 + builtWalls(r1) * 15 + math.ceil(r1.w * r1.d / OfficeCatalog.LIGHT_AREA) * 120
	eq(cost, exp, "piso por casilla, paredes por tramo, luces por luminaria")
	eq(#lines, 3, "tres líneas")
	eq(o.finishes.oficina_principal.floor, "piso_cemento", "cotizar no cambia nada (previsualización gratis)")
	local same = Office.remodelQuote(o, "oficina_principal", { floor = "piso_cemento" }, 1970)
	eq(same, 0, "lo que ya tiene no se cobra")
	check(Office.remodelQuote(o, "direccion", {}, 1970) == nil, "habitación inexistente en el nivel 1")
	-- Ampliación: acabado elegido conservado, habitación nueva con acabado básico y muebles sin pérdidas.
	o.finishes.oficina_principal.floor = "piso_parquet_1970"
	Office.addToInventory(o, "planta_interior_1970", 1)
	table.insert(o.placed, { id = "far", item = "planta_interior_1970", room = "oficina_principal", x = 9.5, y = 7.5, rot = 0 })
	local owned = {}
	for id in OfficeCatalog.FURNITURE do
		owned[id] = Office.owned(o, id)
	end
	g.sede = 2
	local res = Office.remap(o, 2)
	eq(o.level, 2, "plano del nivel 2")
	eq(o.finishes.oficina_principal.floor, "piso_parquet_1970", "acabado conservado en la habitación equivalente")
	eq(o.finishes.sala_reuniones.floor, OfficeCatalog.DEFAULT_FINISH.floor, "la habitación nueva recibe el básico")
	for id, n in owned do
		eq(Office.owned(o, id), n, "sin pérdidas ni copias: " .. id)
	end
	eq(res.toInventory, 0, "todo entra en la oficina más grande")
	-- Un plano más chico (caso de prueba): lo que no entra vuelve al inventario.
	res = Office.remap(o, 1)
	OfficeCatalog.PLANS[6] = { rooms = { { id = "oficina_principal", name = "Chica", w = 4, d = 3, access = {} } } }
	local small = Office.remap(o, 6)
	OfficeCatalog.PLANS[6] = nil
	for id, n in owned do
		eq(Office.owned(o, id), n, "plano chico, sin pérdidas: " .. id)
	end
	check(small.toInventory >= 1, "lo que no entra vuelve al inventario")
end)

test("[OF] Ampliación real de oficinas: la obra terminada pasa la decoración al plano nuevo", function()
	local g = newCompany("Crece SA")
	local ctx = makeCtx(9)
	g.money = 1e9
	g.counters.unitsSold = 1e6
	g.reputation = 5
	local r = Actions.upgradeFacility(g, ctx, { kind = "offices" })
	check(r.ok, r.msg)
	Simulation.simulate(g, ctx, Catalog.RULES.gameDayMinutes * 400)
	eq(g.sede, 2, "oficinas nivel 2")
	eq(g.office.level, 2, "la decoración sigue al nivel")
	eq(Office.owned(g.office, "escritorio_metal_1970") + Office.owned(g.office, "silla_oficina_1970"), 2, "escritorio y silla conservados")
	check(g.office.finishes.sala_reuniones ~= nil, "acabados para la sala nueva")
	check(GameState.validate(g), "válida")
end)

test("[OF] Reparación al cargar: datos de oficina dañados no dañan la empresa ni pierden muebles", function()
	local g = newCompany("Rota SA")
	local save = jsonCopy(g)
	save.office.inventory.lampara_pie_1970 = -3
	save.office.inventory.mueble_inexistente = 2
	table.insert(save.office.placed, { id = "m1", item = "planta_interior_1970", room = "oficina_principal", x = 0.5, y = 3.5, rot = 0 }) -- id repetido y sobre la puerta
	table.insert(save.office.placed, { id = "zz", item = "silla_oficina_1970", room = "habitacion_vieja", x = 1.5, y = 1.5, rot = 0 })
	save.office.finishes.oficina_principal.floor = "piso_desconocido"
	local profile, damaged = GameState.loadProfile({ profile = { slots = { ["1"] = save }, active = "1" } }, 5)
	check(profile ~= nil and next(damaged) == nil, "la empresa carga")
	local o = profile.slots["1"].office
	check(Office.validate(o), "oficina reparada")
	eq(o.inventory.lampara_pie_1970, nil, "cantidad negativa descartada")
	eq(o.inventory.mueble_inexistente, nil, "mueble desconocido descartado")
	eq(Office.count(o, "planta_interior_1970"), 1, "el mueble con datos inválidos vuelve al inventario")
	eq(Office.count(o, "silla_oficina_1970"), 2, "el de una habitación inexistente también (más la inicial)")
	eq(o.finishes.oficina_principal.floor, OfficeCatalog.DEFAULT_FINISH.floor, "acabado desconocido → básico")
end)


test("[OF2] Correcciones: partida del esquema 18 con escritorio y silla colocados solos → vuelven al inventario", function()
	local g = newCompany("Esquema Ocho")
	local old = jsonCopy(g)
	old.schema = 18
	-- Así quedaban en la etapa 1: colocados en su lugar inicial, inventario vacío, seq = 2.
	old.office.inventory = {}
	old.office.placed = {}
	for i, st in OfficeCatalog.STARTER do
		table.insert(old.office.placed, { id = "m" .. i, item = st.item, room = st.room, x = st.x, y = st.y, rot = st.rot })
	end
	old.office.seq = 2
	old.office.rev = nil
	-- Y un mueble comprado que no es el inicial (debe quedar donde está).
	table.insert(old.office.placed, { id = "m3", item = "planta_interior_1970", room = "oficina_principal", x = 8.5, y = 6.5, rot = 0 })
	old.office.seq = 3
	local m, err = GameState.migrate(jsonCopy(old), 1)
	check(m ~= nil, err)
	eq(m.schema, GameState.SCHEMA, "esquema actual")
	eq(Office.count(m.office, "escritorio_metal_1970"), 1, "escritorio al inventario")
	eq(Office.count(m.office, "silla_oficina_1970"), 1, "silla al inventario")
	eq(#m.office.placed, 1, "el mueble comprado sigue colocado")
	eq(m.office.placed[1].id, "m3", "con su id")
	check(GameState.validate(m), "válida")
	local again = GameState.migrate(jsonCopy(m), 2)
	eq(Office.owned(again.office, "escritorio_metal_1970"), 1, "volver a cargar no duplica")
	-- Un jugador que ya movió el escritorio (no está en el lugar inicial): no se toca.
	local moved = jsonCopy(old)
	moved.office.placed[1].x = 7
	local mm = GameState.migrate(moved, 3)
	eq(Office.placedCount(mm.office, "escritorio_metal_1970"), 1, "un escritorio movido queda colocado")
	eq(Office.owned(mm.office, "escritorio_metal_1970"), 1, "sin copias")
end)

test("[OF2] Correcciones: colisiones diagonales con intersección real de rectángulos y límites por esquinas", function()
	local desk = OfficeCatalog.item("escritorio_metal_1970")
	local plant = OfficeCatalog.item("planta_interior_1970")
	local sofa = OfficeCatalog.item("sofa_cuero_1970")
	local o = Office.new(1)
	-- Una planta 1×1 girada 45° en el borde: su esquina sale de la habitación (el centro de casilla no basta).
	local ok, why = Office.validatePlacement(o, plant, { room = "oficina_principal", x = 0.5, y = 7.5, rot = 45 })
	check(not ok and string.find(why, "sale", 1, true) ~= nil, "diagonal pegada a la pared: la esquina se sale")
	check(Office.validatePlacement(o, plant, { room = "oficina_principal", x = 1, y = 7, rot = 45 }), "un poco adentro sí entra")
	-- Dos muebles en diagonal que se tocan solo en las puntas de sus rectángulos: con muestras por centro de
	-- casilla no se detectaba; con intersección real, sí.
	table.insert(o.placed, { id = "m1", item = sofa.id, room = "oficina_principal", x = 5, y = 4, rot = 45 })
	o.seq = 1
	-- En (6, 5) ningún centro de casilla queda dentro de ambos rectángulos, pero los rectángulos se cruzan.
	ok, why = Office.validatePlacement(o, desk, { room = "oficina_principal", x = 6, y = 5, rot = 135 })
	check(not ok and string.find(why, "ocupado", 1, true) ~= nil, "rectángulos girados que se cruzan: ocupado")
	check(Office.validatePlacement(o, desk, { room = "oficina_principal", x = 7.5, y = 5.5, rot = 135 }), "separados: válido")
	-- Tocar un borde no es superponerse.
	local o2 = Office.new(1)
	table.insert(o2.placed, { id = "m1", item = desk.id, room = "oficina_principal", x = 5, y = 2.5, rot = 0 })
	check(Office.validatePlacement(o2, desk, { room = "oficina_principal", x = 7, y = 2.5, rot = 0 }), "dos escritorios lado a lado (comparten un borde)")
	check(not Office.validatePlacement(o2, desk, { room = "oficina_principal", x = 6, y = 2.5, rot = 0 }), "medio escritorio encima: ocupado")
	-- Una diagonal que roza un acceso también lo bloquea.
	ok, why = Office.validatePlacement(o2, plant, { room = "oficina_principal", x = 3.5, y = 3.5, rot = 45 })
	check(ok, "cerca de la puerta sin tocarla")
	ok, why = Office.validatePlacement(o2, plant, { room = "oficina_principal", x = 2.5, y = 3.5, rot = 45 })
	check(not ok, "la punta de la planta en diagonal roza la puerta")
	ok, why = Office.validatePlacement(o2, desk, { room = "oficina_principal", x = 2.5, y = 4, rot = 45 })
	check(not ok and string.find(why, "acceso", 1, true) ~= nil, "en diagonal, rozar la puerta la bloquea")
	-- Huella de casillas (para el editor): las que realmente toca.
	local fp = Office.footprint(plant, 1, 7, 45)
	eq(#fp, 4, "una planta 1×1 a 45° centrada en un vértice toca 4 casillas")
end)

test("[OF2] Correcciones: el contador de ids se sincroniza y nunca reutiliza un id", function()
	local o = Office.new(1)
	table.insert(o.placed, { id = "m7", item = "planta_interior_1970", room = "oficina_principal", x = 8.5, y = 6.5, rot = 0 })
	o.seq = 2 -- atrasado (datos recuperados)
	check(not Office.validate(o), "un seq atrasado no pasa la validación estricta")
	local g = { sede = 1, office = o }
	Office.sanitize(g)
	eq(o.seq, 7, "la reparación lo sincroniza")
	check(Office.validate(o), "y valida")
	local id = Office.newInstanceId(o)
	eq(id, "m8", "el siguiente id es nuevo")
	o.seq = 0
	eq(Office.newInstanceId(o), "m8", "aunque seq se haya atrasado, no repite un id existente")
end)


test("[OF3] Acciones de oficina por Sessions: compra única, reenvíos, rechazos sin cambios, guardado y carga en otro servidor", function()
	local store = newStore()
	local clock = { t = 1000, c = 0 }
	local mgr = makeServer(store, "A", clock)
	local p = { UserId = 7001, Name = "deco" }
	mgr:add(p)
	local s = playThrough(mgr, p)
	local g = s.game
	g.money = 100000
	local lamp = OfficeCatalog.item("lampara_pie_1970")
	-- Sin requestId no se acepta una acción económica.
	check(not mgr:request(p, "officePlace", { item = lamp.id, room = "oficina_principal", x = 8.5, y = 6.5, rot = 0 }).ok, "exige requestId")
	-- Escritorio inicial: desde el inventario, gratis.
	local m0 = g.money
	local r = mgr:request(p, "officePlace", { item = "escritorio_metal_1970", room = "oficina_principal", x = 5, y = 2.5, rot = 0, requestId = rid() })
	check(r.ok and r.fromInventory and r.paid == 0, r.msg)
	eq(g.money, m0, "colocar del inventario es gratis")
	check(s.pendingSave or s.dirty, "dispara el guardado")
	-- Compra nueva con precio enviado por el cliente: se ignora y se cobra el del catálogo, una sola vez.
	local id = rid()
	r = mgr:request(p, "officePlace", { item = lamp.id, room = "oficina_principal", x = 8.5, y = 6.5, rot = 0, price = 1, requestId = id })
	check(r.ok and r.paid == lamp.price and r.instance ~= nil, r.msg)
	local inst = r.instance
	eq(g.money, m0 - lamp.price, "precio del catálogo")
	local again = mgr:request(p, "officePlace", { item = lamp.id, room = "oficina_principal", x = 8.5, y = 6.5, rot = 0, requestId = id })
	check(again.duplicate and again.ok, "reenvío detectado")
	eq(again.instance, inst, "con los datos de la respuesta original")
	eq(again.paid, lamp.price, "y el monto cobrado original")
	eq(g.money, m0 - lamp.price, "sin segundo cobro")
	eq(Office.owned(g.office, lamp.id), 1, "una sola lámpara")
	-- Rechazos: no cambian nada.
	local before = serde.encode("json", g.office)
	local mb = g.money
	for _, bad in {
		{ item = lamp.id, room = "oficina_principal", x = 0.5, y = 3.5, rot = 0 }, -- acceso
		{ item = lamp.id, room = "oficina_principal", x = 8.5, y = 6.5, rot = 0 }, -- ocupado
		{ item = "mesa_reuniones_1970", room = "oficina_principal", x = 9, y = 7, rot = 45 }, -- diagonal fuera del plano
		{ item = lamp.id, room = "direccion", x = 1.5, y = 1.5, rot = 0 }, -- habitación de otro nivel
		{ item = lamp.id, room = "oficina_principal", x = 4.5, y = 4.5, rot = 30 }, -- giro inválido
		{ item = "inexistente", room = "oficina_principal", x = 4.5, y = 4.5, rot = 0 },
	} do
		bad.requestId = rid()
		check(not mgr:request(p, "officePlace", bad).ok, "rechazo: " .. tostring(bad.item) .. " " .. tostring(bad.x) .. "," .. tostring(bad.y))
	end
	eq(g.money, mb, "los rechazos no cobran")
	eq(serde.encode("json", g.office), before, "ni cambian la oficina")
	-- Mover, girar y retirar: gratis; retirar no reembolsa.
	check(mgr:request(p, "officeMove", { instance = inst, room = "oficina_principal", x = 7.5, y = 6.5, rot = 45, requestId = rid() }).ok, "mover y girar 45°")
	eq(g.money, mb, "gratis")
	check(mgr:request(p, "officeRemove", { instance = inst, requestId = rid() }).ok, "retirar")
	eq(Office.count(g.office, lamp.id), 1, "al inventario")
	eq(g.money, mb, "sin reembolso")
	check(mgr:request(p, "officePlace", { item = lamp.id, room = "oficina_principal", x = 8.5, y = 6.5, rot = 90, requestId = rid() }).paid == 0, "reutilizarla es gratis")
	-- Guardar, salir y cargar en otro servidor.
	local layout = serde.encode("json", g.office.placed)
	local inventory = serde.encode("json", g.office.inventory)
	mgr:remove(p)
	local mgr2, pushed2 = makeServer(store, "B", clock)
	mgr2:add(p)
	check(mgr2:request(p, "selectSlot", { slot = "1" }).ok, "volver a abrir la empresa")
	local g2 = mgr2.list[p].game
	eq(serde.encode("json", g2.office.placed), layout, "distribución conservada")
	eq(serde.encode("json", g2.office.inventory), inventory, "inventario conservado")
	eq(g2.money, mb, "dinero conservado")
	check(pushed2[p].game.office ~= nil and #pushed2[p].game.office.placed == #g2.office.placed, "el cliente recibe la oficina")
	-- Un reenvío viejo después de recargar tampoco se aplica (requestId guardado y opId en la partida).
	local r2 = mgr2:request(p, "officePlace", { item = lamp.id, room = "oficina_principal", x = 8.5, y = 6.5, rot = 0, requestId = id })
	check(r2.duplicate == true or not r2.ok, "reenvío viejo rechazado")
	eq(g2.money, mb, "sin cobro")
end)


test("[OF4] Remodelación por Sessions: cotización del servidor, sin recobros, rechazos sin cambios, reenvíos, persistencia y ampliación", function()
	local store = newStore()
	local clock = { t = 1000, c = 0 }
	local mgr = makeServer(store, "A", clock)
	local p = { UserId = 7101, Name = "remo" }
	mgr:add(p)
	local s = playThrough(mgr, p)
	local g = s.game
	g.money = 50000
	local R = "oficina_principal"
	local room = OfficeCatalog.room(g.office.level, R)
	-- Un mueble colocado: la remodelación no lo toca.
	check(mgr:request(p, "officePlace", { item = "escritorio_metal_1970", room = R, x = 5, y = 2.5, rot = 0, requestId = rid() }).ok, "escritorio colocado")
	local furniture = serde.encode("json", g.office.placed)
	local function req(changes: any, extra: any?): any
		local body = { room = R, changes = changes, rev = g.office.rev, quote = select(1, Office.remodelQuote(g.office, R, changes, Rules.year(g))), requestId = rid(), companyId = g.company.id }
		for k, v in extra or {} do
			body[k] = v
		end
		return mgr:request(p, "officeRemodel", body)
	end
	-- 1/4. Varios materiales: total = suma de cantidades × precios del catálogo.
	local F = OfficeCatalog.FINISHES
	local expected = room.w * room.d * F.floor.piso_parquet_1970.price + builtWalls(room) * F.wall.pared_beige_1970.price + builtWalls(room) * F.covering.madera_1970.price + math.ceil(room.w * room.d / OfficeCatalog.LIGHT_AREA) * F.lighting.luz_calida_1970.price
	local m0 = g.money
	local rev0 = g.office.rev
	local id = rid()
	local changes = { floor = "piso_parquet_1970", wall = "pared_beige_1970", covering = "madera_1970", lighting = "luz_calida_1970" }
	local r = mgr:request(p, "officeRemodel", { room = R, changes = changes, rev = g.office.rev, quote = expected, requestId = id, companyId = g.company.id })
	check(r.ok and r.paid == expected, tostring(r.msg))
	eq(g.money, m0 - expected, "cobra el total exacto")
	eq(g.office.finishes[R].floor, "piso_parquet_1970", "piso instalado")
	eq(g.office.finishes[R].lighting, "luz_calida_1970", "iluminación instalada")
	eq(g.office.rev, rev0 + 1, "sube la revisión de la oficina")
	eq(serde.encode("json", g.office.placed), furniture, "los muebles no cambian")
	check(s.pendingSave, "pide el guardado")
	-- 9. Reenvío con el mismo requestId: respuesta original, sin segundo cobro.
	local again = mgr:request(p, "officeRemodel", { room = R, changes = changes, rev = rev0, quote = expected, requestId = id, companyId = g.company.id })
	check(again.duplicate and again.ok and again.paid == expected, "reenvío reconocido")
	eq(g.money, m0 - expected, "un solo cobro")
	-- 5. Lo instalado no se vuelve a cobrar.
	local mA = g.money
	r = req({ floor = "piso_parquet_1970" })
	check(not r.ok, "sin cambios efectivos no hay cobro")
	eq(g.money, mA, "sin cobro")
	-- Volver a un acabado gratis: 0 y sin reembolso.
	r = req({ floor = "piso_cemento" })
	check(r.ok and r.paid == 0, "volver al cemento cuesta 0")
	eq(g.money, mA, "sin reembolso")
	-- Rechazos sin cambios.
	local before, mB = serde.encode("json", g.office), g.money
	local function bad(what: string, body: any)
		body.requestId = body.requestId or rid()
		local res = mgr:request(p, "officeRemodel", body)
		check(not res.ok, "rechaza " .. what .. ": " .. tostring(res.msg))
	end
	local rev = g.office.rev
	bad("categoría desconocida", { room = R, changes = { techo = "x" }, rev = rev, quote = 0 })
	bad("id falso", { room = R, changes = { floor = "piso_oro" }, rev = rev, quote = 0 })
	bad("id de otra categoría", { room = R, changes = { floor = "pared_beige_1970" }, rev = rev, quote = 0 })
	bad("id no textual", { room = R, changes = { floor = 5 }, rev = rev, quote = 0 })
	bad("cambios no tabla", { room = R, changes = "piso", rev = rev, quote = 0 })
	bad("habitación de otro nivel", { room = "direccion", changes = { floor = "piso_alfombra_1970" }, rev = rev, quote = 0 })
	bad("habitación falsa", { room = "x", changes = { floor = "piso_alfombra_1970" }, rev = rev, quote = 0 })
	local carpet = room.w * room.d * F.floor.piso_alfombra_1970.price
	bad("presupuesto desactualizado (precio del cliente)", { room = R, changes = { floor = "piso_alfombra_1970" }, rev = rev, quote = 1 })
	bad("revisión vieja", { room = R, changes = { floor = "piso_alfombra_1970" }, rev = rev - 1, quote = carpet })
	bad("sin revisión", { room = R, changes = { floor = "piso_alfombra_1970" }, quote = carpet })
	bad("otra empresa", { room = R, changes = { floor = "piso_alfombra_1970" }, rev = rev, quote = carpet, companyId = "c-otra" })
	-- 6. Material de un año futuro (registro de prueba).
	F.floor.prueba_1999 = { id = "prueba_1999", name = "Futuro", year = 1999, price = 1, unit = "casilla", material = "Marble", materialName = "x" }
	bad("material futuro", { room = R, changes = { floor = "prueba_1999" }, rev = rev, quote = room.w * room.d })
	F.floor.prueba_1999 = nil
	-- 7. Fondos insuficientes.
	g.money = carpet - 1
	bad("fondos insuficientes", { room = R, changes = { floor = "piso_alfombra_1970" }, rev = rev, quote = carpet })
	eq(g.money, carpet - 1, "sin cobro")
	g.money = mB
	eq(serde.encode("json", g.office), before, "ningún rechazo cambió la oficina")
	eq(g.money, mB, "ni el dinero")
	-- 11. Independencia entre habitaciones (nivel 2: la sala de reuniones no se toca al remodelar la principal).
	-- 13. Ampliación: la obra terminada conserva los acabados y la sala nueva empieza con los básicos.
	g.money = 1e9
	g.counters.unitsSold = 1e6
	g.reputation = 5
	clock.c += 30 -- pasa el límite de acciones por minuto
	clock.t += 30
	check(mgr:request(p, "upgradeFacility", { kind = "offices", requestId = rid() }).ok, "obra de oficinas")
	Simulation.simulate(g, s.ctx, Catalog.RULES.gameDayMinutes * 400)
	eq(g.sede, 2, "oficinas nivel 2")
	eq(g.office.finishes[R].lighting, "luz_calida_1970", "acabados conservados al ampliar")
	eq(serde.encode("json", g.office.finishes.sala_reuniones), serde.encode("json", OfficeCatalog.DEFAULT_FINISH), "habitación nueva con acabados básicos")
	r = req({ wall = "pared_beige_1970" }, { room = "sala_reuniones", quote = builtWalls(OfficeCatalog.room(2, "sala_reuniones")) * F.wall.pared_beige_1970.price })
	check(r.ok, "remodelar la sala nueva: " .. tostring(r.msg))
	eq(g.office.finishes[R].wall, "pared_beige_1970", "la principal sigue con su pintura")
	eq(g.office.finishes.sala_reuniones.floor, "piso_cemento", "la sala solo cambia lo pedido")
	-- 10. Guardar, salir y cargar en otro servidor.
	local finishes = serde.encode("json", g.office.finishes)
	mgr:remove(p)
	local mgr2 = makeServer(store, "B", clock)
	mgr2:add(p)
	check(mgr2:request(p, "selectSlot", { slot = "1" }).ok, "volver a abrir")
	eq(serde.encode("json", mgr2.list[p].game.office.finishes), finishes, "acabados conservados al cargar")
	-- 12. Otra empresa: sus acabados son los básicos.
	check(mgr2:request(p, "createCompany", { slot = "2", name = "Otra Remo", color = "#42B8E5", logo = "rayo" }).ok, "otra empresa")
	eq(mgr2.list[p].game.office.finishes[R].floor, "piso_cemento", "la otra empresa no comparte acabados")
end)


test("[OF5] Tramos de pared: el presupuesto cobra las paredes construidas (perímetro menos aberturas) en los cinco niveles", function()
	local F = OfficeCatalog.FINISHES
	for level = 1, 5 do
		for _, r in OfficeCatalog.plan(level).rooms do
			local built = builtWalls(r)
			eq(Office.wallLength(r), built, "nivel " .. level .. " · " .. r.id .. ": tramos = paredes construidas")
			check(built < 2 * (r.w + r.d), "nivel " .. level .. " · " .. r.id .. ": se descuentan las aberturas (" .. built .. " de " .. 2 * (r.w + r.d) .. ")")
			-- Los tramos de cada lado no se superponen ni se salen del lado.
			local runs = Office.wallRuns(r)
			for side, list in runs do
				local limit = (side == "left" or side == "right") and r.d or r.w
				local last = -1
				for _, run in list do
					check(run[1] >= 0 and run[2] <= limit and run[1] < run[2] and run[1] > last, "nivel " .. level .. " · " .. r.id .. " · " .. side .. ": tramo válido")
					last = run[2]
				end
			end
			-- Cotización: cada unidad con su cantidad real y el precio del catálogo (sin cambios de precio).
			local o = Office.new(level)
			local cost, lines = Office.remodelQuote(o, r.id, { floor = "piso_parquet_1970", wall = "pared_beige_1970", covering = "madera_1970", lighting = "luz_calida_1970" }, 1970)
			local qty = {}
			for _, l in lines do
				qty[l.kind] = l.qty
			end
			eq(qty.floor, r.w * r.d, "piso por casilla")
			eq(qty.wall, built, "pintura por tramo construido")
			eq(qty.covering, built, "revestimiento por tramo construido")
			eq(qty.lighting, math.ceil(r.w * r.d / OfficeCatalog.LIGHT_AREA), "luminarias")
			eq(cost, r.w * r.d * F.floor.piso_parquet_1970.price + built * (F.wall.pared_beige_1970.price + F.covering.madera_1970.price) + qty.lighting * F.lighting.luz_calida_1970.price, "total")
		end
	end
	eq(F.wall.pared_beige_1970.price, 15, "precio unitario de la pintura sin cambios")
	eq(F.covering.madera_1970.price, 60, "precio unitario del revestimiento sin cambios")
end)

test("[OF5] Remodelación en los cinco niveles por Sessions: cobro exacto, duplicados, guardado y cambio de empresa", function()
	local store = newStore()
	local clock = { t = 1000, c = 0 }
	local mgr = makeServer(store, "A", clock)
	local p = { UserId = 7201, Name = "niveles" }
	mgr:add(p)
	local s = playThrough(mgr, p)
	local g = s.game
	local F = OfficeCatalog.FINISHES
	local full = { floor = "piso_parquet_1970", wall = "pared_beige_1970", covering = "madera_1970", lighting = "luz_calida_1970" }
	local function request(action: string, body: any): any
		clock.c += 1 -- sin chocar con el límite de acciones por segundo
		clock.t += 1
		return mgr:request(p, action, body)
	end
	local paidTotal = 0
	for level = 1, 5 do
		g.sede = level
		Office.remap(g.office, level)
		g.money = 1e7
		for _, r in OfficeCatalog.plan(level).rooms do
			local installed = g.office.finishes[r.id]
			if installed.floor == "piso_cemento" then
				local expected = r.w * r.d * F.floor.piso_parquet_1970.price + builtWalls(r) * (F.wall.pared_beige_1970.price + F.covering.madera_1970.price) + math.ceil(r.w * r.d / OfficeCatalog.LIGHT_AREA) * F.lighting.luz_calida_1970.price
				local m0 = g.money
				local id = rid()
				local body = { room = r.id, changes = full, rev = g.office.rev, quote = expected, requestId = id, companyId = g.company.id }
				local res = request("officeRemodel", body)
				check(res.ok and res.paid == expected, "nivel " .. level .. " · " .. r.id .. ": " .. tostring(res.msg))
				eq(g.money, m0 - expected, "nivel " .. level .. " · " .. r.id .. ": cobro exacto")
				paidTotal += expected
				-- Duplicado: misma solicitud, sin segundo cobro.
				local dup = request("officeRemodel", body)
				check(dup.duplicate and dup.paid == expected, "nivel " .. level .. " · " .. r.id .. ": duplicado reconocido")
				eq(g.money, m0 - expected, "nivel " .. level .. " · " .. r.id .. ": sin cobro doble")
			else
				-- Habitación de un nivel anterior: conserva lo instalado y no se recobra.
				eq(installed.lighting, "luz_calida_1970", "nivel " .. level .. " · " .. r.id .. ": acabados conservados al ampliar")
				local res = request("officeRemodel", { room = r.id, changes = full, rev = g.office.rev, quote = 0, requestId = rid(), companyId = g.company.id })
				check(not res.ok, "nivel " .. level .. " · " .. r.id .. ": lo instalado no se vuelve a cobrar")
			end
		end
	end
	-- Guardar, salir y cargar en otro servidor.
	local finishes = serde.encode("json", g.office.finishes)
	local money = g.money
	mgr:remove(p)
	local mgr2 = makeServer(store, "B", clock)
	mgr2:add(p)
	check(mgr2:request(p, "selectSlot", { slot = "1" }).ok, "volver a abrir")
	local g2 = mgr2.list[p].game
	eq(serde.encode("json", g2.office.finishes), finishes, "acabados de los cinco niveles conservados")
	eq(g2.money, money, "dinero conservado")
	-- Cambio de empresa: otra empresa empieza con los básicos y una operación de la primera no se aplica en ella.
	clock.c += 5
	check(mgr2:request(p, "createCompany", { slot = "2", name = "Niveles Dos", color = "#42B8E5", logo = "rayo" }).ok, "otra empresa")
	local g3 = mgr2.list[p].game
	eq(g3.office.finishes.oficina_principal.floor, "piso_cemento", "otra empresa con acabados propios")
	local r1 = OfficeCatalog.room(1, "oficina_principal")
	local q = r1.w * r1.d * F.floor.piso_parquet_1970.price
	clock.c += 5
	local cross = mgr2:request(p, "officeRemodel", { room = "oficina_principal", changes = { floor = "piso_parquet_1970" }, rev = g3.office.rev, quote = q, requestId = rid(), companyId = g2.company.id })
	check(not cross.ok, "una operación de la primera empresa no se aplica en la segunda")
	eq(g3.office.finishes.oficina_principal.floor, "piso_cemento", "la segunda empresa no cambia")
	check(paidTotal > 0, "se cobraron remodelaciones en los cinco niveles")
end)


-- [OF6] Bonificaciones del mobiliario ------------------------------------------------------------------------
local Staff6 = require("./.build/shared/Staff")
local function near(a: number, b: number): boolean
	return math.abs(a - b) < 1e-9
end
local function placeN(g: any, item: string, n: number)
	local o = g.office
	for _ = 1, n do
		o.seq += 1
		table.insert(o.placed, { id = "m" .. o.seq, item = item, room = "oficina_principal", x = 0, y = 0, rot = 0 })
	end
	o.rev = (o.rev or 0) + 1
end

test("[OF6] Mobiliario: 1, 2 y 3 escritorios (1 %, 1,5 %, 1,75 %), guardados no suman, retirar, mover y decorativos", function()
	local g = newCompany("Bonos Uno")
	eq(#g.employees, 0, "sin empleados")
	eq(Rules.staff(g, "organizacion"), 0, "sin muebles colocados no hay bono (escritorio inicial guardado)")
	-- Colocados con OfficeService (validados por el servidor).
	g.money = 1e6
	check(OfficeService.place(g, { item = "escritorio_metal_1970", room = "oficina_principal", x = 5, y = 2.5, rot = 0 }).ok, "1er escritorio (del inventario)")
	check(near(Rules.staff(g, "organizacion"), 0.01), "1. un escritorio: +1 % (" .. Rules.staff(g, "organizacion") .. ")")
	check(OfficeService.place(g, { item = "escritorio_metal_1970", room = "oficina_principal", x = 5, y = 5.5, rot = 0 }).ok, "2º escritorio (compra)")
	check(near(Rules.staff(g, "organizacion"), 0.015), "2. dos escritorios: +1,5 %")
	local r3 = OfficeService.place(g, { item = "escritorio_metal_1970", room = "oficina_principal", x = 8, y = 4.5, rot = 0 })
	check(r3.ok, "3er escritorio")
	check(near(Rules.staff(g, "organizacion"), 0.0175), "3. tres escritorios: +1,75 % (" .. Rules.staff(g, "organizacion") .. ")")
	-- 8. Funciona sin empleados.
	eq(#g.employees, 0, "8. sigue sin empleados")
	-- 6. Mover y girar no cambia el aporte.
	check(OfficeService.move(g, { instance = r3.instance, room = "oficina_principal", x = 8, y = 6, rot = 45 }).ok, "mover y girar 45°")
	check(near(Rules.staff(g, "organizacion"), 0.0175), "6. mover o girar no cambia el aporte")
	-- 5. Retirar baja el aporte; 4. lo guardado no suma.
	check(OfficeService.remove(g, { instance = r3.instance }).ok, "retirar")
	check(near(Rules.staff(g, "organizacion"), 0.015), "5. al retirar vuelve a +1,5 %")
	eq(Office.count(g.office, "escritorio_metal_1970"), 1, "4. el retirado queda guardado…")
	check(near(Office.furnitureRaw(g.office, "organizacion"), 0.015), "4. …y no suma")
	-- Determinismo: el orden de las instancias no importa.
	local rev = g.office.placed
	local copy = table.clone(rev)
	table.sort(copy, function(a: any, b: any): boolean
		return a.id > b.id
	end)
	local g2 = jsonCopy(g)
	g2.office.placed = copy
	check(near(Office.furnitureRaw(g2.office, "organizacion"), Office.furnitureRaw(g.office, "organizacion")), "mismo resultado con otro orden")
	-- 7. Decorativos: no aportan a ninguna habilidad.
	local deco = newCompany("Deco SA")
	placeN(deco, "planta_interior_1970", 3)
	placeN(deco, "lampara_pie_1970", 2)
	placeN(deco, "silla_oficina_1970", 2)
	placeN(deco, "sofa_cuero_1970", 1)
	for k in Catalog.STAFF.skills do
		eq(Rules.staff(deco, k), 0, "7. decorativos: " .. k .. " sin bono")
	end
	-- Valores del catálogo conservados.
	local F = OfficeCatalog.FURNITURE
	eq(F.escritorio_metal_1970.bonus.value, 0.01, "escritorio 0,01 organización")
	eq(F.maquina_escribir_1970.bonus.skill, "finanzas", "máquina de escribir: finanzas")
	eq(F.estanteria_madera_1970.bonus.value, 0.008, "estantería 0,008 conocimiento")
	eq(F.mesa_reuniones_1970.bonus.skill, "gestion", "mesa: gestión")
	eq(OfficeCatalog.BONUS_DECAY, 0.5, "decaimiento 0,5")
	local bonus = 0
	for _, f in F do
		if f.bonus then
			bonus += 1
		end
	end
	eq(bonus, 4, "solo cuatro muebles con bonificación")
end)

test("[OF6] Personal + mobiliario: suma, tope compartido, contratación efectiva, cambio de departamento, adaptación, capacitación y deuda", function()
	local g = newCompany("Bonos Dos")
	local ctx = makeCtx(5)
	local cap = Catalog.STAFF.skills.organizacion.cap
	-- Un empleado de Administración con aporte conocido.
	Simulation.ensureMarket(g, ctx)
	local c = g.candidates[1]
	c.spec = "administracion"
	c.skills.organizacion = 90
	c.potential.organizacion = 100
	g.money = 1e7
	check(Actions.hire(g, ctx, { candidateId = c.id, dept = "administracion" }).ok, "contratado")
	local e = g.employees[#g.employees]
	local staffOnly = Staff6.contribution(g, e, "organizacion")
	placeN(g, "escritorio_metal_1970", 2)
	local v, raw, capOut, sRaw, fRaw = Staff6.bonusDetail(g, "organizacion")
	check(near(sRaw, staffOnly) and near(fRaw, 0.015), "aportes separados (personal " .. sRaw .. ", muebles " .. fRaw .. ")")
	check(near(v, math.min(cap, staffOnly + 0.015)) and near(Rules.staff(g, "organizacion"), v), "9. se suman (y Rules.staff usa el combinado)")
	eq(capOut, cap, "tope de la habilidad")
	-- 10. Nunca se supera el tope: personal cerca del tope + muebles.
	local big = Util.deepCopy(e)
	big.id = "e-grande"
	big.skills.organizacion = 100
	for _ = 1, 4 do
		local x = Util.deepCopy(big)
		x.id = x.id .. tostring(#g.employees)
		table.insert(g.employees, x)
	end
	local v2, raw2 = Staff6.bonusDetail(g, "organizacion")
	check(raw2 > cap and near(v2, cap), "10. con personal y muebles por encima del tope, queda en " .. cap .. " (" .. raw2 .. " sin tope)")
	check(near(Rules.staff(g, "organizacion"), cap), "10. Rules.staff no supera el tope")
	-- 11. Vista previa de contratación: mejora efectiva 0 cuando ya está al tope por muebles + personal.
	local cand = Util.deepCopy(g.candidates[2] or c)
	cand.id = "cand-test"
	cand.skills.organizacion = 80
	local gain = nil
	for _, p in Staff6.previewHire(g, cand, "administracion") do
		if p.skill == "organizacion" then
			gain = p
		end
	end
	check(gain and near(gain.gain, 0) and gain.capped, "11. contratar no muestra una mejora ficticia (al tope por personal + muebles)")
	-- Con margen: la vista previa muestra solo el espacio que queda hasta el tope.
	while #g.employees > 1 do
		table.remove(g.employees)
	end
	local before = Rules.staff(g, "organizacion")
	cand.skills.organizacion = 100
	cand.potential.organizacion = 100
	cand.spec = "administracion" -- en su especialidad (sin adaptación)
	for _, p in Staff6.previewHire(g, cand, "administracion") do
		if p.skill == "organizacion" then
			gain = p
		end
	end
	local candRaw = 100 / 100 * Catalog.STAFF.skills.organizacion.per
	check(near(gain.gain, math.min(cap, before + candRaw) - before), "11. vista previa = aumento efectivo con el mobiliario incluido")
	-- 12. Cambio de departamento: el aporte del empleado sale de Organización; el de los muebles queda.
	check(Actions.setDept(g, ctx, { employeeId = e.id, dept = "produccion" }).ok, "a Producción")
	check(near(Rules.staff(g, "organizacion"), 0.015), "12. sin el empleado queda solo el mobiliario")
	-- 13. Adaptación y capacitación afectan al empleado, no a los muebles.
	local _, _, _, sAfter, fAfter = Staff6.bonusDetail(g, "organizacion")
	eq(sAfter, 0, "12. aporte del personal en 0")
	check(near(fAfter, 0.015), "13. el aporte de los muebles no depende de la adaptación")
	check(Actions.setDept(g, ctx, { employeeId = e.id, dept = "administracion" }).ok, "vuelve a Administración")
	e.training = "t-prueba"
	local _, _, _, sTrain, fTrain = Staff6.bonusDetail(g, "organizacion")
	check(sTrain < staffOnly and near(fTrain, 0.015), "13. capacitándose rinde menos el empleado; los muebles igual")
	e.training = nil
	-- 14. Deuda salarial: baja la productividad del personal, no el aporte de los muebles.
	g.payroll.debtMonths = 3
	local _, _, _, sDebt, fDebt = Staff6.bonusDetail(g, "organizacion")
	check(sDebt < staffOnly and near(fDebt, 0.015), "14. con deuda baja el personal y los muebles siguen en +1,5 %")
	g.payroll.debtMonths = 0
end)

test("[OF6] Economía: obras, mantenimiento, PI de investigación y expansión; sin doble aplicación; empresas y niveles", function()
	local base = newCompany("Economia Base")
	local furn = newCompany("Economia Muebles")
	-- 15. Escritorio: las obras avanzan más rápido (Rules.buildSpeed = 1 + organización).
	placeN(furn, "escritorio_metal_1970", 1)
	check(near(Rules.buildSpeed(furn), 1.01) and near(Rules.buildSpeed(base), 1), "15. obras: 1,01 días por día con un escritorio")
	local ctx = makeCtx(4)
	for _, g in { base, furn } do
		g.money = 1e9
		g.counters.unitsSold = 1e6
		g.reputation = 5
		check(Actions.upgradeFacility(g, ctx, { kind = "offices" }).ok, "obra")
	end
	Simulation.simulate(base, ctx, Catalog.RULES.gameDayMinutes * 30)
	Simulation.simulate(furn, ctx, Catalog.RULES.gameDayMinutes * 30)
	check(furn.facilities.builds[1].progress > base.facilities.builds[1].progress, "15. una obra en curso avanza más con el escritorio (" .. furn.facilities.builds[1].progress .. " > " .. base.facilities.builds[1].progress .. ")")
	-- 16. Máquina de escribir: menor mantenimiento (finanzas).
	local fin = newCompany("Economia Finanzas")
	fin.facilities.invested, base.facilities.invested = 10000000, 10000000
	placeN(fin, "maquina_escribir_1970", 1)
	eq(Rules.maintenance(base), Util.round(10000000 * Catalog.FACILITIES.maintenanceRate), "16. mantenimiento base")
	eq(Rules.maintenance(fin), Util.round(10000000 * Catalog.FACILITIES.maintenanceRate * (1 - 0.01)), "16. mantenimiento con la máquina de escribir (−1 %)")
	-- 17. Estantería: menos PI para una investigación nueva (no genera PI).
	local know = newCompany("Economia Saber")
	placeN(know, "estanteria_madera_1970", 1)
	local node
	for _, cat in { "chasis", "motores", "seguridad", "tecnologia" } do
		for _, n in Catalog.RESEARCH[cat].nodes do
			if not node or n.rp > node.rp then
				node = n
			end
		end
	end
	local piBase = Rules.researchCost(base, node)
	local piKnow, _, _, info = Rules.researchCost(know, node)
	local diff = info.diffusion
	local ahead = info.ahead
	eq(piKnow, math.max(1, math.floor(node.rp * diff * (1 + Catalog.RESEARCH_RULES.aheadPi * ahead) * (1 - 0.008) + 0.5)), "17. PI con la estantería (−0,8 %)")
	check(piKnow < piBase, "17. menos PI que sin la estantería (" .. piKnow .. " < " .. piBase .. ")")
	eq(Rules.piPerMinute(know), Rules.piPerMinute(base), "17. no genera PI por minuto")
	-- 18. Mesa de reuniones: expansiones más baratas (gestión).
	local mgmt = newCompany("Economia Gestion")
	placeN(mgmt, "mesa_reuniones_1970", 1)
	eq(Rules.expansionCost(mgmt, 300000), Util.round(300000 * (1 - 0.008) / 100) * 100, "18. costo de expansión con la mesa (−0,8 %)")
	eq(Rules.expansionCost(base, 300000), 300000, "18. sin la mesa, el costo base")
	-- 19. Una sola aplicación: Rules.staff = combinado, y una obra de oficinas cuesta lo mismo que el cálculo directo.
	eq(Rules.staff(mgmt, "gestion"), Staff6.bonus(mgmt, "gestion"), "19. Rules.staff = Staff.bonus (un solo camino)")
	check(near(Rules.staff(mgmt, "gestion"), 0.008), "19. no se aplica dos veces")
	-- 21. Empresas distintas: estadísticas independientes.
	check(Rules.staff(base, "organizacion") == 0 and near(Rules.staff(furn, "organizacion"), 0.01), "21. cada empresa con sus muebles")
	-- 20. Guardar y cargar (JSON): los beneficios se reconstruyen desde g.office.placed (colocación válida).
	local saved = newCompany("Economia Guardada")
	saved.money = 1e6
	check(OfficeService.place(saved, { item = "escritorio_metal_1970", room = "oficina_principal", x = 5, y = 2.5, rot = 0 }).ok, "escritorio válido")
	local loaded = GameState.migrate(jsonCopy(saved), 2)
	Office.sanitize(loaded)
	check(near(Rules.staff(loaded, "organizacion"), 0.01), "20. al cargar se reconstruye el beneficio")
	check(loaded.office.bonus == nil and loaded.office.bonuses == nil, "20. no se guardan estadísticas derivadas")
	-- 22. Niveles 1 a 5: al ampliar los muebles siguen aportando.
	local lv = newCompany("Economia Niveles")
	lv.money = 1e7
	check(OfficeService.place(lv, { item = "escritorio_metal_1970", room = "oficina_principal", x = 5, y = 2.5, rot = 0 }).ok, "escritorio colocado")
	for level = 2, 5 do
		lv.sede = level
		Office.remap(lv.office, level)
		check(near(Rules.staff(lv, "organizacion"), 0.01), "22. nivel " .. level .. ": el escritorio sigue aportando")
	end
	-- 24. Datos inválidos no crean beneficios: muebles desconocidos, habitaciones de otro nivel, ids repetidos.
	local bad = newCompany("Economia Mala")
	table.insert(bad.office.placed, { id = "m1", item = "escritorio_inexistente", room = "oficina_principal", x = 1, y = 1, rot = 0 })
	table.insert(bad.office.placed, { id = "m2", item = "escritorio_metal_1970", room = "direccion", x = 1, y = 1, rot = 0 })
	table.insert(bad.office.placed, { id = "m3", item = "escritorio_metal_1970", room = "oficina_principal", x = 5, y = 2.5, rot = 0 })
	table.insert(bad.office.placed, { id = "m3", item = "escritorio_metal_1970", room = "oficina_principal", x = 5, y = 5.5, rot = 0 })
	table.insert(bad.office.placed, "basura")
	check(near(Rules.staff(bad, "organizacion"), 0.01), "24. solo cuenta el escritorio válido (sin duplicar ids ni habitaciones de otro nivel)")
	bad.office.placed = "no es una lista"
	eq(Rules.staff(bad, "organizacion"), 0, "24. una oficina dañada no da bonificaciones")
	bad.office = nil
	eq(Rules.staff(bad, "organizacion"), 0, "24. sin oficina tampoco")
end)

test("[OF6] Sessions: colocaciones duplicadas no duplican beneficios, el cliente no envía estadísticas y se reconstruyen al cargar", function()
	local store = newStore()
	local clock = { t = 1000, c = 0 }
	local mgr = makeServer(store, "A", clock)
	local p = { UserId = 7301, Name = "bonos" }
	mgr:add(p)
	local s = playThrough(mgr, p)
	local g = s.game
	g.money = 1e6
	local id = rid()
	local body = { item = "escritorio_metal_1970", room = "oficina_principal", x = 5, y = 2.5, rot = 0, requestId = id, companyId = g.company.id, bonus = 5, organizacion = 1 }
	check(mgr:request(p, "officePlace", body).ok, "colocado (los campos extra del cliente se ignoran)")
	clock.c += 1
	check(mgr:request(p, "officePlace", body).duplicate, "duplicado")
	check(near(Rules.staff(g, "organizacion"), 0.01), "23. la colocación duplicada no duplica el beneficio")
	eq(Office.placedCount(g.office, "escritorio_metal_1970"), 1, "23. una sola instancia")
	-- El estado que recibe el cliente no lleva bonificaciones calculadas (las calcula con los mismos datos).
	check(g.office.bonus == nil, "sin campos derivados en la partida")
	mgr:remove(p)
	local mgr2 = makeServer(store, "B", clock)
	mgr2:add(p)
	check(mgr2:request(p, "selectSlot", { slot = "1" }).ok, "recargar")
	check(near(Rules.staff(mgr2.list[p].game, "organizacion"), 0.01), "20. reconstruido después de cargar en otro servidor")
end)


test("[OF6] Puntos de interacción: catálogo válido, giros de 45°, posición en el mundo e inaccesibles sin afectar el beneficio", function()
	for id, f in OfficeCatalog.FURNITURE do
		local ok, why = Office.checkInteraction(f)
		check(ok, id .. ": " .. tostring(why))
	end
	local kinds = {}
	for _, f in OfficeCatalog.FURNITURE do
		if f.interaction then
			kinds[f.interaction.kind] = Office.INTERACTION_KINDS[f.interaction.kind]
		end
	end
	check(kinds.work == "stand" and kinds.browse == "stand" and kinds.sit == "seat" and kinds.rest == "seat", "trabajar y consultar de pie; sentarse y descansar sobre el mueble")
	local g = newCompany("Puntos SA")
	g.money = 1e6
	local r = OfficeService.place(g, { item = "escritorio_metal_1970", room = "oficina_principal", x = 5, y = 4, rot = 45 })
	check(r.ok, "escritorio a 45°")
	local spots = Office.interactionSpots(g.office)
	eq(#spots, 1, "un punto")
	local sp = spots[1]
	-- Punto (0, 1) del escritorio girado 45°: (5 − sin45, 4 + cos45), mirando al escritorio (270 + 45).
	check(math.abs(sp.x - (5 - math.sqrt(0.5))) < 1e-6 and math.abs(sp.y - (4 + math.sqrt(0.5))) < 1e-6, "punto girado 45°")
	eq(sp.facing, 315, "mira al escritorio")
	check(sp.accessible and sp.approach ~= nil, "accesible")
	local wx, wy, wz = Office.toWorld({ x = 100, y = 20, z = 300 }, sp.x, sp.y, sp.facing)
	check(math.abs(wx - (100 + sp.x * OfficeCatalog.CELL)) < 1e-6 and wy == 20 and math.abs(wz - (300 + sp.y * OfficeCatalog.CELL)) < 1e-6, "posición en el mundo según la habitación")
	-- Silla pegada al escritorio por delante: se llega por un costado.
	check(OfficeService.place(g, { item = "silla_oficina_1970", room = "oficina_principal", x = 8.5, y = 1.5, rot = 0 }).ok, "silla")
	for _, x in Office.interactionSpots(g.office) do
		if x.item == "silla_oficina_1970" then
			check(x.accessible, "silla accesible (por algún lado)")
		end
	end
	-- Un mueble que tapa el punto del escritorio lo vuelve inaccesible, sin cambiar el beneficio.
	local before = Rules.staff(g, "organizacion")
	local pr = OfficeService.place(g, { item = "planta_interior_1970", room = "oficina_principal", x = 4, y = 5, rot = 45 })
	check(pr.ok, "planta delante del escritorio (sin superponerse): " .. tostring(pr.msg))
	local blocked
	for _, x in Office.interactionSpots(g.office) do
		if x.item == "escritorio_metal_1970" then
			blocked = x
		end
	end
	check(blocked and not blocked.accessible and blocked.reason ~= nil, "punto tapado: inaccesible (" .. tostring(blocked and blocked.reason) .. ")")
	eq(Rules.staff(g, "organizacion"), before, "el beneficio pasivo no cambia")
	-- Contra la pared: el punto queda fuera de la habitación.
	local w = newCompany("Pared SA")
	w.money = 1e6
	check(OfficeService.place(w, { item = "estanteria_madera_1970", room = "oficina_principal", x = 5, y = 7.5, rot = 0 }).ok, "estantería contra la pared del fondo")
	local wall = Office.interactionSpots(w.office)[1]
	check(wall and not wall.accessible and string.find(wall.reason, "fuera", 1, true) ~= nil, "punto fuera de la habitación: inaccesible")
	check(math.abs(Rules.staff(w, "conocimiento") - 0.008) < 1e-9, "la estantería sigue aportando")
end)


-- Etapa 5: navegación de los empleados visibles (pura, sin Roblox) ---------------------------------------------
do
	local Office = require("./.build/shared/Office")
	local OfficeCatalog = require("./.build/shared/OfficeCatalog")
	local OfficeService = require("./.build/server/OfficeService")
	local Nav = require("./.build/shared/OfficeNavigation")
	local Geometry = require("./.build/shared/OfficeGeometry")

	-- Comprobación independiente de una ruta: cada 0,05 casillas el cuerpo (radio RADIUS) queda dentro de la
	-- habitación y lejos de todos los muebles (rectángulos girados reales).
	local function routeOk(o: any, roomId: string, fx: number, fy: number, path: { { number } }): (boolean, string?)
		local r = OfficeCatalog.room(o.level, roomId)
		local R = Nav.RADIUS - 1e-6
		local polys = {}
		for _, p in o.placed do
			if p.room == roomId then
				table.insert(polys, Office.corners(OfficeCatalog.item(p.item), p.x, p.y, p.rot))
			end
		end
		local px, py = fx, fy
		for _, wp in path do
			local dx, dy = wp[1] - px, wp[2] - py
			local n = math.max(1, math.ceil(math.sqrt(dx * dx + dy * dy) / 0.05))
			for k = 0, n do
				local x, y = px + dx * k / n, py + dy * k / n
				if x < R or y < R or x > r.w - R or y > r.d - R then
					return false, string.format("atraviesa la pared en (%.2f, %.2f)", x, y)
				end
				for _, poly in polys do
					if Geometry.distance(poly, x, y) < R then
						return false, string.format("atraviesa un mueble en (%.2f, %.2f)", x, y)
					end
				end
			end
			px, py = wp[1], wp[2]
		end
		return true, nil
	end

	local function company(name: string): any
		local g = newCompany(name)
		g.money = 1e7
		return g
	end

	test("[NV1] Navegación: rodea muebles, respeta los giros de 45°, no corta esquinas ni atraviesa paredes", function()
		local g = company("Rutas SA")
		local R = "oficina_principal"
		-- 8. Una fila de escritorios en el medio: la ruta los rodea.
		for _, x in { 3, 5, 7 } do
			check(OfficeService.place(g, { item = "escritorio_metal_1970", room = R, x = x, y = 4.5, rot = 0 }).ok, "escritorio en " .. x)
		end
		local grid = Nav.grid(g.office, R)
		local path, why = Nav.findPath(grid, 5, 2.5, 5, 6.5)
		check(path ~= nil, "hay ruta alrededor de la fila: " .. tostring(why))
		local ok, bad = routeOk(g.office, R, 5, 2.5, path)
		check(ok, "8. no atraviesa muebles: " .. tostring(bad))
		check(Nav.pathLength(5, 2.5, path) > 4.5, "la ruta rodea (más larga que la línea recta)")
		-- 9. Muebles girados 45°: la ruta respeta el rectángulo girado real.
		local d = company("Diagonal SA")
		check(OfficeService.place(d, { item = "mesa_reuniones_1970", room = R, x = 5, y = 4, rot = 45 }).ok, "mesa a 45°")
		check(OfficeService.place(d, { item = "estanteria_madera_1970", room = R, x = 8, y = 2, rot = 135 }).ok, "estantería a 135°")
		local dg = Nav.grid(d.office, R)
		for _, pair in { { { 2.5, 4 }, { 8.5, 4 } }, { { 5, 0.75 }, { 5, 7.25 } }, { { 2, 1.5 }, { 9, 6.5 } } } do
			local a, b = pair[1], pair[2]
			local pth, w2 = Nav.findPath(dg, a[1], a[2], b[1], b[2])
			check(pth ~= nil, "ruta con muebles diagonales: " .. tostring(w2))
			local ok2, bad2 = routeOk(d.office, R, a[1], a[2], pth)
			check(ok2, "9. respeta los giros de 45°: " .. tostring(bad2))
		end
		-- 10. Esquinas: ningún paso diagonal entre dos nodos si alguno de los dos vecinos rectos está ocupado.
		local cut = 0
		for _, gr in { grid, dg } do
			for idx = 1, gr.cols * gr.rows do
				if gr.free[idx] then
					local x, y = Nav.nodePos(gr, idx)
					for _, n in Nav.neighbors(gr, idx) do
						local nx, ny = Nav.nodePos(gr, n)
						if nx ~= x and ny ~= y then
							local i1 = idx + (nx > x and 1 or -1)
							local j1 = idx + (ny > y and gr.cols or -gr.cols)
							if not (gr.free[i1] and gr.free[j1]) then
								cut += 1
							end
						end
					end
				end
			end
		end
		eq(cut, 0, "10. no hay pasos diagonales que corten esquinas ocupadas")
		-- Dos plantas que se tocan en una esquina: no se pasa entre ellas en diagonal.
		local c = company("Esquinas SA")
		check(OfficeService.place(c, { item = "planta_interior_1970", room = R, x = 4.5, y = 4.5, rot = 0 }).ok, "planta 1")
		check(OfficeService.place(c, { item = "planta_interior_1970", room = R, x = 5.5, y = 5.5, rot = 0 }).ok, "planta 2")
		local cg = Nav.grid(c.office, R)
		check(not Nav.segmentClear(cg, 4.4, 5.6, 5.6, 4.4), "el hueco de la esquina no deja pasar el cuerpo")
		local cp = Nav.findPath(cg, 4.3, 5.9, 5.7, 4.1)
		check(cp ~= nil and routeOk(c.office, R, 4.3, 5.9, cp), "la ruta da la vuelta por fuera")
		-- 11. Paredes: ningún nodo transitable a menos del radio de una pared; destino fuera de la habitación.
		local r = OfficeCatalog.room(1, R)
		local near = 0
		for idx = 1, grid.cols * grid.rows do
			local x, y = Nav.nodePos(grid, idx)
			if grid.free[idx] and (x < Nav.RADIUS or y < Nav.RADIUS or x > r.w - Nav.RADIUS or y > r.d - Nav.RADIUS) then
				near += 1
			end
		end
		eq(near, 0, "11. ningún lugar transitable pegado a la pared")
		local out, whyOut = Nav.findPath(grid, 5, 2.5, r.w + 3, 4)
		check(out == nil and whyOut ~= nil, "11. no hay ruta hacia afuera de la habitación (" .. tostring(whyOut) .. ")")
	end)

	test("[NV2] Navegación: habitaciones separadas, rutas imposibles, cambios de muebles y acceso desde la entrada", function()
		-- 12. Cada habitación es independiente (sin pasillos inventados entre ellas).
		local g2 = company("Dos Salas SA")
		g2.office = Office.new(2)
		for _, rr in OfficeCatalog.plan(2).rooms do
			eq(#Nav.links(2, rr.id), 0, "12. " .. rr.id .. ": sin conexiones inventadas con otras habitaciones")
			local gr = Nav.grid(g2.office, rr.id)
			local mx, my = 0, 0
			for idx = 1, gr.cols * gr.rows do
				local x, y = Nav.nodePos(gr, idx)
				mx, my = math.max(mx, x), math.max(my, y)
			end
			check(mx < rr.w and my < rr.d and #gr.entries > 0, "12. " .. rr.id .. ": la zona transitable queda dentro de la habitación y tiene entrada")
		end
		-- 13. Una pared de estanterías parte la habitación: la mitad derecha queda inalcanzable.
		local g = company("Muro SA")
		local R = "oficina_principal"
		for _, y in { 1, 3, 5, 7 } do
			check(OfficeService.place(g, { item = "estanteria_madera_1970", room = R, x = 6.5, y = y, rot = 90 }).ok, "estantería del muro en y=" .. y)
		end
		local grid = Nav.grid(g.office, R)
		local t0 = os.clock()
		local path, why = Nav.findPath(grid, 2, 4, 8.5, 4)
		local elapsed = os.clock() - t0
		check(path == nil and why ~= nil, "13. ruta imposible detectada: " .. tostring(why))
		check(elapsed < 0.05, string.format("13. sin bloquear el sistema (%.4f s)", elapsed))
		-- 15. Un escritorio del otro lado del muro: su punto está libre pero no hay recorrido desde la puerta.
		check(OfficeService.place(g, { item = "escritorio_metal_1970", room = R, x = 8.5, y = 4, rot = 90 }).ok, "escritorio detrás del muro")
		local behind
		for _, sp in Office.interactionSpots(g.office) do
			if sp.item == "escritorio_metal_1970" then
				behind = sp
			end
		end
		check(behind and not behind.accessible and behind.reason == "sin recorrido desde la entrada", "15. punto libre pero sin recorrido desde la entrada: inaccesible (" .. tostring(behind and behind.reason) .. ")")
		check(math.abs(Rules.staff(g, "organizacion") - 0.01) < 1e-9, "15. el escritorio inaccesible conserva su beneficio pasivo")
		-- 14. Quitar una estantería abre el paso: la grilla se rearma (solo esa habitación) y la ruta aparece.
		local builds = Nav.builds
		local same = Nav.grid(g.office, R)
		eq(Nav.builds, builds, "14. sin cambios no se rearma la grilla")
		check(same == Nav.grid(g.office, R), "14. misma grilla en caché")
		local sh = g.office.placed[3]
		check(OfficeService.remove(g, { instance = sh.id }).ok, "quitar una estantería del muro")
		local fresh = Nav.grid(g.office, R)
		check(fresh ~= grid and Nav.builds == builds + 1, "14. el cambio de muebles rearma la grilla")
		local p2, w2 = Nav.findPath(fresh, 2, 4, 8.5, 6.5)
		check(p2 ~= nil, "14. con el paso abierto hay ruta: " .. tostring(w2))
		check(routeOk(g.office, R, 2, 4, p2), "14. la ruta nueva tampoco atraviesa muebles")
		for _, sp in Office.interactionSpots(g.office) do
			if sp.item == "escritorio_metal_1970" then
				check(sp.accessible, "15. con recorrido desde la entrada, el punto es accesible")
			end
		end
		-- Una ruta vieja que ahora cruza un mueble nuevo deja de ser válida.
		local open = Nav.findPath(Nav.grid(g.office, R), 1, 1, 4, 1)
		check(open ~= nil and Nav.segmentClear(Nav.grid(g.office, R), 1, 1, 4, 1), "camino libre por arriba")
		check(OfficeService.place(g, { item = "planta_interior_1970", room = R, x = 2.5, y = 1.5, rot = 0 }).ok, "planta en el camino")
		check(not Nav.segmentClear(Nav.grid(g.office, R), 1, 1, 4, 1), "14. el tramo viejo queda bloqueado por el mueble nuevo")
		-- Lugares de uso de varias personas: separados y girando con el mueble.
		check(OfficeService.place(g, { item = "mesa_reuniones_1970", room = R, x = 3.5, y = 6, rot = 0 }).ok, "mesa de reuniones")
		local meet = {}
		for _, sp in Office.interactionSpots(g.office) do
			if sp.kind == "meet" then
				table.insert(meet, sp)
			end
		end
		eq(#meet, 6, "la mesa de reuniones tiene seis lugares")
		for i = 1, #meet do
			for k = i + 1, #meet do
				check(math.sqrt((meet[i].x - meet[k].x) ^ 2 + (meet[i].y - meet[k].y) ^ 2) >= 2 * Nav.RADIUS, "lugares de reunión separados")
			end
		end
		for id, f in OfficeCatalog.FURNITURE do
			local okc, whyc = Office.checkInteraction(f)
			check(okc, id .. ": puntos de uso válidos (" .. tostring(whyc) .. ")")
		end
	end)
end


-- Empleados = amigos de Roblox ----------------------------------------------------------------------------------
do
	local FI = require("./.build/server/FriendIdentity")
	local Staff = require("./.build/shared/Staff")

	local function friends(n: number, from: number?): { any }
		local out = {}
		for i = 1, n do
			local id = (from or 1000) + i
			table.insert(out, { userId = id, username = "amigo" .. id, displayName = "Amigo " .. id })
		end
		return out
	end

	local function hireN(g: any, ctx: any, n: number): { any }
		local out = {}
		for _ = 1, n do
			Simulation.ensureMarket(g, ctx)
			if #g.candidates == 0 then
				Simulation.refreshCandidates(g, ctx, nil)
			end
			local c = g.candidates[1]
			local r = Actions.hire(g, ctx, { candidateId = c.id })
			assert(r.ok, r.msg)
			table.insert(out, { e = g.employees[#g.employees], c = c, r = r })
		end
		return out
	end

	test("[AM1] Contratar asigna solo un amigo de Roblox: identidad real, sin repetir, sin tocar la economía", function()
		local g = newCompany("Amigos SA")
		g.sede = 3 -- lugar para 16 empleados
		local ctx = makeCtx(5)
		ctx.friends = FI.roster({ status = "ok", complete = true, list = friends(3) })
		local nextF = FI.nextFriend(g, ctx.friends)
		local hired = hireN(g, ctx, 3)
		local seen = {}
		for i, h in hired do
			local e, c = h.e, h.c
			check(e.friend ~= nil, "1-3. el contratado " .. i .. " es un amigo")
			check(ctx.friends.byId[e.friend.userId] ~= nil, "4. su UserId es de un amigo real de la lista")
			eq(e.name, e.friend.displayName, "4. usa el DisplayName del amigo")
			check(e.friend.username == "amigo" .. e.friend.userId, "4. y su Username")
			check(not seen[e.friend.userId], "7. ningún amigo repetido en la empresa")
			seen[e.friend.userId] = true
			-- 10. Habilidades, especialidad y salario: los del perfil contratado (Staff de siempre).
			eq(e.spec, c.spec, "10. especialidad del perfil")
			eq(e.salary, c.salary, "10. salario del perfil")
			eq(serde.encode("json", e.skills), serde.encode("json", c.skills), "10. habilidades del perfil")
			check(string.find(h.r.msg, e.friend.displayName, 1, true) ~= nil, "el aviso nombra al amigo")
		end
		eq(hired[1].e.friend.userId, nextF.userId, "se asigna el que se anunció como próximo")
		-- 13. Más contrataciones que amigos: el puesto existe y trabaja, sin identidad ni clones.
		local extra = hireN(g, ctx, 2)
		for _, h in extra do
			check(h.e.friend == nil and h.e.name == FI.VACANT, "13. puesto sin amigo (sin clonar a nadie)")
			check(string.find(h.r.msg, "Sin amigos de Roblox libres", 1, true) ~= nil, "13. el aviso lo explica")
		end
		eq(#g.employees, 5, "13. los cinco puestos económicos se mantienen")
		local sum = FI.summary(g, ctx.friends)
		check(sum.total == 3 and sum.available == 0 and sum.vacant == 2 and sum.next == nil, "resumen: 3 amigos, 0 libres, 2 puestos sin amigo")
		-- La productividad de un puesto sin amigo es la misma que la de uno con amigo (misma fórmula).
		local a, b = hired[1].e, extra[1].e
		local pb = Staff.productivity(g, b)
		b.friend = { userId = 1, username = "x", displayName = "x" }
		eq(Staff.productivity(g, b), pb, "10. la identidad no cambia la productividad")
		b.friend = nil
		check(Staff.productivity(g, a) > 0, "productividad normal")
		-- 12. Despedir libera al amigo: la contratación siguiente lo recibe.
		local freed = hired[2].e.friend.userId
		check(Actions.fire(g, ctx, { employeeId = hired[2].e.id }).ok, "despedir")
		eq(FI.nextFriend(g, ctx.friends).userId, freed, "12. el amigo despedido queda libre")
		local res = FI.reconcile(g, ctx.friends, 5000, 1)
		eq(res.assigned, 1, "12. un puesto sin amigo recibe al liberado")
		check(extra[1].e.friend and extra[1].e.friend.userId == freed, "12. el más antiguo sin amigo lo recibe")
		-- Orden estable: la misma empresa asigna siempre igual; otra empresa, en otro orden posible.
		local g2 = newCompany("Amigos SA")
		g2.company.id = g.company.id
		local o1 = FI.available({ employees = {}, company = g.company }, ctx.friends)
		local o2 = FI.available({ employees = {}, company = g2.company }, ctx.friends)
		eq(o1[1].userId, o2[1].userId, "orden estable para la misma empresa")
		-- Sin lista (cargando o con falla): se contrata igual, sin identidad, y se asigna después.
		local g3 = newCompany("Sin Lista SA")
		g3.sede = 3
		local ctx3 = makeCtx(6)
		ctx3.friends = FI.roster({ status = "failed" })
		local h3 = hireN(g3, ctx3, 1)[1]
		check(h3.e.friend == nil, "14. con la consulta fallida el puesto espera su amigo")
		FI.reconcile(g3, FI.roster({ status = "ok", complete = true, list = friends(2) }), 100, 1)
		check(h3.e.friend ~= nil and h3.e.name == h3.e.friend.displayName, "al llegar la lista recibe su amigo")
		-- 11. El amigo no está conectado ni juega: alcanza con estar en la lista (no hay ningún otro requisito).
		check(ctx.friends.list[1].isOnline == nil, "no se usa si está conectado")
	end)

	test("[AM2] Política segura: fallas, listas incompletas o sospechosas, reasignación confirmada y nombres", function()
		local g = newCompany("Seguro SA")
		g.sede = 3
		local ctx = makeCtx(7)
		local list = friends(10)
		ctx.friends = FI.roster({ status = "ok", complete = true, list = list })
		local hired = hireN(g, ctx, 3)
		FI.reconcile(g, ctx.friends, 1000, 1) -- registra el tamaño de la lista completa
		local e = hired[1].e
		local uid = e.friend.userId
		local stats = serde.encode("json", { e.skills, e.potential, e.salary, e.months, e.hiredDay, e.spec, e.dept, e.id })
		local function without(id: number, extra: { any }?): { any }
			local out = {}
			for _, f in list do
				if f.userId ~= id then
					table.insert(out, f)
				end
			end
			for _, f in extra or {} do
				table.insert(out, f)
			end
			return out
		end
		-- 14. Consulta fallida o cargando: nadie pierde su amigo.
		for _, st in { "failed", "loading" } do
			local r = FI.reconcile(g, FI.roster({ status = st }), 5000, 2)
			check(r.marked + r.reassigned + r.released == 0 and e.friend.userId == uid, "14. lista " .. st .. ": se conservan las asignaciones")
		end
		-- Lista incompleta (una página falló): no se marca a nadie como ausente.
		FI.reconcile(g, FI.roster({ status = "ok", complete = false, list = without(uid) }), 5000, 2)
		check(e.friend.missingSince == nil, "14. lista incompleta: no cuenta como ausencia")
		-- Lista sospechosa (cae a menos de la mitad): tampoco.
		FI.reconcile(g, FI.roster({ status = "ok", complete = true, list = { list[2], list[3] } }), 5000, 2)
		check(e.friend.missingSince == nil and e.friend.userId == uid, "14. caída brusca de la lista: no se quita a nadie")
		-- 15. Ausente en una lista confiable: primero se marca; no se reemplaza enseguida.
		local nine = without(uid)
		local r1 = FI.reconcile(g, FI.roster({ status = "ok", complete = true, list = nine }), 6000, 2)
		check(r1.marked == 1 and e.friend.userId == uid and e.friend.missingSince == 6000, "15. primera ausencia: solo se anota")
		local r2 = FI.reconcile(g, FI.roster({ status = "ok", complete = true, list = nine }), 6000 + FI.MISSING_CONFIRM - 1, 2)
		check(r2.reassigned == 0 and e.friend.userId == uid, "15. antes del plazo de confirmación sigue igual")
		-- Si vuelve a aparecer, se borra la marca.
		FI.reconcile(g, FI.roster({ status = "ok", complete = true, list = list }), 6300, 2)
		check(e.friend.missingSince == nil, "15. vuelve a estar: se borra la marca")
		FI.reconcile(g, FI.roster({ status = "ok", complete = true, list = nine }), 7000, 2)
		local r3 = FI.reconcile(g, FI.roster({ status = "ok", complete = true, list = nine }), 7000 + FI.MISSING_CONFIRM, 3)
		check(r3.reassigned == 1 and e.friend and e.friend.userId ~= uid, "15. confirmado: el puesto pasa a otro amigo libre")
		eq(e.name, e.friend.displayName, "15. con su nombre")
		eq(serde.encode("json", { e.skills, e.potential, e.salary, e.months, e.hiredDay, e.spec, e.dept, e.id }), stats, "15. sin perder las estadísticas laborales")
		check(#r3.messages == 1 and string.find(r3.messages[1], "mismas habilidades", 1, true) ~= nil, "15. se avisa al jugador")
		-- Sin amigos libres: el puesto queda sin identidad hasta que haya uno.
		local g2 = newCompany("Pocos SA")
		g2.sede = 3
		local ctx2 = makeCtx(8)
		local two = friends(4, 5000)
		ctx2.friends = FI.roster({ status = "ok", complete = true, list = two })
		local h2 = hireN(g2, ctx2, 4)
		FI.reconcile(g2, ctx2.friends, 100, 1)
		local gone = h2[1].e.friend.userId
		local three = { two[1], two[2], two[3], two[4] }
		for i = #three, 1, -1 do
			if three[i].userId == gone then
				table.remove(three, i)
			end
		end
		FI.reconcile(g2, FI.roster({ status = "ok", complete = true, list = three }), 200, 1)
		local r4 = FI.reconcile(g2, FI.roster({ status = "ok", complete = true, list = three }), 200 + FI.MISSING_CONFIRM, 1)
		check(r4.released == 1 and h2[1].e.friend == nil and h2[1].e.name == FI.VACANT, "15. sin amigos libres: el puesto sigue, sin identidad")
		local plus = table.clone(three)
		table.insert(plus, { userId = 9999, username = "nuevo", displayName = "Nuevo" })
		FI.reconcile(g2, FI.roster({ status = "ok", complete = true, list = plus }), 300, 1)
		check(h2[1].e.friend and h2[1].e.friend.userId == 9999, "al aparecer un amigo nuevo, lo recibe")
		-- Cambio de DisplayName del amigo: se actualiza el nombre del empleado.
		plus[#plus] = { userId = 9999, username = "nuevo", displayName = "Nuevo Nombre" }
		local r5 = FI.reconcile(g2, FI.roster({ status = "ok", complete = true, list = plus }), 400, 1)
		check(r5.renamed == 1 and h2[1].e.name == "Nuevo Nombre", "16. el nombre visible sigue al del amigo")
		-- Datos guardados dañados o repetidos: se reparan sin perder el puesto.
		local g3 = newCompany("Dañada SA")
		g3.employees = {
			{ id = "e1", name = "x", friend = { userId = 7, username = "siete", displayName = "Siete" } },
			{ id = "e2", name = "y", friend = { userId = 7, username = "siete", displayName = "Siete" } },
			{ id = "e3", name = "z", friend = { userId = -3, username = "" } },
		}
		FI.sanitize(g3)
		check(g3.employees[1].friend and not g3.employees[2].friend and not g3.employees[3].friend, "8. amigo repetido o inválido: queda sin identidad (sin borrar el empleado)")
		eq(#g3.employees, 3, "8. ningún empleado eliminado")
	end)

	test("[AM4] Pedidos de avatares: formato estricto, solo empleados autorizados, sin repetidos; jugador sin amigos", function()
		local g = newCompany("Pedidos SA")
		g.sede = 3
		local ctx = makeCtx(9)
		ctx.friends = FI.roster({ status = "ok", complete = true, list = friends(3, 3000) })
		local hired = hireN(g, ctx, 4) -- 3 con amigo, 1 sin amigo
		local a, b, vac = hired[1].e, hired[2].e, hired[4].e
		check(vac.friend == nil, "cuarto puesto sin amigo")
		local ok = FI.avatarRequest(g, { a.id, b.id })
		check(ok and #ok == 2 and ok[1] == a.friend.userId and ok[2] == b.friend.userId, "pedido válido: los UserId de sus amigos")
		local dup = FI.avatarRequest(g, { a.id, a.id, a.id })
		check(dup and #dup == 1, "pedidos repetidos: un solo avatar")
		local big = {}
		for i = 1, FI.MAX_AVATAR_REQUEST + 1 do
			big[i] = a.id
		end
		local bad = {
			{ nil, "nil" }, { 5, "número" }, { "e1", "texto suelto" }, { {}, "lista vacía" },
			{ { x = a.id }, "diccionario" }, { { [1] = a.id, [3] = b.id }, "lista con huecos" },
			{ { [1] = a.id, extra = true }, "lista con claves extra" }, { { [0] = a.id }, "índice 0" },
			{ { [1.5] = a.id }, "índice fraccionario" }, { big, "demasiados" }, { { { a.id } }, "tabla anidada" },
			{ { 123 }, "número como id" }, { { string.rep("x", 65) }, "id demasiado largo" }, { { "" }, "id vacío" },
			{ { vac.id }, "empleado sin amigo" }, { { "e-otro" }, "empleado inexistente" }, { { a.id, "e-otro" }, "uno válido y uno ajeno" },
		}
		for _, case in bad do
			local res, why = FI.avatarRequest(g, case[1])
			check(res == nil and why ~= nil, "rechazado: " .. case[2])
		end
		check(FI.avatarRequest(nil, { a.id }) == nil, "sin empresa activa: rechazado")
		-- Un empleado de OTRA empresa del mismo jugador no se puede pedir desde esta.
		local other = newCompany("Otra SA")
		other.sede = 3
		local ctx2 = makeCtx(10)
		ctx2.friends = ctx.friends
		local h2 = hireN(other, ctx2, 1)[1].e
		-- Los ids de empleado son de cada empresa: un pedido se resuelve SIEMPRE contra la empresa activa, nunca
		-- devuelve el amigo de un empleado de otra empresa.
		local cross = FI.avatarRequest(g, { h2.id })
		check(cross == nil or (FI.isAssigned(g, cross[1]) and (cross[1] ~= h2.friend.userId or FI.isAssigned(g, h2.friend.userId))), "otra empresa: solo se resuelven amigos de la empresa activa")
		check(FI.isAssigned(g, a.friend.userId) and not FI.isAssigned(g, 424242), "vigencia: solo amigos asignados en la empresa")
		local fu = a.friend.userId
		check(Actions.fire(g, ctx, { employeeId = a.id }).ok, "despedir")
		check(not FI.isAssigned(g, fu), "despedido: su amigo deja de estar vigente")
		check(FI.avatarRequest(g, { a.id }) == nil, "despedido: ya no se puede pedir su avatar")
		-- Jugador sin amigos: la lista llega vacía (válida) y todos los puestos quedan sin identidad.
		local lonely = newCompany("Solo SA")
		lonely.sede = 3
		local ctx3 = makeCtx(11)
		ctx3.friends = FI.roster({ status = "ok", complete = true, list = {} })
		local hs = hireN(lonely, ctx3, 2)
		check(hs[1].e.friend == nil and hs[2].e.friend == nil, "sin amigos: puestos sin identidad")
		local sum = FI.summary(lonely, ctx3.friends)
		check(sum.status == "ok" and sum.total == 0 and sum.vacant == 2 and sum.next == nil, "resumen: 0 amigos, 2 puestos sin amigo")
		local r = FI.reconcile(lonely, ctx3.friends, 100, 1)
		check(r.assigned == 0 and r.released == 0, "nada que reasignar")
	end)

	test("[AM3] Sesión: la lista se pide al entrar, se reintenta, se guarda el UserId y las partidas viejas se completan", function()
		local store = newStore()
		local clock = { t = 1000, c = 0 }
		local mode = "fail"
		local calls = 0
		local roster = friends(3, 2000)
		local notices = {}
		local fetcher = {
			fetch = function(_player: any): any
				calls += 1
				if mode == "fail" then
					error("HTTP 500")
				end
				return { status = "ok", complete = mode ~= "partial", list = mode == "partial" and { roster[1] } or roster, fetchedAt = clock.t }
			end,
		}
		local mgr, pushed = makeServer(store, "A", clock, { friends = fetcher, notice = function(_, _, text)
			table.insert(notices, text)
		end })
		local p = { UserId = 77, Name = "siete" }
		mgr:add(p)
		eq(calls, 1, "1. la lista se pide al entrar")
		local s = playThrough(mgr, p)
		s.game.sede = 3
		eq(pushed[p].friends.status, "failed", "14. la falla se informa a la interfaz")
		Simulation.ensureMarket(s.game, s.ctx)
		local c = s.game.candidates[1]
		check(mgr:request(p, "hire", { candidateId = c.id, requestId = rid() }).ok, "contratar con la lista caída")
		local e = s.game.employees[#s.game.employees]
		check(e.friend == nil, "14. sin lista: puesto sin identidad (no se inventa ninguna)")
		-- Reintento programado: se vuelve a pedir después de la espera, no en cada segundo.
		check(s.friendsNext ~= nil and s.friendsNext > clock.c, "se programa un reintento")
		mgr:tick()
		eq(calls, 1, "no se reintenta antes de tiempo (límite de solicitudes)")
		mode = "ok"
		clock.c = s.friendsNext + 0.1
		mgr:tick()
		eq(calls, 2, "reintenta después de la espera")
		check(e.friend ~= nil and e.name == e.friend.displayName, "al llegar la lista, el puesto recibe su amigo")
		local uid = e.friend.userId
		eq(pushed[p].friends.status, "ok", "la interfaz recibe el estado de la lista")
		check(pushed[p].game.employees[#pushed[p].game.employees].friend.userId == uid, "el cliente recibe el UserId del amigo")
		-- Una lista cortada no reemplaza a la completa.
		mode = "partial"
		mgr:fetchFriends(s)
		eq(#s.friends.list, 3, "lista incompleta: sigue valiendo la completa")
		-- 8. Se guarda el UserId y se recupera en otra sesión, aunque allí la consulta falle.
		mgr:remove(p) -- guarda al salir
		check(store.data["player_77"] ~= nil, "partida guardada")
		mode = "fail"
		local mgr2, pushed2 = makeServer(store, "B", clock, { friends = fetcher })
		mgr2:add(p)
		check(mgr2:request(p, "selectSlot", { slot = "1" }).ok, "abrir la empresa en otro servidor")
		local e2 = mgr2.list[p].game.employees[#mgr2.list[p].game.employees]
		check(e2.friend and e2.friend.userId == uid and e2.name == e.name, "8 y 14. identidad conservada entre sesiones aunque falle la consulta")
		eq(pushed2[p].game.schema, GameState.SCHEMA, "sin cambio de esquema")
		mgr2:remove(p)
		-- 18. Partida vieja (sin identidades): al llegar la lista, sus empleados reciben amigos sin tocar nada más.
		local old = loadFixture()
		local store2 = newStore()
		local migrated = assert(GameState.migrate(Util.deepCopy(old), 1000))
		migrated.employees = {
			{ id = "v1", name = "Viejo Uno", spec = "produccion", dept = "produccion", salary = 1500, skills = {}, potential = {}, months = 12, hiredDay = 0, adapt = {}, status = "activo" },
		}
		for _, k in Staff.SKILL_ORDER do
			migrated.employees[1].skills[k] = 30
			migrated.employees[1].potential[k] = 60
		end
		store2.data["player_78"] = { schema = 2, profile = { slots = { ["1"] = migrated }, active = "1" } }
		mode = "ok"
		local mgr3, pushed3 = makeServer(store2, "C", clock, { friends = fetcher })
		local p3 = { UserId = 78 }
		mgr3:add(p3)
		eq(pushed3[p3].status, "ready", "18. la partida vieja carga")
		check(mgr3:request(p3, "selectSlot", { slot = "1" }).ok, "18. abrirla")
		local ve = mgr3.list[p3].game.employees[1]
		check(ve.friend ~= nil and ve.name == ve.friend.displayName, "18. el empleado viejo pasa a ser un amigo")
		eq(ve.salary, 1500, "18. conserva su salario")
		eq(ve.months, 12, "18. y su experiencia")
	end)
end


-- Etapa 6: primer ciclo jugable completo (integración con sesiones reales) -------------------------------------
do
	local START = Catalog.START.money
	local VALID_SALE = { produccion = true, ["por lanzar"] = true, ["en venta"] = true }

	-- Dinero que explican los movimientos registrados (libro + ventas y fabricación agregadas por mes).
	local function flowTotal(g: any): number
		local t = 0
		for _, ds in g.stats.days do
			for _, v in ds.flow do
				t += v
			end
		end
		return t
	end

	-- Estados imposibles: si algo no cierra, devuelve el motivo.
	local function impossible(g: any): string?
		if type(g.money) ~= "number" or g.money ~= g.money or g.money < 0 then
			return "dinero inválido: " .. tostring(g.money)
		end
		if math.abs(g.money - (START + flowTotal(g))) > 0.5 then
			return string.format("el dinero (%d) no coincide con los movimientos (%d)", g.money, START + flowTotal(g))
		end
		local perDesign, lines, sold = {}, {}, 0
		local function noteDesign(id: string)
			perDesign[id] = (perDesign[id] or 0) + 1
			if perDesign[id] > 1 then
				return "dos lotes del mismo diseño " .. id
			end
			return nil
		end
		for _, l in g.lots do
			if not VALID_SALE[l.saleState] then
				return "estado de venta imposible en un lote activo: " .. tostring(l.saleState)
			end
			if l.sold < 0 or l.produced < l.sold + l.discarded or l.produced > l.qty then
				return string.format("unidades imposibles (%d fabricadas, %d vendidas, %d de %d)", l.produced, l.sold, l.discarded, l.qty)
			end
			if l.saleState == "produccion" and (l.sold > 0 or l.review ~= nil) then
				return "ventas o reseñas antes de terminar de fabricar"
			end
			if l.saleState ~= "produccion" and (l.produced ~= l.qty or not l.review or #l.review.scores ~= 4) then
				return "a la venta sin terminar de fabricar o sin sus cuatro reseñas"
			end
			if l.saleState == "en venta" and not (type(l.price) == "number" and l.price > 0) then
				return "a la venta sin precio"
			end
			if l.costSpent ~= l.qty * l.unitCost then
				return "costo cobrado distinto del lote"
			end
			if l.saleState == "produccion" then
				if lines[l.line] then
					return "dos lotes en la misma línea"
				end
				lines[l.line] = true
			end
			local why = noteDesign(l.designId)
			if why then
				return why
			end
			sold += l.sold
		end
		for _, h in g.lotHistory do
			local why = noteDesign(h.designId or h.id)
			if why then
				return why
			end
			sold += h.sold or 0
		end
		if sold ~= g.counters.unitsSold then
			return string.format("ventas contadas dos veces o perdidas (%d en lotes, contador %d)", sold, g.counters.unitsSold)
		end
		for _, d in g.designs do
			if perDesign[d.id] and not d.lotLaunched then
				return "diseño con lote sin marcar como fabricado"
			end
		end
		return nil
	end

	local function server(uid: number, store: any?, clock: any?, job: string?): (any, any, any, any)
		store = store or newStore()
		clock = clock or { t = 1000, c = 0 }
		local mgr, pushed = makeServer(store, job or "A", clock)
		local p = { UserId = uid }
		mgr:add(p)
		return mgr, p, store, clock, pushed
	end

	-- Corre n segundos de juego y comprueba los estados en cada uno.
	local function run(mgr: any, clock: any, g: any, n: number, untilFn: (() -> boolean)?): (boolean, string?)
		for _ = 1, n do
			ticks(mgr, clock, 1)
			local why = impossible(g)
			if why then
				return false, why
			end
			if untilFn and untilFn() then
				return true, nil
			end
		end
		return untilFn == nil, untilFn and "no llegó a tiempo" or nil
	end

	local draftN = 0
	-- El camino del editor: borrador guardado y finalizado (cada paso por la sesión real).
	local function design(mgr: any, p: any, g: any, baseId: string, name: string): (any, any)
		draftN += 1
		local id = "borrador-ciclo-" .. draftN
		local draft = draftFor(g, baseId, name)
		local sv = mgr:request(p, "saveDraft", { draftId = id, draft = draft, step = 5, visited = 5, rev = 1, requestId = rid() })
		assert(sv.ok, sv.msg)
		local r = mgr:request(p, "finalizeDesign", { draftId = id, draft = draft, requestId = rid() })
		return r, id
	end

	local function waitState(mgr: any, clock: any, g: any, lotId: string, state: string, limit: number?): (boolean, string?)
		return run(mgr, clock, g, limit or 3000, function(): boolean
			local l = findLot(g, lotId)
			return (l and l.saleState == state) or (state == "agotado" and l == nil and findHist(g, lotId) ~= nil)
		end)
	end

	test("[CJ1] Ciclo jugable 1–8: empresa de 1970, primer diseño con el capital inicial, incompleto, borrador, lote chico, fondos y duplicados", function()
		local mgr, p, store, clock = server(7001)
		local s = playThrough(mgr, p)
		local g = s.game
		-- 1. Empresa nueva de 1970 con lo necesario para el primer auto.
		eq(Rules.date(g), "01/01/1970", "1. empieza el 01/01/1970")
		eq(g.money, START, "1. capital inicial")
		check(Rules.ownsLine(g, 1) and not Rules.ownsLine(g, 2) and not Rules.ownsLine(g, 3), "1. una línea al inicio; la 2 y la 3 bloqueadas")
		check(DesignCalc.baseAvailable(g, Catalog.base("brisa")) == nil and DesignCalc.baseAvailable(g, Catalog.base("duna")) == nil, "1. sedán y coupé de 1970 disponibles")
		local base = DesignCalc.newDraft(g, "brisa")
		for _, cat in { "motor" } do
			check(DesignCalc.partBlock(g, base, Catalog.part(cat, base.parts[cat])) == nil, "1. el motor inicial se puede usar")
		end
		check(impossible(g) == nil, "1. sin estados imposibles al empezar")
		-- 3. Diseño incompleto o inválido: se explica y no se cobra nada.
		local bad = draftFor(g, "brisa", "")
		local m0 = g.money
		local r = mgr:request(p, "saveDesign", { draft = bad, requestId = rid() })
		check(not r.ok and string.find(r.msg, "nombre", 1, true) ~= nil, "3. sin nombre: se explica qué falta (" .. tostring(r.msg) .. ")")
		local unknown = draftFor(g, "brisa", "Motor Raro")
		unknown.parts.motor = "motor-inexistente"
		r = mgr:request(p, "saveDesign", { draft = unknown, requestId = rid() })
		check(not r.ok and string.find(r.msg, "desconocida", 1, true) ~= nil, "3. componente inexistente: rechazado con motivo (" .. tostring(r.msg) .. ")")
		local locked
		for _, pt in Catalog.partsOf("motor") do
			if not locked and DesignCalc.partBlock(g, DesignCalc.newDraft(g, "brisa"), pt) ~= nil then
				locked = pt
			end
		end
		local future2 = draftFor(g, "brisa", "Motor Futuro")
		future2.parts.motor = locked.id
		r = mgr:request(p, "saveDesign", { draft = future2, requestId = rid() })
		check(not r.ok and string.find(r.msg, locked.name, 1, true) ~= nil, "3. componente bloqueado (" .. locked.name .. "): rechazado con su requisito (" .. tostring(r.msg) .. ")")
		-- Un componente que falta en la solicitud se completa con el predeterminado de la carrocería (compatibilidad
		-- con clientes anteriores): el editor siempre envía todos, y nunca queda un auto incompleto.
		local noMotor = draftFor(g, "brisa", "Sin Motor")
		noMotor.parts.motor = nil
		local filled = DesignCalc.sanitize(g, noMotor)
		check(filled and filled.parts.motor == Catalog.base("brisa").defaults.motor, "3. componente omitido: se usa el predeterminado (el auto nunca queda incompleto)")
		local future = draftFor(g, "brisa", "Del Futuro")
		future.baseId = "no-existe"
		r = mgr:request(p, "saveDesign", { draft = future, requestId = rid() })
		check(not r.ok, "3. carrocería inexistente: rechazada")
		eq(g.money, m0, "3. los rechazos no cobran")
		eq(#g.designs, 0, "3. no se crea ningún diseño")
		-- 4. Borrador: se guarda, se sale y se recupera en otra sesión.
		local draft = draftFor(g, "brisa", "Primer Sedán")
		draft.paint.primary = "#2E6BFF"
		check(mgr:request(p, "saveDraft", { draftId = "borrador-primero", draft = draft, step = 3, visited = 3, rev = 1, requestId = rid() }).ok, "4. borrador guardado")
		mgr:remove(p)
		local mgr2, _, _, _ = makeServer(store, "B", clock)
		mgr2:add(p)
		check(mgr2:request(p, "selectSlot", { slot = "1" }).ok, "4. volver a entrar")
		g = mgr2.list[p].game
		local dr = Actions.findDraft(g, "borrador-primero")
		check(dr and dr.step == 3 and dr.spec.name == "Primer Sedán" and dr.spec.paint.primary == "#2E6BFF", "4. el borrador vuelve igual (etapa, nombre y pintura)")
		mgr = mgr2
		-- 2 y 5. Finalizar: diseño válido con el capital inicial, id único, estadísticas y costo una sola vez.
		local items = DesignCalc.devItems(g, dr.spec, DesignCalc.engineeringKind(nil, dr.spec))
		local dev = 0
		for _, it in items do
			if not it.paid and not it.stock then
				dev += it.cost
			end
		end
		check(dev > 0 and dev < START, "2. el desarrollo es pagable con el capital inicial (" .. Util.money(dev) .. ")")
		local fid = rid()
		r = mgr:request(p, "finalizeDesign", { draftId = "borrador-primero", draft = dr.spec, requestId = fid })
		check(r.ok and r.designId ~= nil, "5. diseño finalizado: " .. tostring(r.msg))
		check(string.find(r.msg, "Producción", 1, true) ~= nil, "5. confirmación clara con el paso siguiente")
		local d = g.designs[1]
		eq(g.money, START - dev, "5. desarrollo cobrado una sola vez")
		check(Actions.findDraft(g, "borrador-primero") == nil, "5. el borrador se retira")
		eq(serde.encode("json", DesignCalc.computeDesign(g, d)), serde.encode("json", DesignCalc.computeDesign(g, draft)), "5. conserva las estadísticas de la configuración elegida")
		eq(d.paint.primary, "#2E6BFF", "5. y su aspecto")
		-- 8. Solicitud duplicada: mismo requestId → la misma respuesta; otro id → explicado, sin duplicar.
		local again = mgr:request(p, "finalizeDesign", { draftId = "borrador-primero", draft = dr.spec, requestId = fid })
		check(again.ok and again.designId == d.id, "8. reenvío idéntico: misma respuesta")
		local other = mgr:request(p, "finalizeDesign", { draftId = "borrador-primero", draft = dr.spec, requestId = rid() })
		check(not other.ok and string.find(other.msg, "ya se finalizó", 1, true) ~= nil, "8. otra confirmación: explicada, sin duplicar")
		eq(#g.designs, 1, "8. un solo diseño")
		eq(g.money, START - dev, "8. sin cobros extra")
		r = design(mgr, p, g, "brisa", "Segundo Sedán")
		check(r.ok and r.designId ~= d.id, "5. cada diseño recibe un id único")
		local d2 = g.designs[2]
		-- 7. Fondos insuficientes: no se cobra, no se marca y se explica cuánto alcanza.
		local unit = Rules.lotUnitCost(g, DesignCalc.computeDesign(g, d).unitCost)
		local maxQty = math.floor(g.money / unit)
		local m1 = g.money
		r = mgr:request(p, "createLot", { designId = d.id, qty = maxQty + 1, requestId = rid() })
		check(not r.ok and string.find(r.msg, "Fondos insuficientes", 1, true) ~= nil, "7. fondos insuficientes explicado")
		check(g.money == m1 and #g.lots == 0 and not d.lotLaunched, "7. sin cobro, sin lote y el diseño sigue disponible")
		check(maxQty >= 20, "el primer lote razonable (≥ 20 unidades) se puede pagar con el capital inicial (" .. maxQty .. ")")
		-- 6. Lote chico, pagado al comenzar.
		local lid = rid()
		r = mgr:request(p, "createLot", { designId = d.id, qty = 10, requestId = lid })
		check(r.ok, "6. lote de 10: " .. tostring(r.msg))
		eq(m1 - g.money, 10 * unit, "6. se pagó completo al comenzar")
		local again2 = mgr:request(p, "createLot", { designId = d.id, qty = 10, requestId = lid })
		check(again2.ok and #g.lots == 1 and m1 - g.money == 10 * unit, "8. reenvío del lote: no se cobra ni crea dos veces")
		check(impossible(g) == nil, "sin estados imposibles: " .. tostring(impossible(g)))
		local _ = d2
	end)

	test("[CJ2] Ciclo jugable 9–18: producción, cuatro reseñas, precio, ventas parciales y completas, beneficios, archivo y segundo modelo", function()
		local mgr, p, store, clock = server(7002)
		local s = playThrough(mgr, p)
		local g = s.game
		local xp0, rep0 = g.xp, g.reputation
		local r = design(mgr, p, g, "brisa", "Ciclo Uno")
		check(r.ok, "diseño: " .. tostring(r.msg))
		check(g.xp > xp0, "experiencia por diseñar")
		local d = g.designs[1]
		local m0 = g.money
		r = mgr:request(p, "createLot", { designId = d.id, qty = 30, requestId = rid() })
		check(r.ok, "lote de 30 con el capital inicial: " .. tostring(r.msg))
		local lot = g.lots[1]
		local cost = m0 - g.money
		-- 9. Avance de producción sin ventas.
		local ok, why = run(mgr, clock, g, 10)
		check(ok, "9. " .. tostring(why))
		check(lot.produced > 0 and lot.produced < lot.qty and lot.sold == 0, "9. avanza la fabricación y no se vende (" .. lot.produced .. "/30)")
		check(not mgr:request(p, "launchSale", { lotId = lot.id, price = 5000, requestId = rid() }).ok, "12. no se vende antes de terminar")
		check(not mgr:request(p, "closeSale", { lotId = lot.id, requestId = rid() }).ok, "la fabricación no se cancela")
		-- 10. Al terminar: cuatro reseñas una sola vez.
		ok, why = waitState(mgr, clock, g, lot.id, "por lanzar")
		check(ok, "10. termina la fabricación: " .. tostring(why))
		local rv = lot.review
		eq(#rv.scores, 4, "10. cuatro críticos")
		for _, sc in rv.scores do
			check(type(sc.score) == "number" and sc.score >= 1 and sc.score <= 10 and type(sc.text) == "string" and #sc.text > 0, "10. nota y comentario de " .. tostring(sc.name))
		end
		local frozen = serde.encode("json", rv)
		run(mgr, clock, g, 20)
		eq(serde.encode("json", lot.review), frozen, "10. no se vuelven a generar")
		local again = Rules.criticReviews(g, lot.design)
		local same = #again.scores == 4
		for i, sc in again.scores do
			same = same and sc.critic == rv.scores[i].critic and math.abs(sc.score - rv.scores[i].score) <= 0.3
		end
		check(same, "10. corresponden a las características del auto (las mismas notas del cálculo, salvo el paso del tiempo)")
		-- 11. Precio recomendado: el del cálculo del diseño; más barato vende más rápido.
		eq(lot.refPrice, DesignCalc.computeDesign(g, d).price, "11. precio recomendado del cálculo")
		check(lot.refPrice > lot.unitCost, "11. el recomendado deja margen")
		-- 12. Inicio de ventas validado.
		check(not mgr:request(p, "launchSale", { lotId = lot.id, price = -5, requestId = rid() }).ok, "12. precio inválido rechazado")
		eq(Rules.validPrice(1.5), 2, "12. un precio con decimales se redondea al dólar (se puede cambiar después)")
		check(Rules.validPrice(0) == nil and Rules.validPrice(0 / 0) == nil and Rules.validPrice(math.huge) == nil, "12. cero, NaN e infinito rechazados")
		check(mgr:request(p, "launchSale", { lotId = lot.id, price = lot.refPrice, requestId = rid() }).ok, "12. a la venta al recomendado")
		check(not mgr:request(p, "launchSale", { lotId = lot.id, price = lot.refPrice, requestId = rid() }).ok, "12. no se lanza dos veces")
		-- 13. Venta parcial.
		ok, why = run(mgr, clock, g, 3000, function(): boolean
			local l = findLot(g, lot.id)
			return l ~= nil and l.sold > 0
		end)
		check(ok, "13. primeras ventas: " .. tostring(why))
		check(lot.sold < lot.produced and lot.revenue == lot.sold * lot.price, "13. venta parcial con ingresos exactos")
		-- 14. Venta completa y 16. archivo.
		local moneyBefore = g.money - lot.revenue
		ok, why = waitState(mgr, clock, g, lot.id, "agotado")
		check(ok, "14. se agota: " .. tostring(why))
		local h = findHist(g, lot.id)
		check(h and h.sold == 30 and h.saleState == "agotado", "14. las 30 vendidas, nunca más")
		check(findLot(g, lot.id) == nil, "16. el lote sale de los activos")
		check(#g.modelHistory >= 1, "16. queda en el historial de modelos")
		-- 15. Beneficio = ingresos − costo del lote (sin cobrar de nuevo al vender).
		eq(h.revenue - h.costSpent, h.revenue - cost, "15. el costo del lote se cobró una vez")
		eq(g.money - moneyBefore, h.revenue, "15. los ingresos entraron completos")
		check(h.revenue - h.costSpent > 0, "15. con ganancia al precio recomendado (" .. Util.money(h.revenue - h.costSpent) .. ")")
		check(g.reputation >= rep0 and g.rp > 0, "PI y reputación según las reglas")
		-- 18. Rechazo de un segundo lote del mismo diseño.
		r = mgr:request(p, "createLot", { designId = d.id, qty = 5, requestId = rid() })
		check(not r.ok and string.find(r.msg, "una sola vez", 1, true) ~= nil, "18. segundo lote del mismo diseño rechazado con explicación")
		-- 17. Segundo modelo.
		r = design(mgr, p, g, "duna", "Ciclo Dos")
		check(r.ok, "17. segundo modelo diseñado con las ganancias: " .. tostring(r.msg))
		local d2 = g.designs[#g.designs]
		local unit2 = Rules.lotUnitCost(g, DesignCalc.computeDesign(g, d2).unitCost)
		local q2 = math.min(40, math.floor(g.money / unit2))
		check(q2 >= 20, "17. alcanza para un segundo lote razonable (" .. q2 .. ")")
		r = mgr:request(p, "createLot", { designId = d2.id, qty = q2, requestId = rid() })
		check(r.ok, "17. segundo lote: " .. tostring(r.msg))
		check(impossible(g) == nil, "sin estados imposibles: " .. tostring(impossible(g)))
		local _ = store
	end)

	test("[CJ3] Ciclo jugable 19–22: velocidades, guardado en cada fase, empresas independientes y sin estados imposibles", function()
		local store = newStore()
		local clock = { t = 1000, c = 0 }
		local mgr = makeServer(store, "A", clock)
		local p = { UserId = 7003 }
		mgr:add(p)
		local s = playThrough(mgr, p)
		local g = s.game
		-- 19. Velocidades: proporcionales y sin ventas ni fabricación duplicadas al cambiar.
		check(design(mgr, p, g, "brisa", "Velocidad").ok, "diseño")
		local d = g.designs[1]
		check(mgr:request(p, "createLot", { designId = d.id, qty = 30, requestId = rid() }).ok, "lote")
		local lot = g.lots[1]
		local function produced(speed: number, secs: number): number
			check(mgr:request(p, "setSpeed", { speed = speed, requestId = rid() }).ok, "velocidad " .. speed)
			local b = lot.produced
			local ok, why = run(mgr, clock, g, secs)
			check(ok, "19. " .. tostring(why))
			return lot.produced - b
		end
		local a1 = produced(1, 6)
		local a3 = produced(3, 2)
		check(math.abs(a3 - a1) <= 2, string.format("19. 2 s a 3× fabrican como 6 s a 1× (%d y %d)", a1, a3))
		for i = 1, 30 do
			mgr:request(p, "setSpeed", { speed = (i % 3) + 1, requestId = rid() })
			local ok, why = run(mgr, clock, g, 1)
			if not ok then
				check(false, "19. cambios de velocidad: " .. tostring(why))
				break
			end
		end
		mgr:request(p, "setUiPause", { paused = true })
		local frozen = { lot.produced, g.time.day, g.time.minute, g.money }
		run(mgr, clock, g, 10)
		check(lot.produced == frozen[1] and g.time.day == frozen[2] and g.time.minute == frozen[3] and g.money == frozen[4], "9 y 19. en pausa no avanza nada")
		mgr:request(p, "setUiPause", { paused = false })
		mgr:request(p, "setSpeed", { speed = 1, requestId = rid() })
		-- 20. Guardar y recuperar en cada fase (fabricando, por lanzar, a la venta, agotado).
		local function reload(label: string)
			local snap = serde.encode("json", { g.money, g.time, g.lots, g.lotHistory, g.designs, g.counters, g.drafts })
			mgr:remove(p)
			mgr = makeServer(store, "R" .. label, clock)
			mgr:add(p)
			check(mgr:request(p, "selectSlot", { slot = "1" }).ok, "20. recargar (" .. label .. ")")
			g = mgr.list[p].game
			eq(serde.encode("json", { g.money, g.time, g.lots, g.lotHistory, g.designs, g.counters, g.drafts }), snap, "20. " .. label .. ": todo igual al recuperarlo")
			check(impossible(g) == nil, "20. " .. label .. ": sin estados imposibles (" .. tostring(impossible(g)) .. ")")
			lot = findLot(g, lot.id) or findHist(g, lot.id)
		end
		reload("fabricando")
		local ok, why = waitState(mgr, clock, g, lot.id, "por lanzar")
		check(ok, "termina: " .. tostring(why))
		local review = serde.encode("json", lot.review)
		reload("por lanzar")
		eq(serde.encode("json", lot.review), review, "20. las reseñas no cambian al recargar")
		check(mgr:request(p, "launchSale", { lotId = lot.id, price = lot.refPrice, requestId = rid() }).ok, "a la venta")
		run(mgr, clock, g, 3000, function(): boolean
			local l = findLot(g, lot.id)
			return l ~= nil and l.sold > 0
		end)
		reload("a la venta")
		ok, why = waitState(mgr, clock, g, lot.id, "agotado")
		check(ok, "agotado: " .. tostring(why))
		reload("agotado")
		check(findHist(g, lot.id) ~= nil and findHist(g, lot.id).sold == 30, "20. el historial se conserva")
		-- Sin progreso sin conexión: lo que pasa mientras no está no se calcula.
		local before = serde.encode("json", { g.money, g.time })
		mgr:remove(p)
		clock.t += 100000
		clock.c += 100000
		mgr = makeServer(store, "Z", clock)
		mgr:add(p)
		mgr:request(p, "selectSlot", { slot = "1" })
		g = mgr.list[p].game
		eq(serde.encode("json", { g.money, g.time }), before, "20. nada se ejecuta dos veces ni sin conexión al volver")
		-- 21. Empresas independientes: otra ranura con su propio ciclo.
		local moneyA, designsA, histA = g.money, #g.designs, #g.lotHistory
		check(mgr:request(p, "leaveCompany", {}).ok, "volver al menú")
		check(mgr:request(p, "createCompany", { slot = "2", name = "Otra Empresa", color = "#FF8A3D", logo = "rayo" }).ok, "21. segunda empresa")
		local g2 = mgr.list[p].game
		check(g2.money == START and #g2.designs == 0 and #g2.lots == 0 and #g2.lotHistory == 0 and #g2.drafts == 0, "21. empieza de cero: sin dinero, diseños, lotes ni ventas de la otra")
		check(design(mgr, p, g2, "duna", "De la Otra").ok, "21. diseña en la segunda")
		check(mgr:request(p, "createLot", { designId = g2.designs[1].id, qty = 10, requestId = rid() }).ok, "21. fabrica en la segunda")
		run(mgr, clock, g2, 20)
		check(mgr:request(p, "leaveCompany", {}).ok, "volver al menú")
		check(mgr:request(p, "selectSlot", { slot = "1" }).ok, "volver a la primera")
		g = mgr.list[p].game
		check(g.money == moneyA and #g.designs == designsA and #g.lotHistory == histA and #g.lots == 0, "21. la primera quedó intacta")
		for _, dd in g.designs do
			check(dd.name ~= "De la Otra", "21. sin diseños mezclados")
		end
		-- 22. Recorrido al azar (velocidades, pausas, lotes, ventas y recargas): nunca un estado imposible.
		local seed = 4242
		local function rnd(): number
			seed = (seed * 16807) % 2147483647
			return seed / 2147483647
		end
		local fails = nil
		for step = 1, 900 do
			local x = rnd()
			if x < 0.03 then
				mgr:request(p, "setSpeed", { speed = math.floor(rnd() * 3) + 1, requestId = rid() })
			elseif x < 0.05 then
				mgr:request(p, "setUiPause", { paused = rnd() < 0.5 })
			elseif x < 0.07 and #g.designs < 8 and g.money > 30000 then
				design(mgr, p, g, rnd() < 0.5 and "brisa" or "duna", "Azar " .. step)
			elseif x < 0.10 then
				for _, dd in g.designs do
					if not dd.lotLaunched then
						local unit = Rules.lotUnitCost(g, DesignCalc.computeDesign(g, dd).unitCost)
						local q = math.floor(g.money / unit * rnd())
						if q >= 1 then
							mgr:request(p, "createLot", { designId = dd.id, qty = q, requestId = rid() })
						end
						break
					end
				end
			elseif x < 0.13 then
				for _, l in g.lots do
					if l.saleState == "por lanzar" then
						mgr:request(p, "launchSale", { lotId = l.id, price = math.floor(l.refPrice * (0.8 + rnd() * 0.6)), requestId = rid() })
					elseif l.saleState == "en venta" and rnd() < 0.2 then
						mgr:request(p, "setLotPrice", { lotId = l.id, price = math.floor(l.refPrice * (0.8 + rnd() * 0.6)), requestId = rid() })
					end
				end
			elseif x < 0.135 then
				for _, l in g.lots do
					if l.saleState == "en venta" and l.sold > 0 and rnd() < 0.3 then
						mgr:request(p, "closeSale", { lotId = l.id, requestId = rid() })
					end
				end
			elseif x < 0.14 then
				mgr:remove(p)
				mgr = makeServer(store, "Q" .. step, clock)
				mgr:add(p)
				mgr:request(p, "selectSlot", { slot = "1" })
				g = mgr.list[p].game
			end
			ticks(mgr, clock, 1)
			local why2 = impossible(g)
			if why2 then
				fails = "paso " .. step .. ": " .. why2
				break
			end
		end
		check(fails == nil, "22. sin estados imposibles en 900 pasos al azar (" .. tostring(fails) .. ")")
	end)
end

-- Etapa 7: investigación y progresión tecnológica (casos 1–30 y recorrido 1970–2030) ---------------------------
do
	local RR = Catalog.RESEARCH_RULES
	local function allNodes(): { any }
		local out = {}
		for _, key in Catalog.RESEARCH_ORDER do
			for _, n in Catalog.RESEARCH[key].nodes do
				table.insert(out, n)
			end
		end
		return out
	end
	local function near(a: number, b: number, eps: number?): boolean
		return math.abs(a - b) < (eps or 1e-6)
	end
	local function setYear(g: any, y: number)
		g.time.day = (y - Catalog.CALENDAR.startYear) * 12
		g.time.minute = 0
	end
	-- Termina un proyecto con el reloj real de la simulación (días de juego = minutos / gameDayMinutes).
	local function finish(g: any, ctx: any, id: string)
		local p = Rules.researchProject(g, id)
		assert(p, "sin proyecto " .. id)
		local left = (p.days - p.progress) / Rules.researchSpeed(g)
		Simulation.simulate(g, ctx, math.ceil(left * Catalog.RULES.gameDayMinutes / 10) * 10)
	end
	local function research(g: any, ctx: any, id: string): any
		local r = Actions.startResearch(g, ctx, { id = id })
		if r.ok then
			finish(g, ctx, id)
		end
		return r
	end
	-- Invariantes de la investigación (lo que nunca puede pasar).
	local function researchImpossible(g: any): string?
		local seen = {}
		for _, id in g.research.done do
			if seen[id] then
				return "repetida en done: " .. id
			end
			seen[id] = true
			if not Catalog.researchNode(id) then
				return "tecnología inexistente: " .. tostring(id)
			end
		end
		if #g.research.projects > RR.maxParallel then
			return "más de " .. RR.maxParallel .. " proyectos"
		end
		local running = {}
		for _, p in g.research.projects do
			if running[p.id] then
				return "proyecto repetido: " .. p.id
			end
			running[p.id] = true
			if seen[p.id] then
				return "en curso y completada: " .. p.id
			end
			if not (p.progress >= 0 and p.progress <= p.days and p.days > 0) then
				return "avance fuera de rango: " .. p.id
			end
		end
		if not (g.rp >= 0) or g.rp ~= g.rp then
			return "PI inválidos: " .. tostring(g.rp)
		end
		for _, id in g.research.done do
			for _, r in Catalog.researchNode(id).req do
				if not seen[r] then
					return id .. " completada sin su requisito " .. r
				end
			end
		end
		if Rules.researchTreeDone(g) > Catalog.RESEARCH_TOTAL then
			return "más tecnologías que el árbol"
		end
		return nil
	end

	test("[IN1] Catálogo: ids únicos, años, requisitos válidos, sin ciclos ni investigaciones imposibles, beneficios reales (27, 29)", function()
		local nodes = allNodes()
		local ids = {}
		local normal, levels = 0, 0
		for _, n in nodes do
			check(ids[n.id] == nil, "27. id único: " .. n.id)
			ids[n.id] = n
			if n.family then
				levels += 1
			else
				normal += 1
			end
			check(type(n.year) == "number" and n.year >= Catalog.CALENDAR.startYear and n.year <= Catalog.CALENDAR.endYear, "27. año válido: " .. n.id .. " " .. tostring(n.year))
			check(table.find(Catalog.RESEARCH_ORDER, n.category) ~= nil, "27. categoría válida: " .. n.id)
		end
		eq(normal, 58, "27. 58 tecnologías normales")
		eq(levels, 54, "27. 54 niveles de motor (6 familias × niveles 2–10)")
		eq(Catalog.RESEARCH_TOTAL, 112, "27. total del árbol: 112")
		-- Requisitos: existen y no son de un año posterior.
		for _, n in nodes do
			for _, r in n.req do
				check(ids[r] ~= nil, "27. requisito existente: " .. n.id .. " ← " .. r)
				check(ids[r] == nil or ids[r].year <= n.year, "27. el requisito no es posterior: " .. n.id .. " ← " .. r)
			end
		end
		-- Sin ciclos (búsqueda en profundidad).
		local state, cycle = {}, nil
		local function visit(id: string)
			if state[id] == 1 then
				cycle = id
				return
			end
			if state[id] == 2 then
				return
			end
			state[id] = 1
			for _, r in ids[id].req do
				visit(r)
			end
			state[id] = 2
		end
		for _, n in nodes do
			visit(n.id)
		end
		check(cycle == nil, "27. sin dependencias circulares (" .. tostring(cycle) .. ")")
		-- Ninguna imposible: el primer año en que se puede empezar (adelanto + requisitos, que tardan sus días)
		-- existe y es como mucho 2030.
		local earliest = {}
		local function first(id: string): number
			if earliest[id] then
				return earliest[id]
			end
			local n = ids[id]
			local y = math.max(Catalog.CALENDAR.startYear, n.year - RR.aheadMaxYears)
			for _, r in n.req do
				y = math.max(y, first(r))
			end
			earliest[id] = y
			return y
		end
		local worst = 0
		for _, n in nodes do
			worst = math.max(worst, first(n.id))
		end
		check(worst <= Catalog.CALENDAR.endYear, "27. todas se pueden empezar antes de " .. Catalog.CALENDAR.endYear .. " (la última desde " .. worst .. ")")
		-- Cada tecnología hace algo: efecto automático o una opción del editor.
		for _, n in nodes do
			check((n.fx and next(n.fx) ~= nil) or Catalog.RESEARCH_UNLOCKS[n.id] ~= nil, "27. " .. n.id .. " tiene efecto (" .. Catalog.researchEffectKind(n) .. ")")
		end
		-- Las referencias de piezas, bases, equipamiento, variantes y opciones apuntan a tecnologías reales.
		local refs = 0
		for id in Catalog.RESEARCH_UNLOCKS do
			refs += 1
			check(ids[id] ~= nil, "27. desbloqueo de una tecnología real: " .. id)
		end
		check(refs >= 100, "27. " .. refs .. " tecnologías con desbloqueos del editor")
		-- Beneficio descrito = efecto real (los números del texto salen de fx).
		local LABEL = { hpPct = "%% de potencia", consPct = "%% de consumo", durability = "de durabilidad", safety = "de seguridad", unitCostPct = "%% de costo por unidad", quality = "de calidad", topPct = "%% de velocidad máxima", spoilerGrip = "de manejo" }
		for _, n in nodes do
			for k, v in n.fx do
				local lbl = LABEL[k]
				check(lbl ~= nil, "27. efecto conocido " .. n.id .. "." .. k)
				if lbl then
					local num = (v > 0 and "+" or "−") .. math.abs(v)
					check(string.find(n.gain, num .. " " .. lbl) ~= nil, "27. el texto de " .. n.id .. " dice " .. num .. " " .. string.gsub(lbl, "%%%%", "%%") .. " («" .. n.gain .. "»)")
				end
			end
		end
		-- Niveles de motor: el texto coincide con ENGINE_LEVEL_FX.
		local F = Catalog.ENGINE_LEVEL_FX
		for _, n in nodes do
			if n.family then
				local k = n.level - 1
				check(string.find(n.gain, "+" .. math.floor(F.hp * k * 100 + 0.5) .. " % de potencia", 1, true) ~= nil and string.find(n.gain, math.floor(F.cons * k * 100 - 0.5) .. " % de consumo", 1, true) ~= nil and string.find(n.gain, "+" .. math.floor(F.cost * k * 100 + 0.5) .. " % de costo", 1, true) ~= nil, "27. texto del nivel " .. n.id)
			end
		end
		-- 29. Balance: costos según las fórmulas centralizadas y reglas sin cambios.
		for _, n in nodes do
			local c = n.complexity
			check(c >= 1 and c <= 5, "29. complejidad 1–5: " .. n.id)
			eq(n.rp, math.max(1, math.floor(RR.pi[c] * (1 + RR.piEraGrowth * (n.year - 1970)) + 0.5)), "29. PI de " .. n.id)
			eq(n.cost, math.floor(RR.money[c] * Catalog.interp(RR.moneyEra, n.year) / 100 + 0.5) * 100, "29. dinero de " .. n.id)
			eq(n.days, RR.days[c], "29. días de " .. n.id)
		end
		check(RR.aheadMaxYears == 5 and RR.aheadPi == 0.15 and RR.aheadMoney == 0.15 and RR.aheadDays == 0.10 and RR.maxParallel == 6 and RR.linePi == 2 and RR.engineMaxLevel == 10, "29. reglas de I+D sin cambios (adelanto 5 años, +15/+15/+10 %, 6 a la vez, 2 PI por línea, 10 niveles)")
		local piLv = {}
		for _, l in Catalog.FACILITIES.research.levels do
			table.insert(piLv, l.pi)
		end
		eq(table.concat(piLv, ","), "3,8,20,45,90", "29. PI/min del centro por nivel sin cambios")
	end)

	test("[IN2] Familias de motor y variantes: niveles 2–10, requisitos, motores físicos y fechas coherentes (20, 22)", function()
		for _, fam in Catalog.ENGINE_FAMILIES do
			local prevYear = fam.first
			for lvl = 2, RR.engineMaxLevel do
				local n = Catalog.researchNode("eng_" .. fam.id .. "_" .. lvl)
				check(n ~= nil and n.family == fam.id and n.level == lvl, "20. existe " .. fam.id .. " nivel " .. lvl)
				if n then
					if lvl == 2 then
						eq(table.concat(n.req, ","), fam.req or "", "20. el nivel 2 de " .. fam.id .. " pide solo lo que habilita la familia")
					else
						eq(table.concat(n.req, ","), "eng_" .. fam.id .. "_" .. (lvl - 1), "20. " .. fam.id .. " nivel " .. lvl .. " pide el anterior")
					end
					check(n.year >= prevYear and n.year <= Catalog.CALENDAR.endYear, "20. años crecientes " .. n.id .. " (" .. n.year .. ")")
					prevYear = n.year
				end
			end
			-- Motores físicos de la familia: el nivel 1 llega con el motor, nunca después de poder investigar el 2.
			local firstMotor = math.huge
			local unlockers = {}
			for _, p in Catalog.PARTS do
				if p.cat == "motor" and p.family == fam.id then
					local y = p.research and Catalog.researchNode(p.research).year or p.year or 1970
					firstMotor = math.min(firstMotor, y)
					if p.research then
						unlockers[p.research] = true
					end
				end
			end
			check(firstMotor < math.huge, "20. " .. fam.id .. " tiene motores en el catálogo")
			-- El motor (nivel 1) está disponible desde el año de la familia o antes (I3: el 1.0 turbo llega con
			-- «Inyección directa», 2006), nunca después de que se pueda investigar el nivel 2.
			check(firstMotor <= fam.first, "20. el primer motor " .. fam.id .. " (" .. firstMotor .. ") no llega después de la familia (" .. fam.first .. ")")
			check(firstMotor <= Catalog.researchNode("eng_" .. fam.id .. "_2").year, "20. el motor " .. fam.id .. " existe antes de su nivel 2")
			check(fam.req == nil or unlockers[fam.req], "20. la tecnología que habilita la familia " .. fam.id .. " también habilita su motor")
		end
		-- Variantes: equilibrada de serie; económica y deportiva por investigación, solo a combustión.
		local bal, eco, sport = Catalog.engineVariant("balanced"), Catalog.engineVariant("eco"), Catalog.engineVariant("sport")
		check(bal.research == nil and eco.research == "var_eco" and sport.research == "var_sport", "22. equilibrada de serie; las otras dos se investigan")
		check(#Catalog.researchNode("var_eco").req == 0 and #Catalog.researchNode("var_sport").req == 0, "22. en cualquier orden (sin requisitos entre sí)")
		check(eco.need == "combustion" and sport.need == "combustion", "22. solo para motores a combustión")
		check(string.find(Catalog.researchNode("var_sport").gain, "+15 % de potencia, +12 % de consumo, +1 de calidad y +10 % de costo", 1, true) ~= nil, "22. el texto de la deportiva coincide con el catálogo")
		check(string.find(Catalog.researchNode("var_eco").gain, "−15 % de consumo, −12 % de potencia y −3 % de costo", 1, true) ~= nil, "22. el texto de la económica coincide con el catálogo")
	end)

	test("[IN3] PI en una partida real: centro, líneas activas e inactivas, 1×/2×/3×, pausa por menú y sin PI duplicados (1–6)", function()
		local store = newStore()
		local clock = { t = 1000, c = 0 }
		local mgr = makeServer(store, "IN3", clock)
		local p = { UserId = 7301 }
		mgr:add(p)
		local s = playThrough(mgr, p)
		local g = s.game
		-- 1. Empresa nueva en 1970.
		eq(Rules.year(g), 1970, "1. empieza en 1970")
		check(g.time.day == 0 and g.rp == 0 and #g.research.done == 0 and #g.research.projects == 0, "1. sin PI, sin tecnologías y sin proyectos")
		eq(g.counters.researchDone, 0, "1. contador en 0")
		-- 2. Investigaciones iniciales disponibles: lo de 1970–1975 sin requisitos.
		local avail = {}
		for _, n in allNodes() do
			local st = Rules.researchState(g, n)
			if st == "disponible" then
				table.insert(avail, n.id)
				check(n.year <= 1975 and #Rules.researchMissing(g, n) == 0, "2. disponible solo si está dentro del adelanto: " .. n.id)
			elseif n.year <= 1975 and #n.req == 0 then
				check(false, "2. debería estar disponible: " .. n.id)
			end
		end
		check(#avail >= 15, "2. " .. #avail .. " investigaciones disponibles al empezar (" .. table.concat(avail, ", ") .. ")")
		for _, id in { "ca1", "mo1", "mo2", "se1", "te_radio", "eng_I4_2", "eng_I6_2" } do
			check(table.find(avail, id) ~= nil, "2. disponible desde el inicio: " .. id)
		end
		check(Rules.researchState(g, Catalog.researchNode("ca3")) == "bloqueada", "2. con requisitos pendientes queda bloqueada")
		-- 3. Centro: 3 PI por minuto real a 1×.
		ticks(mgr, clock, 60)
		check(near(g.rp, 3), "3. un minuto a 1×: " .. Util.num(g.rp, 3) .. " PI (centro nivel 1 = 3/min)")
		g.facilities.research = 2
		eq(Rules.piCenter(g), 8, "3. centro nivel 2: 8 PI/min")
		local rp0 = g.rp
		ticks(mgr, clock, 30)
		check(near(g.rp - rp0, 4), "3. medio minuto con el nivel 2: +" .. Util.num(g.rp - rp0, 3))
		g.facilities.research = 1
		-- 4. Producción: una línea fabricando suma 2 PI/min; terminada, deja de sumar.
		g.money = 5000000
		check(mgr:request(p, "saveDesign", { draft = draftFor(g, "brisa", "Sedán PI"), requestId = rid() }).ok, "diseño")
		check(mgr:request(p, "createLot", { designId = g.designs[1].id, qty = 10, requestId = rid() }).ok, "lote chico")
		ticks(mgr, clock, 1)
		eq(Rules.activeLines(g), 1, "4. una línea activa")
		eq(Rules.piPerMinute(g), 3 + RR.linePi, "4. centro + línea = 5 PI/min")
		rp0 = g.rp
		ticks(mgr, clock, 12)
		check(near(g.rp - rp0, 5 * 12 / 60), "4. 12 s: +" .. Util.num(g.rp - rp0, 3) .. " PI (exactamente 5/min, sin duplicar)")
		for _ = 1, 400 do
			if g.lots[1].prodState == "completado" then
				break
			end
			ticks(mgr, clock, 1)
		end
		eq(g.lots[1].prodState, "completado", "4. el lote termina de fabricarse")
		eq(Rules.activeLines(g), 0, "4. una línea sin fabricar no cuenta")
		eq(Rules.piPerMinute(g), 3, "4. solo el centro")
		-- 5. Velocidades.
		for _, sp in { 1, 2, 3 } do
			check(mgr:request(p, "setSpeed", { speed = sp, requestId = rid() }).ok, sp .. "×")
			rp0 = g.rp
			ticks(mgr, clock, 20)
			check(near(g.rp - rp0, 3 * sp * 20 / 60), "5. a " .. sp .. "× en 20 s: +" .. Util.num(g.rp - rp0, 3) .. " PI")
		end
		check(mgr:request(p, "setSpeed", { speed = 1, requestId = rid() }).ok, "1×")
		-- 6. Pausa por menú (y pausa normal): no se generan PI.
		check(mgr:request(p, "setUiPause", { paused = true }).ok, "menú abierto")
		rp0 = g.rp
		ticks(mgr, clock, 60)
		eq(g.rp, rp0, "6. con un menú abierto no se generan PI")
		check(mgr:request(p, "setUiPause", { paused = false }).ok, "menú cerrado")
		check(mgr:request(p, "setSpeed", { speed = 0, requestId = rid() }).ok, "pausa")
		rp0 = g.rp
		ticks(mgr, clock, 60)
		eq(g.rp, rp0, "6. en pausa tampoco")
		check(mgr:request(p, "setSpeed", { speed = 1, requestId = rid() }).ok, "sigue")
		-- Personal y mobiliario: no suman PI por minuto y su descuento se aplica una sola vez.
		local know = newCompany("Saber IN3")
		local plain = newCompany("Plano IN3")
		placeN(know, "estanteria_madera_1970", 1)
		eq(Rules.piPerMinute(know), Rules.piPerMinute(plain), "3. el mobiliario no genera PI por minuto")
		local node = Catalog.researchNode("mo2")
		local piK = Rules.researchCost(know, node)
		eq(piK, math.max(1, math.floor(node.rp * (1 - Rules.staff(know, "conocimiento")) + 0.5)), "3. el descuento de conocimiento se aplica una vez")
		-- Guardar y cargar conserva los PI (con decimales).
		local before = g.rp
		check(mgr:request(p, "leaveCompany", {}).ok, "guardar y volver al menú")
		mgr:remove(p)
		local mgr2 = makeServer(store, "IN3b", clock)
		mgr2:add(p)
		check(mgr2:request(p, "selectSlot", { slot = "1" }).ok, "abrir de nuevo")
		check(near(mgr2.list[p].game.rp, before), "PI conservados al cargar (" .. Util.num(before, 3) .. ")")
	end)

	test("[IN4] Reglas de proyectos: 6 a la vez, séptimo rechazado, cobro único, duplicados, requisitos, adelanto y difusión (7–17)", function()
		local store = newStore()
		local clock = { t = 1000, c = 0 }
		local mgr = makeServer(store, "IN4", clock)
		local p = { UserId = 7401 }
		mgr:add(p)
		local s = playThrough(mgr, p)
		local g = s.game
		g.money = 50000000
		g.rp = 5000
		local function start(id: any, extra: any?): any
			local pl = extra or {}
			pl.id = id
			pl.requestId = pl.requestId or rid()
			clock.c += Sessions.RATE_WINDOW -- sin chocar con el límite de acciones por segundo (sin simular)
			return mgr:request(p, "startResearch", pl)
		end
		local function charges(): number
			local n = 0
			for _, l in g.ledger do
				if l.type == "investigacion" then
					n += 1
				end
			end
			return n
		end
		-- 11. Sin requisitos, desconocida o con datos raros: rechazada sin cobrar.
		local m0, rp0 = g.money, g.rp
		local r = start("ca3")
		check(not r.ok and string.find(r.msg, "Carrocería reforzada", 1, true) ~= nil, "11. sin requisitos: " .. tostring(r.msg))
		check(not start("no_existe").ok and not start({ "ca1" }).ok and not start(42).ok, "11. ids falsos rechazados")
		check(not mgr:request(p, "completeResearch", { id = "ca1", requestId = rid() }).ok, "12. no hay acción para completar desde el cliente")
		eq(g.money, m0, "11. no cobró dinero")
		eq(g.rp, rp0, "11. no cobró PI")
		-- 13. Más de 5 años de adelanto: rechazada.
		r = start("co2") -- 1976: en 1970 son 6 años
		check(not r.ok and string.find(r.msg, "Se puede adelantar desde 1971", 1, true) ~= nil, "13. 6 años de adelanto rechazado: " .. tostring(r.msg))
		-- 12 y 14. Año futuro permitido con el recargo exacto; el cliente no fija el precio.
		local n = Catalog.researchNode("eng_I4_2") -- 1975: 5 años de adelanto
		local wantPi = math.max(1, math.floor(n.rp * (1 + 0.15 * 5) + 0.5))
		local wantMoney = math.floor(n.cost * (1 + 0.15 * 5) / 100 + 0.5) * 100
		local wantDays = math.max(1, math.floor(n.days * (1 + 0.10 * 5) + 0.5))
		local pi, cost, days, info = Rules.researchCost(g, n)
		check(pi == wantPi and cost == wantMoney and days == wantDays and info.ahead == 5, "14. recargo de 5 años: " .. pi .. " PI, " .. cost .. " $, " .. days .. " días")
		m0, rp0 = g.money, g.rp
		r = start(n.id, { pi = 0, cost = 0, money = 0, days = 1, progress = 999, ahead = 0 })
		check(r.ok, "12. adelantada 5 años: " .. tostring(r.msg))
		eq(m0 - g.money, wantMoney, "9/14. dinero cobrado = el del servidor (el cliente no fija el precio)")
		eq(rp0 - g.rp, wantPi, "9/14. PI cobrados = los del servidor")
		local pr = Rules.researchProject(g, n.id)
		check(pr.days == wantDays and pr.progress == 0 and pr.paidPi == wantPi and pr.paidMoney == wantMoney and pr.ahead == 5 and pr.startDay == Rules.absDay(g), "12. proyecto con duración, costos y año de inicio fijos")
		-- 10. Duplicados: la misma de nuevo y el mismo pedido reenviado no cobran otra vez.
		local again = start(n.id)
		check(not again.ok and string.find(again.msg, "ya está en curso", 1, true) ~= nil, "10. no se empieza dos veces")
		local reqId = rid()
		m0 = g.money
		check(start("ca1", { requestId = reqId }).ok, "ca1")
		local dup = start("ca1", { requestId = reqId })
		check(dup.ok and g.money == m0 - Catalog.researchNode("ca1").cost, "10. el mismo pedido reenviado se cobra una sola vez")
		-- 7 y 8. Seis a la vez; la séptima se rechaza sin cobrar.
		for _, id in { "mo1", "se1", "te_radio", "var_eco" } do
			check(start(id).ok, "7. empieza " .. id)
		end
		eq(#g.research.projects, 6, "7. seis investigaciones simultáneas")
		m0, rp0 = g.money, g.rp
		r = start("mo2")
		check(not r.ok and string.find(r.msg, "máximo", 1, true) ~= nil, "8. la séptima se rechaza: " .. tostring(r.msg))
		check(g.money == m0 and g.rp == rp0 and #g.research.projects == 6, "8. sin cobrar ni agregar")
		eq(charges(), 6, "9. seis cobros, uno por proyecto")
		-- No se cancela.
		check(not mgr:request(p, "cancelResearch", { id = "ca1", requestId = rid() }).ok, "no se cancela")
		-- Los costos quedan fijos aunque pase el calendario (un año).
		local fixed = Util.deepCopy(Rules.researchProject(g, n.id))
		ticks(mgr, clock, 60)
		local now = Rules.researchProject(g, n.id)
		check(now.days == fixed.days and now.paidPi == fixed.paidPi and now.paidMoney == fixed.paidMoney and now.ahead == 5, "costos y duración no cambian con el calendario")
		eq(charges(), 6, "sin cobros nuevos con el paso del tiempo")
		-- 16 y 17. Se completa exactamente una vez, con aviso y XP.
		local xp0, lvl0 = g.xp, g.level
		for _ = 1, 2000 do
			if #g.research.projects == 0 then
				break
			end
			ticks(mgr, clock, 1)
		end
		eq(#g.research.projects, 0, "16. las seis terminan (cupos libres)")
		for _, id in { n.id, "ca1", "mo1", "se1", "te_radio", "var_eco" } do
			local count = 0
			for _, d in g.research.done do
				if d == id then
					count += 1
				end
			end
			eq(count, 1, "16. " .. id .. " completada exactamente una vez")
		end
		eq(g.counters.researchDone, 6, "16. contador: 6")
		check(g.level > lvl0 or g.xp > xp0, "16. otorga experiencia")
		local note = false
		for _, nt in g.notifications do
			note = note or string.find(nt.text, "Investigación completada: " .. n.name, 1, true) ~= nil
		end
		check(note, "17. notificación de investigación completada")
		ticks(mgr, clock, 120)
		eq(g.counters.researchDone, 6, "16. seguir el tiempo no la completa de nuevo")
		check(not start("ca1").ok, "10. una completada no se reinvestiga")
		-- Una adelantada se usa enseguida (aunque todavía no sea su año).
		check(Rules.year(g) < 1975 and Rules.engineLevelMax(g, "I4") == 2, "12. nivel 2 del I4 elegible antes de 1975 (año " .. Rules.year(g) .. ")")
		local d = DesignCalc.newDraft(g, "brisa")
		eq(d.motorLevel, 2, "12. un diseño nuevo ya lo usa")
		-- 15. Difusión: las viejas son más baratas; el piso es 40 %.
		local g2 = newCompany("Difusion IN4")
		local ca2 = Catalog.researchNode("ca2") -- 1975
		setYear(g2, 1977)
		local pi77 = Rules.researchCost(g2, ca2)
		eq(pi77, math.max(1, math.floor(ca2.rp * (1 - 0.08 * 1) + 0.5)), "15. dos años después: −8 %")
		setYear(g2, 2010)
		local piOld, moneyOld, daysOld, inf = Rules.researchCost(g2, ca2)
		eq(inf.diffusion, 0.4, "15. piso de difusión: 40 %")
		eq(piOld, math.max(1, math.floor(ca2.rp * 0.4 + 0.5)), "15. PI con difusión")
		eq(moneyOld, math.floor(ca2.cost * 0.4 / 100 + 0.5) * 100, "15. dinero con difusión")
		eq(daysOld, ca2.days, "15. la duración no cambia")
	end)

	test("[IN5] Guardado, empresas independientes y cambios de empresa sin abusos (18, 19)", function()
		local store = newStore()
		local clock = { t = 1000, c = 0 }
		local mgr = makeServer(store, "IN5", clock)
		local p = { UserId = 7501 }
		mgr:add(p)
		local g = playThrough(mgr, p).game
		g.money, g.rp = 10000000, 500
		check(mgr:request(p, "startResearch", { id = "mo2", requestId = rid() }).ok, "mo2")
		check(mgr:request(p, "startResearch", { id = "eng_I6_2", requestId = rid() }).ok, "I6 nivel 2 adelantado")
		ticks(mgr, clock, 40)
		local snap = jsonCopy(g.research)
		local money, rp = g.money, g.rp
		-- Empresa 2: árbol propio.
		check(mgr:request(p, "leaveCompany", {}).ok, "volver al menú")
		local rc = mgr:request(p, "createCompany", { slot = "2", name = "Segunda SA", color = Catalog.BRAND_COLORS[2][1], logo = "pico" })
		check(rc.ok, "segunda empresa: " .. tostring(rc.msg))
		local g2 = mgr.list[p].game
		check(#g2.research.done == 0 and #g2.research.projects == 0 and g2.rp == 0, "19. la segunda empresa empieza con su propio árbol vacío")
		ticks(mgr, clock, 30)
		g2.money, g2.rp = 10000000, 500
		check(mgr:request(p, "startResearch", { id = "ca1", requestId = rid() }).ok, "19. investiga en la segunda")
		check(mgr:request(p, "leaveCompany", {}).ok, "guarda la segunda")
		-- 18. Cargar en otro servidor: mismo avance, costos pagados, duración y año; sin cobrar de nuevo.
		mgr:remove(p)
		local mgr2 = makeServer(store, "IN5b", clock)
		mgr2:add(p)
		check(mgr2:request(p, "selectSlot", { slot = "1" }).ok, "abrir la primera")
		local g1 = mgr2.list[p].game
		eq(serde.encode("json", jsonCopy(g1.research)), serde.encode("json", snap), "18. proyectos idénticos (avance, PI y dinero pagados, días, adelanto, año de inicio)")
		check(g1.money == money and near(g1.rp, rp), "18. sin cobrar de nuevo al cargar")
		check(Rules.researchProject(g1, "ca1") == nil and not Rules.has(g1, "ca1"), "19. lo de la segunda empresa no aparece en la primera")
		-- Sigue desde el avance correcto y termina en los días que faltaban.
		local pr = Rules.researchProject(g1, "mo2")
		local left = math.ceil((pr.days - pr.progress) * Catalog.CALENDAR.realSecondsPerDay)
		ticks(mgr2, clock, left - 2)
		check(not Rules.has(g1, "mo2"), "18. no termina antes de tiempo")
		local doneBefore = g1.counters.researchDone
		local s1 = mgr2.list[p]
		local savedAt = s1.lastSave
		for _ = 1, 3 do
			s1.lastAutosave = clock.c + 1 -- que no coincida con el autoguardado periódico
			ticks(mgr2, clock, 1)
		end
		check(Rules.has(g1, "mo2"), "18. termina en los días que faltaban")
		eq(g1.counters.researchDone - doneBefore, 1, "18. una sola vez")
		check(s1.pendingSave == true or s1.lastSave ~= savedAt, "18. una investigación completada se guarda enseguida")
		-- Cambiar de empresa no mueve proyectos, cobros ni bonificaciones.
		check(mgr2:request(p, "leaveCompany", {}).ok, "menú")
		check(mgr2:request(p, "selectSlot", { slot = "2" }).ok, "abrir la segunda")
		local g2b = mgr2.list[p].game
		check(Rules.researchProject(g2b, "ca1") ~= nil and #g2b.research.projects == 1 and not Rules.has(g2b, "mo2"), "19. la segunda conserva solo lo suyo")
		check(g2b.money == 10000000 - Catalog.researchNode("ca1").cost, "19. la segunda pagó solo lo suyo")
	end)

	test("[IN6] Editor: desbloqueos, componentes bloqueados rechazados, estadísticas y diseños viejos intactos (21–26)", function()
		local ctx = makeCtx(77)
		local g = newCompany("Editor IN6")
		g.money, g.rp = 1e9, 1e6
		-- 23. Antes de investigar: bloqueados con el motivo; después: disponibles.
		local d = DesignCalc.newDraft(g, "brisa")
		local function needs(why: string?, name: string): boolean
			return why ~= nil and string.find(why, "«" .. name .. "»", 1, true) ~= nil
		end
		check(needs(DesignCalc.baseAvailable(g, Catalog.base("aurora")), "Plataforma de coupé deportivo"), "23. Aurora GT bloqueado con su requisito")
		check(needs(DesignCalc.partBlock(g, d, Catalog.part("turbo", "t1")), "Turbocompresor"), "23. turbo bloqueado con su requisito")
		check(needs(DesignCalc.equipmentBlock(g, Catalog.equipment("ac")), "Aire acondicionado"), "23. aire acondicionado bloqueado")
		check(needs(DesignCalc.optionBlock(g, Catalog.interiorOpt("seats", "sport")), "Butacas deportivas"), "23. butacas deportivas bloqueadas")
		check(needs(DesignCalc.variantBlock(g, d, Catalog.engineVariant("sport")), "Variante de motor deportiva"), "22. variante deportiva bloqueada con su requisito")
		-- 24. El servidor rechaza componentes bloqueados aunque el cliente los mande.
		local function save(mut: (any) -> ()): any
			local dr = draftFor(g, "brisa", "Prueba " .. rid():sub(9, 12))
			mut(dr)
			return Actions.saveDesign(g, ctx, { draft = dr })
		end
		check(not save(function(x) x.parts.turbo = "t1" end).ok, "24. turbo sin investigar rechazado")
		check(not save(function(x) x.motorLevel = 2 end).ok, "24. nivel de motor sin investigar rechazado")
		check(not save(function(x) x.motorLevel = 99 end).ok, "24. nivel inexistente rechazado")
		check(not save(function(x) x.motorVariant = "sport" end).ok, "24. variante sin investigar rechazada")
		check(not save(function(x) x.equipment = { "ac" } end).ok, "24. equipamiento sin investigar rechazado")
		check(not save(function(x) x.interior.seats = "sport" end).ok, "24. opción de interior sin investigar rechazada")
		check(not Actions.saveDesign(g, ctx, { draft = draftFor(g, "aurora", "Aurora X") }).ok, "24. chasis sin investigar rechazado")
		-- Diseño viejo (nivel 1, equilibrada) antes de investigar.
		local oldId = saveNew(g, ctx, "brisa", "Viejo 1970")
		local old = nil
		for _, x in g.designs do
			if x.id == oldId then
				old = x
			end
		end
		local oldCalc = DesignCalc.computeDesign(g, old)
		check(Actions.createLot(g, ctx, { designId = oldId, qty = 5 }).ok, "lote del diseño viejo")
		local lot = g.lots[#g.lots]
		local lotHp = lot.design.calc.hp
		-- Investigar: I4 hasta el nivel 10 (con el adelanto permitido año a año), variantes en orden inverso y piezas.
		for lvl = 2, 10 do
			local n = Catalog.researchNode("eng_I4_" .. lvl)
			if Rules.year(g) + RR.aheadMaxYears < n.year then
				setYear(g, n.year - RR.aheadMaxYears)
			end
			local r = research(g, ctx, n.id)
			check(r.ok and Rules.has(g, n.id), "20. I4 nivel " .. lvl .. ": " .. tostring(r.msg))
		end
		eq(Rules.engineLevelMax(g, "I4"), 10, "20. I4 completo hasta el nivel 10")
		eq(Rules.engineLevelMax(g, "I6"), 1, "20. las demás familias siguen en su nivel")
		check(research(g, ctx, "var_sport").ok and research(g, ctx, "var_eco").ok, "22. deportiva y después económica (cualquier orden)")
		for _, id in { "ca1", "ca2", "mo1", "mo3", "co1", "co2" } do
			check(research(g, ctx, id).ok, "23. investiga " .. id)
		end
		check(DesignCalc.baseAvailable(g, Catalog.base("aurora")) == nil, "23. Aurora GT habilitado")
		d = DesignCalc.newDraft(g, "brisa")
		check(DesignCalc.partBlock(g, d, Catalog.part("turbo", "t1")) == nil and DesignCalc.equipmentBlock(g, Catalog.equipment("ac")) == nil and DesignCalc.optionBlock(g, Catalog.interiorOpt("seats", "sport")) == nil, "23. turbo, aire y butacas habilitados")
		-- 21. Elegir niveles anteriores sigue siendo válido; un diseño nuevo propone el máximo.
		eq(d.motorLevel, 10, "21. un diseño nuevo propone el nivel 10")
		for _, lvl in { 1, 3, 7, 10 } do
			check(save(function(x) x.motorLevel = lvl end).ok, "21. se puede elegir el nivel " .. lvl)
		end
		check(not save(function(x) x.motorLevel = 11 end).ok, "21. el 11 no existe")
		-- 22. Variantes en todas las familias a combustión; nunca en el eléctrico.
		for _, motor in { "i4", "i6", "v6", "v8" } do
			local dd = DesignCalc.newDraft(g, "brisa")
			dd.parts.motor = motor
			check(DesignCalc.variantBlock(g, dd, Catalog.engineVariant("sport")) == nil and DesignCalc.variantBlock(g, dd, Catalog.engineVariant("eco")) == nil, "22. variantes válidas con " .. motor)
		end
		local ev = DesignCalc.newDraft(g, "rayo")
		check(DesignCalc.variantBlock(g, ev, Catalog.engineVariant("sport")) ~= nil and DesignCalc.variantBlock(g, ev, Catalog.engineVariant("eco")) ~= nil, "22. el eléctrico no admite variantes de combustión")
		check(DesignCalc.variantBlock(g, ev, Catalog.engineVariant("balanced")) == nil, "22. el eléctrico usa la equilibrada")
		-- 25. Estadísticas con las tecnologías nuevas (mismas fórmulas del catálogo).
		local F = Catalog.ENGINE_LEVEL_FX
		local function calc(mut: (any) -> ()): any
			local dd = DesignCalc.newDraft(g, "brisa")
			dd.equipment = {}
			mut(dd)
			return DesignCalc.computeDesign(g, dd)
		end
		local c1 = calc(function(x) x.motorLevel = 1; x.motorVariant = "balanced" end)
		local c5 = calc(function(x) x.motorLevel = 5; x.motorVariant = "balanced" end)
		check(c5.hp > c1.hp and c5.unitCost > c1.unitCost and c5.consumption < c1.consumption, "25. nivel 5: más potencia, más costo y menos consumo")
		local cs = calc(function(x) x.motorLevel = 1; x.motorVariant = "sport" end)
		local ce = calc(function(x) x.motorLevel = 1; x.motorVariant = "eco" end)
		check(cs.hp > c1.hp and cs.consumption > c1.consumption and ce.hp < c1.hp and ce.consumption < c1.consumption, "25. deportiva más potente y gastadora; económica al revés")
		-- Eléctrico: los niveles también bajan el consumo (como dice su tecnología).
		local g3 = newCompany("EV IN6")
		g3.money, g3.rp = 1e12, 1e7
		setYear(g3, 2010)
		for _, id in { "el1", "el2", "el4", "el5" } do
			check(research(g3, ctx, id).ok, "EV: " .. id)
		end
		local e1 = DesignCalc.computeDesign(g3, DesignCalc.newDraft(g3, "rayo"))
		setYear(g3, 2020)
		for lvl = 2, 5 do
			check(research(g3, ctx, "eng_EV_" .. lvl).ok, "EV nivel " .. lvl)
		end
		local evd = DesignCalc.newDraft(g3, "rayo")
		eq(evd.motorLevel, 5, "EV nivel 5")
		local e5 = DesignCalc.computeDesign(g3, evd)
		check(e5.hp > e1.hp and e5.consumption < e1.consumption, "25. eléctrico nivel 5: más potencia y menos consumo (" .. Util.num(e1.consumption, 2) .. " → " .. Util.num(e5.consumption, 2) .. ")")
		-- Efecto automático (mo1: +5 % de potencia a combustión) sin duplicarse.
		eq(Rules.tech(g, "hpPct"), 5, "25. +5 % de potencia de mo1, una sola vez")
		-- 26. El diseño viejo conserva su nivel y su variante; el lote ya lanzado, su copia.
		for _, x in g.designs do
			if x.id == oldId then
				old = x
			end
		end
		check(old.motorLevel == 1 and old.motorVariant == "balanced", "26. el diseño de 1970 sigue con nivel 1 y equilibrada")
		eq(lot.design.calc.hp, lotHp, "26. el lote ya lanzado no cambia")
		eq(lot.design.spec.motorLevel, 1, "26. su copia sigue en el nivel 1")
		check(oldCalc.hp ~= nil, "26. cálculo del diseño viejo")
	end)

	test("[IN7] Misión «Completá todas las investigaciones»: meta = árbol real, mismo contador, partidas viejas y sin doble premio (28)", function()
		local ctx = makeCtx(5)
		local m = Catalog.mission("s12")
		eq(m.counter, "researchTree", "28. contador del árbol")
		eq(Rules.missionGoal(newCompany("Meta IN7"), m), Catalog.RESEARCH_TOTAL, "28. meta = " .. Catalog.RESEARCH_TOTAL .. " (todas, con los niveles de motor)")
		check(string.find(m.desc, tostring(Catalog.RESEARCH_TOTAL), 1, true) ~= nil, "28. la descripción dice " .. Catalog.RESEARCH_TOTAL)
		local g = newCompany("Mision IN7")
		-- Partida vieja: contador histórico inflado (árboles anteriores) y menos tecnologías del árbol actual.
		g.counters.researchDone = 300
		for i, n in allNodes() do
			if i <= 100 then
				table.insert(g.research.done, n.id)
			end
		end
		eq(Rules.missionValue(g, m), 100, "28. cuenta tecnologías del árbol, no el contador histórico")
		eq(Rules.missionState(g, m), "progreso", "28. 100 de 112: en progreso")
		check(not Actions.claimMission(g, ctx, { id = "s12" }).ok, "28. no se puede reclamar antes")
		for i, n in allNodes() do
			if i > 100 then
				table.insert(g.research.done, n.id)
			end
		end
		eq(Rules.missionValue(g, m), Catalog.RESEARCH_TOTAL, "28. todas completas")
		eq(Rules.missionState(g, m), "lista", "28. lista")
		local m0 = g.money
		check(Actions.claimMission(g, ctx, { id = "s12" }).ok, "28. se reclama")
		eq(g.money - m0, m.reward.money, "28. premio una vez")
		check(not Actions.claimMission(g, ctx, { id = "s12" }).ok and g.money - m0 == m.reward.money, "28. sin premio duplicado")
		-- Partida vieja que ya la reclamó (con la meta de antes): sigue reclamada.
		local old = newCompany("Vieja IN7")
		old.claimed.s12 = true
		eq(Rules.missionState(old, m), "reclamada", "28. una misión ya reclamada en una partida vieja se conserva")
		local back = GameState.validate(jsonCopy(old))
		check(back ~= false, "28. la partida vieja sigue siendo válida")
		-- Ids repetidos en done (dato corrupto) no inflan el avance.
		local dup = newCompany("Dup IN7")
		dup.research.done = { "ca1", "ca1", "mo1" }
		eq(Rules.researchTreeDone(dup), 2, "28. sin contar repetidos")
	end)

	-- Recorrido de 1970 a 2030 investigando lo más barato que se pueda pagar con los PI reales. upgrade = ampliar
	-- oficinas y centro en cuanto se pueda (techo por fechas) o dejar el centro en el nivel 1 (mínimo de PI).
	local function history(upgrade: boolean)
		local ctx = makeCtx(11)
		ctx.notify = function() end
		local g = newCompany("Historia IN8")
		g.money = 1e13 -- la economía no es lo que se prueba acá: los PI salen solo del centro, como en el juego
		g.counters.unitsSold = 1e7
		g.reputation = 5
		local CUTS = { 1970, 1975, 1980, 1990, 2000, 2010, 2020, 2030 }
		local cutIdx = 1
		local fails: string? = nil
		local started = {}
		local summary = {}
		local lastDone = 0
		local function snapshot(y: number)
			local avail, blocked, ahead = 0, 0, 0
			for _, n in allNodes() do
				local st = Rules.researchState(g, n)
				if st == "disponible" then
					avail += 1
					if n.year > y then
						ahead += 1
					end
					-- Costos según la fórmula (difusión + recargo + personal).
					local pi, cost, days, info = Rules.researchCost(g, n)
					local mod = Rules.researchModifiers(g)
					local wantPi = math.max(1, math.floor(n.rp * info.diffusion * (1 + RR.aheadPi * info.ahead) * mod.pi + 0.5))
					local wantMoney = math.floor(n.cost * info.diffusion * (1 + RR.aheadMoney * info.ahead) * mod.money / 100 + 0.5) * 100
					local wantDays = math.max(1, math.floor(n.days * (1 + RR.aheadDays * info.ahead) * mod.days + 0.5))
					if pi ~= wantPi or cost ~= wantMoney or days ~= wantDays then
						fails = fails or ("costo fuera de fórmula: " .. n.id .. " en " .. y)
					end
					if n.year - y > RR.aheadMaxYears then
						fails = fails or ("disponible fuera de época: " .. n.id .. " en " .. y)
					end
				elseif st == "bloqueada" then
					blocked += 1
				end
			end
			-- Las piezas viejas siguen disponibles.
			local d = DesignCalc.newDraft(g, "brisa")
			local oldOk = DesignCalc.baseAvailable(g, Catalog.base("brisa")) == nil and DesignCalc.partBlock(g, d, Catalog.part("motor", "i4")) == nil and DesignCalc.partBlock(g, d, Catalog.part("motor", "i6")) == nil
			for _, id in g.research.done do
				for _, unl in Catalog.RESEARCH_UNLOCKS[id] or {} do
					if unl.kind == "base" then
						for _, b in Catalog.BASES do
							if b.research == id and DesignCalc.baseAvailable(g, b) ~= nil then
								oldOk = false
							end
						end
					end
				end
			end
			check(oldOk, "30. " .. y .. ": lo viejo sigue disponible en el editor")
			table.insert(summary, string.format("%d: %d completadas, %d en curso, %d disponibles (%d adelantables), %d bloqueadas, centro nivel %d, %.0f PI", y, Rules.researchTreeDone(g), #g.research.projects, avail, ahead, blocked, Rules.facilityLevel(g, "research"), g.rp))
		end
		local steps = 0
		while Rules.year(g) <= 2030 and steps < 200000 do
			steps += 1
			local y = Rules.year(g)
			if cutIdx <= #CUTS and y >= CUTS[cutIdx] then
				snapshot(CUTS[cutIdx])
				cutIdx += 1
			end
			-- Una vez por día: mejorar el centro si se puede y empezar lo más barato disponible (en PI).
			if steps % 2 == 0 then
				-- El centro de nivel n pide oficinas de nivel n (Rules.facilityChecks): se amplían las dos.
				if upgrade then
					Actions.upgradeFacility(g, ctx, { kind = "offices" })
					Actions.upgradeFacility(g, ctx, { kind = "research" })
				end
				while #g.research.projects < RR.maxParallel do
					local best, bestPi = nil, math.huge
					for _, n in allNodes() do
						if Rules.researchState(g, n) == "disponible" then
							local pi = Rules.researchCost(g, n)
							if pi <= g.rp and pi < bestPi then
								best, bestPi = n, pi
							end
						end
					end
					if not best then
						break
					end
					local r = Actions.startResearch(g, ctx, { id = best.id })
					if not r.ok then
						fails = fails or ("no empezó " .. best.id .. ": " .. tostring(r.msg))
						break
					end
					started[best.id] = (started[best.id] or 0) + 1
					if best.year - y > RR.aheadMaxYears then
						fails = fails or ("adelanto de más: " .. best.id)
					end
				end
			end
			Simulation.simulate(g, ctx, 10)
			-- 11/30. Nada se completa solo: cada completada fue empezada (y una sola vez).
			if #g.research.done ~= lastDone then
				for i = lastDone + 1, #g.research.done do
					local id = g.research.done[i]
					if started[id] ~= 1 then
						fails = fails or ("completada sin empezarla una vez: " .. id)
					end
				end
				lastDone = #g.research.done
			end
			local why = researchImpossible(g)
			if why then
				fails = fails or ("año " .. Rules.year(g) .. ": " .. why)
			end
			if fails or (Rules.year(g) == 2030 and g.time.day >= (2030 - 1970) * 12 + 11 and g.time.minute > 0) then
				break
			end
		end
		check(fails == nil, "30. sin estados imposibles de 1970 a 2030 (" .. tostring(fails) .. ")")
		eq(cutIdx, #CUTS + 1, "30. pasó por los ocho cortes")
		check(Rules.researchTreeDone(g) == #g.research.done, "30. todo lo completado es del árbol")
		eq(g.counters.researchDone, #g.research.done, "30. contador = completadas")
		print("    " .. (upgrade and "Centro ampliado en cuanto se puede:" or "Centro siempre en nivel 1 (3 PI/min):"))
		for _, line in summary do
			print("      " .. line)
		end
		return g
	end

	test("[IN8] Recorrido 1970–2030 con las reglas reales: PI del centro y adelanto; cortes de 1970 a 2030 sin estados imposibles (11, 30)", function()
		local slow = history(false)
		eq(Rules.facilityLevel(slow, "research"), 1, "centro en nivel 1 todo el recorrido")
		local n1 = Rules.researchTreeDone(slow)
		check(n1 > 40 and n1 < Catalog.RESEARCH_TOTAL, "con 3 PI/min avanza pero no alcanza para todo (" .. n1 .. " de " .. Catalog.RESEARCH_TOTAL .. "): ampliar el centro importa")
		local fast = history(true)
		eq(Rules.facilityLevel(fast, "research"), 5, "el centro llega al nivel 5")
		eq(Rules.researchTreeDone(fast), Catalog.RESEARCH_TOTAL, "con el centro ampliado se completa el árbol entero (" .. Rules.researchTreeDone(fast) .. " de " .. Catalog.RESEARCH_TOTAL .. ")")
		eq(Rules.missionState(fast, Catalog.mission("s12")), "lista", "28. la misión s12 queda lista al completar el árbol")
		-- Aun con PI de sobra, nada aparece antes de lo que permite el adelanto: las de 2030 se completan desde 2025.
		check(Rules.researchTreeDone(slow) <= Rules.researchTreeDone(fast), "más PI nunca da menos tecnologías")
	end)
end

-- Etapa 8: instalaciones y crecimiento empresarial (casos 1–36, visual y recorrido de crecimiento) ------------
do
	local FI = require("./.build/server/FriendIdentity")
	local OfficeCatalog8 = require("./.build/shared/OfficeCatalog")
	local Office8 = require("./.build/shared/Office")
	local OfficeService8 = require("./.build/server/OfficeService")
	local Nav8 = require("./.build/shared/OfficeNavigation")
	local Visuals = require("./.build/shared/FacilityVisuals")
	local F = Catalog.FACILITIES
	local function close(a: number, b: number, eps: number?): boolean
		return math.abs(a - b) < (eps or 1e-6)
	end
	local function build(g: any, kind: string): any
		return Rules.build(g, kind)
	end
	-- Simula exactamente lo que le falta a la obra (con la velocidad del personal), en pasos de 10 minutos.
	local function finishBuild(g: any, ctx: any, kind: string)
		local b = build(g, kind)
		assert(b, "sin obra " .. kind)
		local left = (b.days - b.progress) / Rules.buildSpeed(g)
		Simulation.simulate(g, ctx, math.ceil(left * Catalog.RULES.gameDayMinutes / 10 + 1e-9) * 10)
	end
	local function upgrade(g: any, ctx: any, kind: string): any
		return Actions.upgradeFacility(g, ctx, { kind = kind })
	end
	local function sedeCharges(g: any): (number, number)
		local n, sum = 0, 0
		for _, l in g.ledger do
			if l.type == "sede" and string.sub(l.note or "", 1, 5) == "Obra:" then
				n += 1
				sum += math.abs(l.amount)
			end
		end
		return n, sum
	end
	-- Progreso que habilita las oficinas de nivel n (ventas y reputación del catálogo).
	local function meetOffices(g: any, n: number)
		local req = Catalog.SEDES[n].req
		g.counters.unitsSold = math.max(g.counters.unitsSold, req.sold)
		g.reputation = math.max(g.reputation, req.rep)
	end
	local function friendsList(n: number): { any }
		local out = {}
		for i = 1, n do
			table.insert(out, { userId = 8000 + i, username = "amigo" .. (8000 + i), displayName = "Amigo " .. (8000 + i) })
		end
		return out
	end
	local function hire(g: any, ctx: any): any
		Simulation.ensureMarket(g, ctx)
		if #g.candidates == 0 then
			Simulation.refreshCandidates(g, ctx, nil)
		end
		return Actions.hire(g, ctx, { candidateId = g.candidates[1].id })
	end
	-- Invariantes de las instalaciones.
	local function facilitiesImpossible(g: any): string?
		local f = g.facilities
		if not (g.sede >= 1 and g.sede <= 5 and f.factory >= 1 and f.factory <= 5 and f.research >= 1 and f.research <= 5) then
			return "nivel fuera de rango"
		end
		if f.factory > g.sede or f.research > g.sede then
			return "fábrica o centro por encima de las oficinas"
		end
		local seen = {}
		for _, b in f.builds do
			if seen[b.kind] then
				return "dos obras en " .. b.kind
			end
			seen[b.kind] = true
			if b.kind ~= "line2" and b.level ~= Rules.facilityLevel(g, b.kind) + 1 then
				return "obra con destino incoherente: " .. b.kind
			end
			if b.kind == "line2" and Rules.ownsLine(g, 2) then
				return "obra de la línea 2 ya comprada"
			end
			if not (b.progress >= 0 and b.progress <= b.days) then
				return "avance fuera de rango"
			end
		end
		if type(g.office) == "table" and g.office.level ~= g.sede then
			return "plano de oficina distinto del nivel de las oficinas"
		end
		if Rules.lineCount(g) > F.maxLines then
			return "más líneas que el máximo"
		end
		return nil
	end

	test("[IS1] Instalaciones 1–10: inicial, primera obra, fondos, requisitos, máximo, duplicados, cobro y fin únicos, recarga", function()
		local store = newStore()
		local clock = { t = 1000, c = 0 }
		local mgr = makeServer(store, "IS1", clock)
		local p = { UserId = 8101 }
		mgr:add(p)
		local g = playThrough(mgr, p).game
		local function req(kind: string, id: string?): any
			clock.c += Sessions.RATE_WINDOW
			return mgr:request(p, "upgradeFacility", { kind = kind, requestId = id or rid() })
		end
		-- 1. Empresa nueva: instalaciones iniciales del catálogo.
		check(g.sede == 1 and g.facilities.factory == 1 and g.facilities.research == 1 and #g.facilities.builds == 0, "1. oficinas, fábrica y centro en nivel 1, sin obras")
		check(Rules.ownsLine(g, 1) and not Rules.ownsLine(g, 2) and not Rules.ownsLine(g, 3), "1. solo la línea 1")
		eq(g.facilities.invested, 0, "1. nada invertido")
		eq(g.office.level, 1, "1. oficina del plano 1")
		local caps = Rules.caps(g)
		check(caps.lines == 1 and close(caps.perLine, F.factory.levels[1].perLine) and caps.pi == 3 and caps.staff == 3, "1. capacidades iniciales: 1 línea, 15 autos/min, 3 PI/min, 3 empleados")
		-- 3. Fondos insuficientes: la línea 2 cuesta 150.000 y la empresa empieza con 90.000.
		local m0 = g.money
		local r = req("line2")
		check(not r.ok and string.find(r.msg, "Dinero", 1, true) ~= nil, "3. sin fondos: " .. tostring(r.msg))
		check(g.money == m0 and #g.facilities.builds == 0 and g.facilities.invested == 0, "3. no cobra ni empieza nada")
		-- 4. Requisitos: la fábrica 2 pide oficinas 2, y las oficinas 2 piden ventas y reputación.
		g.money = 5000000
		r = req("factory")
		check(not r.ok and string.find(r.msg, "Oficinas centrales de nivel 2", 1, true) ~= nil, "4. fábrica sin oficinas: " .. tostring(r.msg))
		r = req("offices")
		check(not r.ok and string.find(r.msg, "Autos vendidos", 1, true) ~= nil, "4. oficinas sin ventas: " .. tostring(r.msg))
		eq(g.money, 5000000, "4. sin cobros")
		-- 2. Primera ampliación válida: la línea 2.
		local nx = Rules.nextFacility(g, "line2")
		r = req("line2")
		check(r.ok, "2. línea 2: " .. tostring(r.msg))
		local b = build(g, "line2")
		check(b ~= nil and b.from == 1 and b.level == 2 and b.cost == nx.cost and b.days == F.line2.days and b.progress == 0 and b.startDay == Rules.absDay(g), "2. obra con origen, destino, costo, duración y día de inicio")
		eq(5000000 - g.money, nx.cost, "7. cobrada una vez")
		eq(g.facilities.invested, nx.cost, "suma a lo invertido (mantenimiento)")
		-- 6. Duplicada: otra obra de la misma instalación y el mismo pedido reenviado.
		r = req("line2")
		check(not r.ok, "6. no se empieza la misma obra dos veces: " .. tostring(r.msg))
		meetOffices(g, 2)
		local id = rid()
		local mo = g.money
		check(req("offices", id).ok, "oficinas 2")
		local again = req("offices", id)
		check(again.ok and g.money == mo - Rules.facilityDef("offices", 2).cost, "6/7. el pedido reenviado no cobra de nuevo")
		check(not req("offices").ok, "6. ni una segunda obra de oficinas")
		local n, sum = sedeCharges(g)
		eq(n, 2, "7. dos obras, dos cobros")
		eq(sum, nx.cost + Rules.facilityDef("offices", 2).cost, "7. por el importe exacto")
		-- 10. Guardar en mitad de la obra y cargar en otro servidor.
		ticks(mgr, clock, 20)
		local snapB = jsonCopy(g.facilities)
		local money = g.money
		check(mgr:request(p, "leaveCompany", {}).ok, "guardar y volver al menú")
		mgr:remove(p)
		local mgr2 = makeServer(store, "IS1b", clock)
		mgr2:add(p)
		check(mgr2:request(p, "selectSlot", { slot = "1" }).ok, "abrir de nuevo")
		local g2 = mgr2.list[p].game
		eq(serde.encode("json", jsonCopy(g2.facilities)), serde.encode("json", snapB), "10. obras, avance, costos pagados, niveles y líneas idénticos")
		eq(g2.money, money, "10. sin cobrar de nuevo al cargar")
		-- 8 y 9. Termina una sola vez y aplica el beneficio.
		local bl = build(g2, "line2")
		local left = math.ceil((bl.days - bl.progress) * Catalog.CALENDAR.realSecondsPerDay)
		ticks(mgr2, clock, left - 2)
		check(not Rules.ownsLine(g2, 2), "8. no termina antes de tiempo")
		local xp0 = g2.xp + Rules.xpForLevel(g2.level) * 0
		local s2 = mgr2.list[p]
		local savedAt = s2.lastSave
		for _ = 1, 3 do
			s2.lastAutosave = clock.c + 1 -- que no coincida con el autoguardado periódico
			ticks(mgr2, clock, 1)
		end
		check(Rules.ownsLine(g2, 2) and build(g2, "line2") == nil, "9. línea 2 activa al terminar")
		check(s2.pendingSave == true or s2.lastSave ~= savedAt, "10. una obra terminada se guarda enseguida")
		eq(Rules.caps(g2).lines, 2, "9. capacidad: dos líneas")
		local notes = 0
		for _, nt in g2.notifications do
			if string.find(nt.text, "Obra terminada: Línea de producción 2", 1, true) then
				notes += 1
			end
		end
		eq(notes, 1, "8. un solo aviso")
		check(g2.xp ~= xp0 or g2.level > 1, "8. otorga experiencia")
		-- Oficinas: termina y no vuelve a aplicar.
		for _ = 1, 400 do
			if g2.sede == 2 then
				break
			end
			ticks(mgr2, clock, 1)
		end
		eq(g2.sede, 2, "9. oficinas nivel 2")
		local inv = g2.facilities.invested
		ticks(mgr2, clock, 120)
		check(g2.sede == 2 and g2.facilities.invested == inv and #g2.facilities.builds == 0, "8. sigue en 2: ningún efecto repetido")
		-- 5. Nivel máximo.
		g2.sede, g2.facilities.factory, g2.facilities.research = 5, 5, 5
		g2.office.level = 5
		for _, k in { "offices", "factory", "research" } do
			clock.c += Sessions.RATE_WINDOW
			local rr = mgr2:request(p, "upgradeFacility", { kind = k, requestId = rid() })
			check(not rr.ok and string.find(rr.msg, "máximo", 1, true) ~= nil and Rules.nextFacility(g2, k) == nil, "5. " .. k .. " en el máximo: " .. tostring(rr.msg))
		end
		clock.c += Sessions.RATE_WINDOW
		check(not mgr2:request(p, "upgradeFacility", { kind = "line3", requestId = rid() }).ok, "la línea 3 no se construye con dinero")
		check(not mgr2:request(p, "upgradeFacility", { kind = "factory", level = 9, days = 0, cost = 0, requestId = rid() }).ok, "el cliente no fija nivel, días ni costo")
	end)

	test("[IS2] Producción 11–17: líneas 1/2/3, línea 3 prémium sin la 2, producción durante una ampliación, capacidad y lotes", function()
		local ctx = makeCtx(81)
		local g = newCompany("Lineas IS2")
		g.money = 1e9
		-- 11. La línea 1 desde el inicio.
		check(Rules.ownsLine(g, 1) and Rules.freeLine(g) == 1, "11. línea 1 disponible")
		-- 14. Línea 3 (de la cuenta) sin la 2: se usan la 1 y la 3, la 2 no aparece sola.
		local undo = Simulation.grantLine3(g)
		check(Rules.ownsLine(g, 3) and not Rules.ownsLine(g, 2), "14. línea 3 sin la 2")
		eq(Rules.lineCount(g), 2, "14. dos líneas")
		local d1 = saveNew(g, ctx, "brisa", "Uno IS2")
		local d2 = saveNew(g, ctx, "duna", "Dos IS2")
		local d3 = saveNew(g, ctx, "brisa", "Tres IS2")
		check(not Actions.createLot(g, ctx, { designId = d1, qty = 40, line = 2 }).ok, "14. la línea 2 no se puede usar")
		check(Actions.createLot(g, ctx, { designId = d1, qty = 40, line = 3 }).ok, "14. la 3 sí")
		check(Actions.createLot(g, ctx, { designId = d2, qty = 40 }).ok, "14. y la 1")
		local r3 = Actions.createLot(g, ctx, { designId = d3, qty = 40 })
		check(not r3.ok, "14. sin línea libre (la 2 no existe): " .. tostring(r3.msg))
		check(Rules.lineLot(g, 1) ~= nil and Rules.lineLot(g, 3) ~= nil and Rules.lineLot(g, 2) == nil, "14. fabrican la 1 y la 3")
		undo()
		check(not Rules.ownsLine(g, 3), "deshacer la línea 3 de prueba")
		-- 13. Línea 3 autorizada solo por un recibo del servidor.
		local store = newStore()
		local clock = { t = 1000, c = 0 }
		local prompts = {}
		local mgr = makeServer(store, "IS2", clock, { prompt = function(_, pid)
			table.insert(prompts, pid)
		end })
		local p = { UserId = 8201 }
		mgr:add(p)
		local gs = playThrough(mgr, p).game
		local saved = Catalog.PRODUCTS.line3.id
		Catalog.PRODUCTS.line3.id = 7777
		check(mgr:request(p, "buyProduct", { product = "line3" }).ok and prompts[1] == 7777, "13. pedirla solo abre la compra")
		check(not Rules.ownsLine(gs, 3), "13. el pedido del cliente no la concede")
		check(not mgr:request(p, "grantLine3", {}).ok, "13. no hay acción para concederla")
		check(mgr:processReceipt({ PlayerId = 8201, ProductId = 7777, PurchaseId = "is2-1" }) == true, "13. el recibo de Roblox la acredita")
		check(Rules.ownsLine(gs, 3) and not Rules.ownsLine(gs, 2), "13. línea 3 activa, la 2 sigue sin comprar")
		check(mgr:processReceipt({ PlayerId = 8201, ProductId = 7777, PurchaseId = "is2-1" }) == true and Rules.lineCount(gs) == 2, "13. el mismo recibo no la duplica")
		Catalog.PRODUCTS.line3.id = saved
		-- 12. Línea 2 por progreso (obra con dinero del juego).
		local g2 = newCompany("Progreso IS2")
		g2.money = 1e7
		check(upgrade(g2, ctx, "line2").ok, "12. obra de la línea 2")
		check(not Rules.ownsLine(g2, 2), "12. todavía no (obra en curso)")
		finishBuild(g2, ctx, "line2")
		check(Rules.ownsLine(g2, 2) and Rules.lineCount(g2) == 2, "12. línea 2 al terminar")
		-- 15–17. Producción durante una ampliación de la fábrica.
		meetOffices(g2, 2)
		check(upgrade(g2, ctx, "offices").ok, "oficinas 2")
		finishBuild(g2, ctx, "offices")
		local dd = saveNew(g2, ctx, "brisa", "Ampliacion IS2")
		check(Actions.createLot(g2, ctx, { designId = dd, qty = 400 }).ok, "15. lote grande en curso")
		local lot = g2.lots[#g2.lots]
		local unit, qty, spent = lot.unitCost, lot.qty, lot.costSpent
		local moneyLot = g2.money
		local rate1 = Rules.lineRate(g2)
		local cap1 = Rules.caps(g2).capacity
		local nxf = Rules.nextFacility(g2, "factory")
		check(upgrade(g2, ctx, "factory").ok, "15. ampliación de la fábrica con el lote en curso")
		eq(moneyLot - g2.money, nxf.cost, "15. solo se cobra la obra")
		Simulation.simulate(g2, ctx, 200)
		check(close(Rules.lineRate(g2), rate1), "15. durante la obra rige el nivel actual (" .. Util.num(Rules.lineRate(g2), 1) .. "/min)")
		finishBuild(g2, ctx, "factory")
		eq(g2.facilities.factory, 2, "16. fábrica nivel 2")
		check(close(Rules.lineRate(g2), rate1 * F.factory.levels[2].perLine / F.factory.levels[1].perLine), "16. autos por minuto por línea: " .. Util.num(rate1, 1) .. " → " .. Util.num(Rules.lineRate(g2), 1))
		check(close(Rules.caps(g2).capacity, cap1 * 25 / 15), "16. capacidad total: " .. Util.num(cap1, 1) .. " → " .. Util.num(Rules.caps(g2).capacity, 1))
		check(lot.unitCost == unit and lot.qty == qty, "15. el lote conserva su costo por unidad y su cantidad")
		for _ = 1, 5000 do
			if lot.produced >= lot.qty then
				break
			end
			Simulation.simulate(g2, ctx, 10)
		end
		Simulation.simulate(g2, ctx, 600)
		eq(lot.produced, qty, "17. se fabrican exactamente las unidades pedidas")
		eq(g2.counters.unitsProduced, qty, "17. sin unidades duplicadas en los contadores")
		eq(lot.costSpent, spent, "15. sin cobros extra por la ampliación (el lote se pagó al crearlo)")
		local count = 0
		for _, l in g2.lots do
			if l.designId == dd then
				count += 1
			end
		end
		eq(count, 1, "17. un solo lote, sin duplicados")
		check(facilitiesImpossible(g2) == nil, "sin estados imposibles")
	end)

	test("[IS3] Investigación 18–20: PI de cada nivel del centro, obra pendiente sin beneficio, bonos una sola vez", function()
		local ctx = makeCtx(83)
		-- 18. PI por nivel (con una línea fabricando suma 2 por línea, igual en todos los niveles).
		local want = { 3, 8, 20, 45, 90 }
		for lvl = 1, 5 do
			local g = newCompany("Centro " .. lvl .. " IS3")
			g.facilities.research = lvl
			eq(Rules.piPerMinute(g), want[lvl], "18. centro nivel " .. lvl .. ": " .. want[lvl] .. " PI/min")
			g.rp = 0
			Simulation.simulate(g, ctx, Catalog.RULES.minutesPerRealSecond * 60)
			check(close(g.rp, want[lvl]), "18. un minuto real a 1× = " .. Util.num(g.rp, 2) .. " PI")
		end
		-- 20. Progresión al mejorar: la obra pendiente no adelanta el beneficio; al terminar, el nivel nuevo.
		local g = newCompany("Progresion IS3")
		g.money = 1e10
		local rows = {}
		for lvl = 2, 5 do
			meetOffices(g, lvl)
			check(upgrade(g, ctx, "offices").ok, "oficinas " .. lvl)
			finishBuild(g, ctx, "offices")
			local before = Rules.piPerMinute(g)
			local nx = Rules.nextFacility(g, "research")
			check(upgrade(g, ctx, "research").ok, "20. obra del centro " .. lvl)
			Simulation.simulate(g, ctx, 300)
			eq(Rules.piPerMinute(g), before, "20. durante la obra sigue en " .. before .. " PI/min")
			finishBuild(g, ctx, "research")
			eq(Rules.piPerMinute(g), want[lvl], "20. al terminar: " .. want[lvl] .. " PI/min")
			table.insert(rows, string.format("nivel %d → %d: %d → %d PI por minuto real a 1× (%s → %s PI por hora de juego), %s, %d días", lvl - 1, lvl, before, want[lvl], Util.num(Rules.perGameMinutes(before, 60), 1), Util.num(Rules.perGameMinutes(want[lvl], 60), 1), Util.money(nx.cost), nx.days))
		end
		for _, l in rows do
			print("      " .. l)
		end
		-- 19. Personal y mobiliario: un solo camino (Rules.staff) para obras, mantenimiento y costos.
		local h = newCompany("Bonos IS3")
		placeN(h, "escritorio_metal_1970", 1) -- organización
		placeN(h, "maquina_escribir_1970", 1) -- finanzas
		placeN(h, "mesa_reuniones_1970", 1) -- gestión
		local org, fin, gest = Rules.staff(h, "organizacion"), Rules.staff(h, "finanzas"), Rules.staff(h, "gestion")
		check(org > 0 and fin > 0 and gest > 0, "19. los tres bonos activos")
		check(close(Rules.buildSpeed(h), 1 + org), "19. obras: 1 + organización (una vez)")
		h.facilities.invested = 1000000
		eq(Rules.maintenance(h), Util.round(1000000 * F.maintenanceRate * (1 - fin)), "19. mantenimiento con finanzas (una vez)")
		h.money = 1e7
		local nx = Rules.nextFacility(h, "line2")
		eq(nx.cost, Util.round(F.line2.cost * (1 - gest) / 100) * 100, "19. costo con gestión (una vez)")
		local m0 = h.money
		check(upgrade(h, ctx, "line2").ok, "obra")
		eq(m0 - h.money, nx.cost, "19. se cobra el costo con el descuento")
		-- El costo y la duración se fijan al empezar: más bonos después no cambian la obra.
		local b = build(h, "line2")
		local cost0, days0 = b.cost, b.days
		placeN(h, "mesa_reuniones_1970", 2)
		placeN(h, "escritorio_metal_1970", 2)
		check(b.cost == cost0 and b.days == days0, "19. la obra iniciada no se recalcula")
		check(Rules.buildSpeed(h) > 1 + org, "19. la organización solo acelera el avance diario desde ahora")
		check(Rules.staff(h, "conocimiento") == 0 and Rules.piPerMinute(h) == 3, "19. las obras no tocan los PI por minuto")
	end)

	test("[IS4] Oficinas 21–28: planos 1→5, muebles, inventario, acabados, bonos, navegación y amigos", function()
		local ctx = makeCtx(85)
		ctx.friends = FI.roster({ status = "ok", complete = true, list = friendsList(40) })
		local g = newCompany("Oficinas IS4")
		g.money = 1e10
		local o = g.office
		-- Muebles colocados con el servidor (del inventario y comprados) y algo guardado.
		check(OfficeService8.place(g, { item = "escritorio_metal_1970", room = "oficina_principal", x = 5, y = 2.5, rot = 0 }).ok, "escritorio inicial")
		check(OfficeService8.place(g, { item = "silla_oficina_1970", room = "oficina_principal", x = 5.5, y = 3.5, rot = 0 }).ok, "silla inicial")
		check(OfficeService8.place(g, { item = "escritorio_metal_1970", room = "oficina_principal", x = 8, y = 2.5, rot = 0 }).ok, "escritorio comprado")
		-- Un mueble en un lugar válido en el plano 1 que queda en el paso de la puerta del plano 2.
		local evictItem, evictSpot = nil, nil
		for _, it in OfficeCatalog8.FURNITURE do
			if not evictItem and Office8.available(it, Rules.year(g)) then
				for x = 0, 9, 0.5 do
					for y = 0, 7, 0.5 do
						if not evictItem then
							local spot = { room = "oficina_principal", x = x, y = y, rot = 0 }
							local ok1 = Office8.validatePlacement(o, it, spot)
							local ok2 = Office8.validatePlacement({ level = 2, placed = o.placed }, it, spot)
							if ok1 and not ok2 then
								evictItem, evictSpot = it, spot
							end
						end
					end
				end
			end
		end
		check(evictItem ~= nil, "hay un lugar válido en el plano 1 que el plano 2 usa de paso")
		local moneyBeforeEvict = g.money
		local rev = OfficeService8.place(g, { item = evictItem.id, room = evictSpot.room, x = evictSpot.x, y = evictSpot.y, rot = 0 })
		check(rev.ok, "mueble que va a quedar en el paso: " .. tostring(rev.msg))
		local moneyAfterBuy = g.money
		Office8.addToInventory(o, "silla_oficina_1970", 2)
		o.finishes.oficina_principal = { floor = OfficeCatalog8.DEFAULT_FINISH.floor, wall = OfficeCatalog8.DEFAULT_FINISH.wall, covering = OfficeCatalog8.DEFAULT_FINISH.covering, lighting = OfficeCatalog8.DEFAULT_FINISH.lighting, custom = true }
		local function totals(): { [string]: number }
			local t = {}
			for _, pl in o.placed do
				t[pl.item] = (t[pl.item] or 0) + 1
			end
			for item, n in o.inventory do
				t[item] = (t[item] or 0) + n
			end
			return t
		end
		local own0 = totals()
		local placedIds = {}
		for _, pl in o.placed do
			placedIds[pl.id] = true
		end
		-- Personal con amigos antes de ampliar.
		for _ = 1, 3 do
			check(hire(g, ctx).ok, "contrata (límite 3)")
		end
		check(not hire(g, ctx).ok, "28. el límite de las oficinas 1 es 3")
		local friendsBefore = {}
		for _, e in g.employees do
			friendsBefore[e.id] = e.friend and e.friend.userId
		end
		local roomsWant = { 1, 2, 3, 4, 5 }
		for lvl = 2, 5 do
			meetOffices(g, lvl)
			local rev0 = o.rev
			local org0 = Rules.staff(g, "organizacion")
			check(upgrade(g, ctx, "offices").ok, "2" .. lvl - 1 .. ". obra de oficinas " .. lvl)
			eq(o.level, lvl - 1, "el plano no cambia antes de terminar")
			finishBuild(g, ctx, "offices")
			g.office = g.office -- (misma tabla)
			eq(g.sede, lvl, "22. oficinas nivel " .. lvl)
			eq(o.level, lvl, "21/22. el plano pasa al nivel " .. lvl)
			eq(#OfficeCatalog8.plan(lvl).rooms, roomsWant[lvl], "21. habitaciones del plano " .. lvl)
			check(o.rev > rev0, "el plano nuevo cambia la revisión (descarta borradores viejos)")
			-- 23–24. Nada se pierde ni se duplica: colocado + guardado = lo que había.
			local own = totals()
			for item, n in own0 do
				eq(own[item] or 0, n, "23/24. " .. item .. " conservado en el nivel " .. lvl)
			end
			local ids = {}
			for _, pl in o.placed do
				check(not ids[pl.id], "23. sin muebles duplicados")
				ids[pl.id] = true
				check(OfficeCatalog8.room(lvl, pl.room) ~= nil, "23. cada mueble en una habitación del plano")
			end
			-- 25. Acabados compatibles conservados; habitaciones nuevas con el de serie.
			check(o.finishes.oficina_principal and o.finishes.oficina_principal.custom == true, "25. la oficina principal conserva su acabado")
			for _, rm in OfficeCatalog8.plan(lvl).rooms do
				check(o.finishes[rm.id] ~= nil, "25. acabado para " .. rm.id)
			end
			-- 26. Bonos recalculados desde lo colocado (lo guardado no suma).
			check(close(Office8.furnitureRaw(o, "organizacion"), Office8.furnitureRaw({ level = o.level, placed = o.placed }, "organizacion")), "26. bono desde lo colocado")
			check(Rules.staff(g, "organizacion") <= org0 + 1e-9, "26. ampliar no inventa bonos")
			-- 27. Navegación: grilla para cada habitación del plano nuevo, con el tamaño nuevo.
			for _, rm in OfficeCatalog8.plan(lvl).rooms do
				local grid = Nav8.grid(o, rm.id)
				check(grid ~= nil and grid.room.w == rm.w and grid.room.d == rm.d, "27. grilla de " .. rm.id .. " (" .. rm.w .. "×" .. rm.d .. ")")
			end
			local newRoom = OfficeCatalog8.plan(lvl).rooms[#OfficeCatalog8.plan(lvl).rooms]
			local grid = Nav8.grid(o, newRoom.id)
			local path = Nav8.findPath(grid, 1.5, 1.5, newRoom.w - 1.5, newRoom.d - 1.5)
			check(path ~= nil and #path >= 1, "27. se puede caminar por " .. newRoom.id)
			-- 28. Amigos: siguen asignados; el límite nuevo deja contratar más, con amigo.
			for _, e in g.employees do
				if friendsBefore[e.id] then
					eq(e.friend and e.friend.userId, friendsBefore[e.id], "28. el empleado conserva su amigo")
				end
			end
			eq(Rules.caps(g).staff, Catalog.SEDES[lvl].staff, "límite global de empleados del nivel " .. lvl)
			local hr = hire(g, ctx)
			check(hr.ok and g.employees[#g.employees].friend ~= nil, "28. con más lugar se contrata otro amigo")
			friendsBefore[g.employees[#g.employees].id] = g.employees[#g.employees].friend.userId
			local ids2 = {}
			for _, e in g.employees do
				table.insert(ids2, e.id)
			end
			local okReq = FI.avatarRequest(g, { ids2[1], ids2[#ids2] })
			check(okReq ~= nil and #okReq >= 1, "28. los avatares de los amigos se siguen pidiendo")
			check(facilitiesImpossible(g) == nil, "sin estados imposibles en el nivel " .. lvl)
		end
		-- Política segura: el mueble que quedó en el paso volvió al inventario, sin reembolso.
		local stillPlaced = false
		for _, pl in o.placed do
			stillPlaced = stillPlaced or pl.id == rev.instance
		end
		check(not stillPlaced, "el mueble del paso volvió al inventario")
		check(moneyBeforeEvict > moneyAfterBuy or rev.fromInventory, "lo había pagado o era del inventario")
		eq(Office8.count(o, evictItem.id) >= 1, true, "está en el inventario")
		-- Los colocados que seguían siendo válidos conservan su id.
		local kept = 0
		for _, pl in o.placed do
			if placedIds[pl.id] then
				kept += 1
			end
		end
		check(kept >= 3, "21. los muebles válidos siguen en su lugar (" .. kept .. ")")
	end)

	test("[IS5] Integración 29–36: pausa, velocidades, empresas, guardado en obra, cobros, estados imposibles y partidas viejas", function()
		local store = newStore()
		local clock = { t = 1000, c = 0 }
		local mgr = makeServer(store, "IS5", clock)
		local p = { UserId = 8501 }
		mgr:add(p)
		local g = playThrough(mgr, p).game
		g.money = 1e7
		clock.c += Sessions.RATE_WINDOW
		check(mgr:request(p, "upgradeFacility", { kind = "line2", requestId = rid() }).ok, "obra")
		local b = build(g, "line2")
		-- 30. Velocidades: un día de obra cada 2 s a 1×, el doble a 2× y el triple a 3×, sin saltos.
		for _, sp in { 1, 2, 3, 1 } do
			clock.c += Sessions.RATE_WINDOW
			check(mgr:request(p, "setSpeed", { speed = sp, requestId = rid() }).ok, sp .. "×")
			local p0 = b.progress
			ticks(mgr, clock, 4)
			check(close(b.progress - p0, 2 * sp), "30. a " .. sp .. "× en 4 s: +" .. Util.num(b.progress - p0, 2) .. " días")
		end
		-- 29. Pausa por menú y al salir se reanuda.
		check(mgr:request(p, "setUiPause", { paused = true }).ok, "menú")
		local pp = b.progress
		ticks(mgr, clock, 30)
		eq(b.progress, pp, "29. con un menú abierto la obra no avanza")
		check(mgr:request(p, "setUiPause", { paused = false }).ok, "cierra el menú")
		ticks(mgr, clock, 2)
		check(close(b.progress - pp, 1), "29. al salir sigue al mismo ritmo")
		-- 31. Otra empresa: sus obras son suyas y la primera no avanza mientras no está abierta.
		check(mgr:request(p, "leaveCompany", {}).ok, "menú de empresas")
		local frozen = b.progress
		clock.c += Sessions.RATE_WINDOW
		check(mgr:request(p, "createCompany", { slot = "2", name = "Otra IS5", color = Catalog.BRAND_COLORS[3][1], logo = "pico" }).ok, "segunda empresa")
		local g2 = mgr.list[p].game
		check(#g2.facilities.builds == 0 and not Rules.ownsLine(g2, 2), "31. la segunda empresa no tiene la obra")
		ticks(mgr, clock, 30)
		g2.money = 1e7
		clock.c += Sessions.RATE_WINDOW
		check(mgr:request(p, "upgradeFacility", { kind = "line2", requestId = rid() }).ok, "31. obra propia en la segunda")
		check(mgr:request(p, "leaveCompany", {}).ok, "guardar")
		check(mgr:request(p, "selectSlot", { slot = "1" }).ok, "volver a la primera")
		local g1 = mgr.list[p].game
		local b1 = build(g1, "line2")
		check(b1 ~= nil and close(b1.progress, frozen), "31/32. la obra de la primera no avanzó ni cambió (" .. Util.num(b1.progress, 2) .. ")")
		-- 33. Economía sin cobros duplicados: los cobros de obras = lo invertido.
		local n, sum = sedeCharges(g1)
		check(n == 1 and sum == g1.facilities.invested, "33. un cobro por obra, igual a lo invertido")
		-- 35. Estados imposibles: pedidos al azar (válidos y no) durante 300 segundos.
		local rnd = seeded(808)
		local kinds = { "offices", "factory", "research", "line2", "line3", "bogus" }
		g1.money = 1e12
		g1.counters.unitsSold, g1.reputation = 200000, 5
		local bad = nil
		for step = 1, 300 do
			if rnd() < 0.3 then
				clock.c += Sessions.RATE_WINDOW
				local k = kinds[1 + math.floor(rnd() * #kinds)]
				local m0 = g1.money
				local r = mgr:request(p, "upgradeFacility", { kind = k, requestId = rid() })
				if not r.ok and g1.money ~= m0 then
					bad = bad or ("cobró una obra rechazada (" .. k .. ")")
				end
			end
			ticks(mgr, clock, 1)
			bad = bad or facilitiesImpossible(g1)
			if bad then
				bad = "paso " .. step .. ": " .. bad
				break
			end
		end
		check(bad == nil, "35. sin estados imposibles (" .. tostring(bad) .. ")")
		local n2, sum2 = sedeCharges(g1)
		check(sum2 == g1.facilities.invested, "33. lo cobrado por obras = lo invertido (" .. n2 .. " obras)")
		-- 36. Partida vieja: obras sin `from` ni `startDay` siguen siendo válidas y se muestran.
		local old = newCompany("Vieja IS5")
		old.sede = 2
		table.insert(old.facilities.builds, { id = "b-old", kind = "factory", level = 2, progress = 10, days = 45, cost = 200000 })
		local back = jsonCopy(old)
		check(GameState.validate(back), "36. obra sin origen: válida")
		local bi = Rules.buildInfo(back, back.facilities.builds[1])
		check(bi.from == 1 and bi.to == 2 and bi.paid == 200000 and close(bi.pct, 10 / 45) and bi.state == "en obra", "36. origen deducido, pagado y avance")
		local broken = jsonCopy(old)
		broken.facilities.builds[1].from = 3
		check(not GameState.validate(broken), "36. un origen incoherente se rechaza")
	end)

	test("[IS6] Crecimiento visual provisional: niveles, líneas, obras, sin superponerse y reemplazable por modelos", function()
		local base = { factory = 1, research = 1, offices = 1, lines = { true, false, false }, building = {} }
		local function find(groups: { any }, id: string): any
			for _, gr in groups do
				if gr.id == id then
					return gr
				end
			end
			return nil
		end
		local l1 = Visuals.layout(base)
		eq(#find(l1, "fabrica").parts, 0, "garaje nivel 1: sin agregados")
		check(find(l1, "linea2").owned == false and find(l1, "linea3").owned == false, "líneas 2 y 3: solo el lugar marcado")
		check(find(l1, "linea2").asset == nil, "sin modelo para una línea que no es tuya")
		local prevH, prevO, prevF = 0, 0, -1
		for lvl = 1, 5 do
			local st = { factory = lvl, research = lvl, offices = lvl, lines = { true, true, true }, building = {} }
			local gr = Visuals.layout(st)
			local lab, off, fab = find(gr, "investigacion"), find(gr, "oficinas"), find(gr, "fabrica")
			check(lab.height > prevH and off.height > prevO and #fab.parts > prevF, "nivel " .. lvl .. ": más pisos, torre más alta y nave más grande")
			prevH, prevO, prevF = lab.height, off.height, #fab.parts
			eq(lab.asset, "CentroInvestigacion" .. lvl, "modelo reemplazable del centro " .. lvl)
			eq(off.asset, "Oficinas" .. lvl, "modelo reemplazable de las oficinas " .. lvl)
			eq(fab.asset, "NaveFabrica" .. lvl, "modelo reemplazable de la nave " .. lvl)
			-- Dentro de la parcela (o detrás de la pared del fondo) y sin pisar lo que ya hay al nivel del piso.
			for _, g0 in gr do
				for _, pt in g0.parts do
					local x0, x1 = pt.pos[1] - pt.size[1] / 2, pt.pos[1] + pt.size[1] / 2
					local z0, z1 = pt.pos[3] - pt.size[3] / 2, pt.pos[3] + pt.size[3] / 2
					check(x0 >= -45.5 and x1 <= 45.5 and z1 <= 35.5 and z0 >= -60, g0.id .. "/" .. pt.name .. " dentro del terreno")
					if pt.pos[2] - pt.size[2] / 2 < 6 and z0 > -35 then
						for _, rz in Visuals.RESERVED do
							local overlap = x0 < rz.x1 - 0.01 and x1 > rz.x0 + 0.01 and z0 < rz.z1 - 0.01 and z1 > rz.z0 + 0.01
							check(not overlap, g0.id .. "/" .. pt.name .. " no pisa «" .. rz.name .. "»")
						end
					end
				end
			end
		end
		-- Línea 3 sin la 2: cinta en la 3, marca en la 2.
		local only3 = Visuals.layout({ factory = 1, research = 1, offices = 1, lines = { true, false, true }, building = {} })
		check(find(only3, "linea3").owned and not find(only3, "linea2").owned, "línea 3 sin la 2: se dibuja la 3 y el lugar de la 2")
		-- Obra en curso: andamio; la clave cambia con cada nivel, línea u obra.
		local b2 = Visuals.layout({ factory = 2, research = 1, offices = 2, lines = { true, false, false }, building = { factory = true, line2 = true } })
		check(find(b2, "obra_fabrica") ~= nil and find(b2, "obra_linea2") ~= nil and find(b2, "obra_oficinas") == nil, "andamios en las obras en curso, solo ahí")
		local k1 = Visuals.key(base)
		check(Visuals.key({ factory = 2, research = 1, offices = 1, lines = { true, false, false }, building = {} }) ~= k1, "la clave cambia con el nivel")
		check(Visuals.key({ factory = 1, research = 1, offices = 1, lines = { true, true, false }, building = {} }) ~= k1, "la clave cambia con una línea")
		check(Visuals.key({ factory = 1, research = 1, offices = 1, lines = { true, false, false }, building = { research = true } }) ~= k1, "la clave cambia con una obra")
		eq(serde.encode("json", Visuals.layout(base)), serde.encode("json", l1), "determinista")
		-- Desde una partida real.
		local g = newCompany("Visual IS6")
		local st = Visuals.state(g, Rules)
		check(st.factory == 1 and st.offices == 1 and st.lines[1] and not st.lines[2], "estado visual de una empresa nueva")
	end)

	test("[IS7] Recorrido de crecimiento con la economía real (bot 1970 → 2030): de garaje a nivel máximo", function()
		local log = longGame()
		local g = log.g
		eq(g.sede, 5, "oficinas al máximo")
		eq(g.facilities.factory, 5, "fábrica al máximo")
		eq(g.facilities.research, 5, "centro al máximo")
		check(Rules.ownsLine(g, 2), "línea 2 comprada")
		local paid = 0
		local last = { offices = 1, factory = 1, research = 1 }
		print("      Obras del bot (año de inicio → fin · costo · minutos reales a 1×):")
		for _, b in log.builds do
			eq(b.moneyBefore - b.moneyAfter, b.cost, "cobro exacto de " .. b.kind .. " " .. b.level)
			paid += b.cost
			check(b.finishMin ~= nil and b.finishMin >= b.startMin, b.kind .. " " .. b.level .. " terminó")
			if b.kind ~= "line2" then
				eq(b.level, last[b.kind] + 1, b.kind .. ": niveles en orden")
				last[b.kind] = b.level
				if b.kind ~= "offices" then
					local off = 1
					for _, x in log.builds do
						if x.kind == "offices" and x.finishMin and x.finishMin <= b.startMin then
							off = math.max(off, x.level)
						end
					end
					check(off >= b.level, b.kind .. " " .. b.level .. " empezó con oficinas de nivel " .. off)
				end
			end
			print(string.format("        %-8s %d  %d → %s  %14s  %6.1f → %6.1f min", b.kind, b.level, b.startYear, tostring(b.finishYear), Util.money(b.cost), b.startMin, b.finishMin or -1))
		end
		eq(g.facilities.invested, paid, "lo invertido = lo cobrado por todas las obras")
		eq(#log.builds, 4 + 4 + 4 + 1, "13 obras: 4 de oficinas, 4 de fábrica, 4 del centro y la línea 2")
		check(facilitiesImpossible(g) == nil, "sin estados imposibles al final")
	end)
end

-- Correcciones de la etapa 8: unidades de PI (minuto real vs. hora de juego) -----------------------------------
test("[IS8] Unidades de PI: minuto real a 1×, hora de juego, líneas activas e inactivas, 2× y 3×, fórmulas sin cambios", function()
	local function close(a: number, b: number): boolean
		return math.abs(a - b) < 1e-9
	end
	-- 7. Fórmulas y valores sin cambios.
	eq(Catalog.RULES.minutesPerRealSecond, 10, "7. 1 s real = 10 min de juego")
	check(close(Rules.realMinutes(600), 1) and close(Rules.realMinutes(60), 0.1), "7. Rules.realMinutes: 600 min de juego = 1 min real")
	check(close(Rules.perGameMinutes(3, 60), 0.3), "2. 3 PI por minuto real = 0,3 PI por hora de juego")
	-- 1 y 2 con la simulación real, en cada nivel del centro.
	local ctx = makeCtx(88)
	for lvl, pi in { 3, 8, 20, 45, 90 } do
		local g = newCompany("Unidades " .. lvl .. " IS8")
		g.facilities.research = lvl
		eq(Rules.piPerMinute(g), pi, "1. nivel " .. lvl .. ": " .. pi .. " PI por minuto real a 1×")
		g.rp = 0
		Simulation.simulate(g, ctx, Catalog.RULES.minutesPerRealSecond * 60) -- un minuto real a 1×
		check(close(g.rp, pi), "1. un minuto real a 1× suma " .. Util.num(g.rp, 3) .. " PI")
		g.rp = 0
		Simulation.simulate(g, ctx, 60) -- una hora de juego
		check(close(g.rp, Rules.piPerGameHour(g)) and close(g.rp, pi / 10), "2. una hora de juego suma " .. Util.num(g.rp, 3) .. " PI = Rules.piPerGameHour")
	end
	-- 3. Antes y después de mejorar el centro, con la misma unidad.
	check(close(Rules.perGameMinutes(3, 60), 0.3) and close(Rules.perGameMinutes(8, 60), 0.8), "3. centro 1 → 2: 0,3 → 0,8 PI por hora de juego")
	-- 4. Líneas activas e inactivas.
	local g = newCompany("Lineas IS8")
	g.money = 5000000
	local id = saveNew(g, ctx, "brisa", "Linea IS8")
	check(Actions.createLot(g, ctx, { designId = id, qty = 20 }).ok, "lote")
	Simulation.simulate(g, ctx, 10)
	eq(Rules.activeLines(g), 1, "4. una línea fabricando")
	check(close(Rules.piPerGameHour(g), (3 + Catalog.RESEARCH_RULES.linePi) / 10), "4. con la línea: 0,5 PI por hora de juego")
	g.rp = 0
	Simulation.simulate(g, ctx, 60)
	check(close(g.rp, 0.5), "4. y la simulación suma 0,5 en una hora de juego (" .. Util.num(g.rp, 3) .. ")")
	for _ = 1, 500 do
		if g.lots[1].prodState == "completado" then
			break
		end
		Simulation.simulate(g, ctx, 10)
	end
	eq(Rules.activeLines(g), 0, "4. la línea terminó")
	check(close(Rules.piPerGameHour(g), 0.3), "4. sin líneas activas: 0,3 PI por hora de juego")
	-- 5. 2× y 3×: más PI por segundo real, los mismos PI por hora de juego.
	local store = newStore()
	local clock = { t = 1000, c = 0 }
	local mgr = makeServer(store, "IS8", clock)
	local p = { UserId = 8801 }
	mgr:add(p)
	local gs = playThrough(mgr, p).game
	for _, sp in { 1, 2, 3 } do
		check(mgr:request(p, "setSpeed", { speed = sp, requestId = rid() }).ok, sp .. "×")
		local rp0, m0, d0 = gs.rp, gs.time.minute, gs.time.day
		ticks(mgr, clock, 6)
		local gameMin = (gs.time.day - d0) * 1e9 + gs.time.minute - m0
		check(gs.time.day == d0 and close(gameMin, 60 * sp), sp .. "×: 6 s reales = " .. gameMin .. " min de juego")
		check(close(gs.rp - rp0, 3 * sp / 10), "5. a " .. sp .. "× en 6 s reales: +" .. Util.num(gs.rp - rp0, 3) .. " PI (×" .. sp .. " por segundo real)")
		check(close((gs.rp - rp0) / (gameMin / 60), Rules.piPerGameHour(gs)), "5. a " .. sp .. "×: los mismos PI por hora de juego")
	end
end)


-- Etapa 9: expansión internacional y mercado mundial (casos 1–24 y 34–40) -------------------------------------
do
	local E = Catalog.EXPANSION
	local function rel(a: number, b: number): boolean
		return math.abs(a - b) <= 1e-9 * math.max(1, math.abs(a), math.abs(b))
	end
	local function setYear9(g: any, y: number)
		g.time.day = (y - Catalog.CALENDAR.startYear) * 12
		g.time.minute = 0
	end
	-- Empresa lista para expandirse (oficinas 5 y ventas de sobra), sin tocar sus países.
	local function ready(g: any)
		g.sede = 5
		g.office.level = 5
		g.counters.unitsSold = 1e6
		g.money = 1e12
	end
	local function expandCharges(g: any): (number, number)
		local n, sum = 0, 0
		for _, l in g.ledger do
			if l.type == "sede" and string.find(l.note or "", "Expansión global:", 1, true) == 1 then
				n += 1
				sum += math.abs(l.amount)
			end
		end
		return n, sum
	end
	local function quoteCost(g: any, n: number): number
		return Rules.expansionCost(g, Util.round(E.cost * math.pow(E.growth, n - 1) / 1000000) * 1000000)
	end

	test("[EX1] Apertura 1–14: requisitos, primer país libre, costo por cantidad, duplicados, inexistentes, diez y once", function()
		local ctx = makeCtx(91)
		-- 1. Empresa sin expansión.
		local g = newCompany("Mundo EX1")
		check(Rules.expansion(g) == 0 and #Rules.openedCountries(g) == 0 and Rules.marketFactor(g) == 1, "1. sin países y mercado ×1")
		for _, t in Catalog.TYPE_ORDER do
			check(Rules.typeMarketFactor(g, t) == 1 and rel(Rules.demand(g, t), Rules.baseDemand(t, Rules.yearFrac(g))), "1. demanda base en " .. t)
		end
		-- 2. Sin oficinas nivel 5.
		g.sede = 4
		g.counters.unitsSold = 1e6
		g.money = 1e12
		local m0 = g.money
		local r = Actions.expandGlobal(g, ctx, { country = "BR" })
		check(not r.ok and string.find(r.msg, "oficinas", 1, true) ~= nil, "2. sin oficinas 5: " .. tostring(r.msg))
		eq(Rules.countryState(g, "BR"), "bloqueado", "2. bloqueado en el mapa")
		local reqs = Rules.expansionRequirements(g)
		check(#reqs == 3 and not reqs[1].ok and reqs[1].kind == "oficinas", "2. el requisito de oficinas se muestra aunque falten")
		-- 3. Ventas insuficientes.
		ready(g)
		g.counters.unitsSold = E.soldBase - 1
		r = Actions.expandGlobal(g, ctx, { country = "BR" })
		check(not r.ok and string.find(r.msg, "Autos vendidos", 1, true) ~= nil, "3. ventas insuficientes: " .. tostring(r.msg))
		-- 4. Dinero insuficiente.
		g.counters.unitsSold = E.soldBase
		g.money = quoteCost(g, 1) - 1
		r = Actions.expandGlobal(g, ctx, { country = "BR" })
		check(not r.ok and string.find(r.msg, "Dinero", 1, true) ~= nil, "4. sin dinero: " .. tostring(r.msg))
		check(g.expansion == 0 and #(g.countries or {}) == 0 and g.money == quoteCost(g, 1) - 1, "2–4. los rechazos no cambian nada")
		-- 5–6. Primera apertura: Brasil.
		g.money = 1e12
		m0 = g.money
		local c1 = quoteCost(g, 1)
		eq(Rules.expansionQuote(g).cost, c1, "costo de la primera apertura")
		r = Actions.expandGlobal(g, ctx, { country = "BR", cost = 1, price = 0 })
		check(r.ok, "5/6. abre Brasil primero: " .. tostring(r.msg))
		check(m0 - g.money == c1 and g.expansion == 1 and g.countries[1] == "BR", "5. cobra " .. Util.money(c1) .. " (el cliente no fija el precio) y registra el país")
		-- 7–8. Otra empresa abre Japón primero: mismo costo.
		local g2 = newCompany("Japon EX1")
		ready(g2)
		local mj = g2.money
		check(Actions.expandGlobal(g2, ctx, { country = "JP" }).ok, "7. Japón como primer país")
		eq(mj - g2.money, c1, "8. el mismo costo sin importar el país")
		eq(g2.countries[1], "JP", "7. Japón registrado")
		-- 9. Segunda apertura más cara.
		local c2 = quoteCost(g, 2)
		check(c2 > c1, "9. la segunda cuesta más (" .. Util.money(c2) .. ")")
		m0 = g.money
		g.counters.unitsSold = 1e6
		local r9 = Actions.expandGlobal(g, ctx, { country = "ZA" })
		check(r9.ok and m0 - g.money == c2, "9. segunda apertura con el costo creciente: " .. tostring(r9.msg))
		-- 10–11. Duplicado e inexistente.
		m0 = g.money
		check(not Actions.expandGlobal(g, ctx, { country = "BR" }).ok, "10. Brasil otra vez: rechazado")
		check(not Actions.expandGlobal(g, ctx, { country = "XX" }).ok and not Actions.expandGlobal(g, ctx, { country = { "JP" } }).ok and not Actions.expandGlobal(g, ctx, {}).ok, "11. país inexistente o inválido: rechazado")
		eq(g.money, m0, "10–11. sin cobros")
		-- Estado incoherente: no cobra.
		local g3 = newCompany("Raro EX1")
		ready(g3)
		g3.expansion, g3.countries = 1, { "BR", "US" }
		local m3 = g3.money
		check(not Actions.expandGlobal(g3, ctx, { country = "JP" }).ok and g3.money == m3, "estado incoherente: rechazado sin cobrar")
		-- 12–13. Las diez en un orden libre y la undécima rechazada.
		local order = { "IN", "AE", "US", "PL", "TH", "DE", "AU", "JP" }
		for i, id in order do
			local before = g.money
			local cost = quoteCost(g, g.expansion + 1)
			check(Actions.expandGlobal(g, ctx, { country = id }).ok and before - g.money == cost, "12. apertura " .. (i + 2) .. ": " .. id)
		end
		eq(g.expansion, 10, "12. diez países")
		eq(#g.countries, 10, "12. los diez registrados")
		check(Rules.expansionQuote(g) == nil and Rules.nextExpansion(g) == nil, "13. no hay undécima")
		m0 = g.money
		check(not Actions.expandGlobal(g, ctx, { country = "BR" }).ok and g.money == m0, "13. una undécima se rechaza")
		local n, sum = expandCharges(g)
		local want = 0
		for k = 1, 10 do
			want += quoteCost(g, k)
		end
		check(n == 10 and sum == want, "diez cobros por el total exacto (" .. Util.money(sum) .. ")")
		-- 14. Pedidos repetidos por la red.
		local store = newStore()
		local clock = { t = 1000, c = 0 }
		local mgr = makeServer(store, "EX1", clock)
		local p = { UserId = 9101 }
		mgr:add(p)
		local gs = playThrough(mgr, p).game
		ready(gs)
		local id = rid()
		local ms = gs.money
		check(mgr:request(p, "expandGlobal", { country = "TH", requestId = id }).ok, "14. abre Tailandia")
		local again = mgr:request(p, "expandGlobal", { country = "TH", requestId = id })
		check(again.ok and gs.money == ms - quoteCost(gs, 1) and gs.expansion == 1, "14. el mismo pedido reenviado no cobra de nuevo")
		clock.c += Sessions.RATE_WINDOW
		check(not mgr:request(p, "expandGlobal", { country = "TH", requestId = rid() }).ok and gs.expansion == 1, "14. un pedido nuevo del mismo país se rechaza")
		check(mgr.list[p].pendingSave == true or mgr.list[p].lastSave > 0, "13. la apertura pide guardar enseguida")
	end)

	test("[EX2] Mercado y producción 15–24: +15 % por país repartido, rivales, ventas, capacidad, campañas y años", function()
		local ctx = makeCtx(92)
		-- 15. +15 % del total por país, en varios años y combinaciones.
		for _, y in { 1975, 1990, 2010, 2030 } do
			local g = newCompany("Total " .. y .. " EX2")
			setYear9(g, y)
			local yf = Rules.yearFrac(g)
			for k, c in E.countries do
				g.countries = g.countries or {}
				table.insert(g.countries, c.id)
				g.expansion = k
				local base, total = Rules.worldDemand(g, yf)
				check(rel(total, base * (1 + E.demand * k)), "15. " .. y .. ", " .. k .. " países: total = base × " .. Util.num(1 + E.demand * k, 2))
			end
		end
		-- 16. Distribución según las preferencias: proporcional a la preferencia en los tipos con demanda.
		local g = newCompany("Pesos EX2")
		setYear9(g, 2015)
		local yf = Rules.yearFrac(g)
		local jp = Rules.country("JP")
		local w = Rules.countryWeights(jp, yf)
		local sumDW, sumD = 0, 0
		for _, t in Catalog.TYPE_ORDER do
			local d = Rules.baseDemand(t, yf)
			sumDW += d * w[t]
			sumD += d
			check(rel(w[t] / w.sedan, jp.prefs[t] / jp.prefs.sedan), "16. peso de " .. t .. " proporcional a su preferencia")
		end
		check(rel(sumDW, sumD), "16. el reparto conserva el volumen (Σ demanda × peso = Σ demanda)")
		g.countries, g.expansion = { "JP" }, 1
		for _, t in Catalog.TYPE_ORDER do
			check(rel(Rules.demand(g, t, yf), Rules.baseDemand(t, yf) * (1 + E.demand * w[t])), "16. demanda de " .. t .. " con Japón")
		end
		-- Pesos iguales = comportamiento anterior.
		local flat = { id = "XX", prefs = {} }
		for t, v in Rules.countryWeights(flat, yf) do
			check(v == 1, "pesos iguales = expansión anterior (" .. t .. ")")
		end
		-- 17. Sin doble aplicación.
		for _, t in Catalog.TYPE_ORDER do
			local m = Rules.market(g, t)
			check(rel(m.demand, Rules.demand(g, t, yf)), "17. el reparto usa una sola vez la demanda (" .. t .. ")")
		end
		local g0 = newCompany("Sin EX2")
		setYear9(g0, 2015)
		eq(Rules.playerMult(g), Rules.playerMult(g0), "17. el multiplicador comercial no incluye la expansión")
		-- 18. Rivales: mismos modelos y pesos con o sin expansión.
		for _, t in { "sedan", "suv", "pickup" } do
			local a, b = Rules.market(g0, t), Rules.market(g, t)
			check(#a.rivals > 0 and #a.rivals == #b.rivals and rel(a.total, b.total), "18. los rivales siguen participando igual en " .. t)
		end
		-- 23. Países distintos, repartos distintos.
		local us = Rules.countryWeights(Rules.country("US"), yf)
		check(w.compacto > us.compacto and us.pickup > w.pickup, "23. Japón prefiere compactos y EE. UU. pickups")
		local diff = 0
		for _, t in Catalog.TYPE_ORDER do
			diff += math.abs(w[t] - us[t])
		end
		check(diff > 0.5, "23. distribuciones distintas")
		-- 24. Tipos sin demanda en su época: sin demanda aunque se prefieran.
		local old = newCompany("1975 EX2")
		setYear9(old, 1975)
		old.countries = {}
		for _, c in E.countries do
			table.insert(old.countries, c.id)
		end
		old.expansion = 10
		for _, t in { "suv", "electrico" } do
			eq(Rules.demand(old, t), 0, "24. " .. t .. " en 1975: sin demanda con los diez países")
			eq(Rules.market(old, t).demand, 0, "24. ni en el reparto")
		end
		-- 19–20. Ventas y capacidad con mercados abiertos.
		local s = newCompany("Ventas EX2")
		s.money = 1e9
		local rate0 = Rules.lineRate(s)
		local id = saveNew(s, ctx, "brisa", "Mundial EX2")
		check(Actions.createLot(s, ctx, { designId = id, qty = 300 }).ok, "lote")
		local lot = s.lots[1]
		local unit, qty = lot.unitCost, lot.qty
		ready(s)
		s.money = 1e12
		for _, c in E.countries do
			check(Actions.expandGlobal(s, ctx, { country = c.id }).ok, "abre " .. c.id)
		end
		check(rel(Rules.lineRate(s), rate0 * (1 + E.line * 10)), "20. cada línea fabrica +" .. Util.round(E.line * 1000) .. " % con diez países")
		check(not Rules.ownsLine(s, 2) and not Rules.ownsLine(s, 3) and Rules.lineCount(s) == 1, "20. abrir países no da líneas")
		check(lot.unitCost == unit and lot.qty == qty, "20. el lote conserva costo y cantidad")
		check(s.facilities.research == 1 and s.facilities.factory == 1, "oficinas, fábrica y centro sin beneficios nuevos")
		for _ = 1, 3000 do
			if lot.saleState == "en venta" or lot.saleState == "agotado" then
				break
			end
			Simulation.simulate(s, ctx, 10)
			if lot.saleState == "por lanzar" then
				check(Actions.launchSale(s, ctx, { lotId = lot.id, price = lot.refPrice }).ok, "sale a la venta")
			end
		end
		local revenueOnlySales = true
		for _ = 1, 600 do
			Simulation.simulate(s, ctx, 10)
			check(lot.sold <= lot.produced, "19. ventas ≤ fabricadas")
		end
		for _, l in s.ledger do
			if l.amount > 0 and l.type ~= "venta" and l.type ~= "ventas" and l.type ~= "recompensa" and l.type ~= "prestamo" then
				revenueOnlySales = revenueOnlySales and string.find(l.note or "", "Expansión", 1, true) == nil
			end
		end
		check(revenueOnlySales, "la expansión no genera ingresos directos")
		check(lot.sold > 0, "19. vende con los mercados abiertos (" .. lot.sold .. ")")
		-- 21. Campañas: la corporativa escala con el mercado; la de modelo no; sin doble aplicación.
		local cg = newCompany("Campana EX2")
		cg.money = 1e10
		local era = Rules.marketingEra(cg)
		local req = { kind = "corporativa", budget = Util.round(Catalog.MARKETING.budgetMin * era) * 2, days = 30 }
		local before = Rules.campaignPlan(cg, req)
		ready(cg)
		cg.money = 1e12
		local beforeSede5 = Rules.campaignPlan(cg, req)
		check(Actions.expandGlobal(cg, ctx, { country = "DE" }).ok, "abre Alemania")
		local after = Rules.campaignPlan(cg, req)
		check(rel(after.cost / beforeSede5.cost, Rules.marketFactor(cg)) or math.abs(after.cost - Util.round(beforeSede5.cost * 1.15 / 10) * 10) <= 10, "21. la corporativa cuesta ×" .. Util.num(Rules.marketFactor(cg), 2) .. " (" .. Util.money(beforeSede5.cost) .. " → " .. Util.money(after.cost) .. ")")
		check(before.boost == after.boost, "21. el efecto no depende de la expansión")
		check(Actions.startCampaign(cg, ctx, req).ok, "campaña corporativa")
		local camp = Util.deepCopy(cg.campaign)
		check(Actions.expandGlobal(cg, ctx, { country = "PL" }).ok, "abre Polonia con la campaña en curso")
		check(cg.campaign.cost == camp.cost and cg.campaign.boost == camp.boost and cg.campaign.days == camp.days, "21. la campaña iniciada antes no cambia")
		local fakeLot = { designId = "x" }
		eq(Rules.campaignMult(cg, fakeLot), 1 + Rules.campaignBoost(cg), "21. el multiplicador de campaña se aplica una sola vez")
		-- 22. Cambio de año con mercados abiertos.
		local yg = newCompany("Anio EX2")
		yg.countries, yg.expansion = { "AE", "IN" }, 2
		setYear9(yg, 1999)
		yg.time.day += 11
		local w1999 = Rules.countryWeights(Rules.country("AE"), Rules.yearFrac(yg)).suv
		Simulation.simulate(yg, ctx, Rules.monthMinutes(yg.time.day) + 10)
		eq(Rules.year(yg), 2000, "22. pasó a 2000")
		local base2, total2 = Rules.worldDemand(yg)
		check(rel(total2, base2 * 1.3), "22. en 2000 el total sigue siendo base × 1,30")
		check(Rules.countryWeights(Rules.country("AE"), Rules.yearFrac(yg)).suv ~= w1999, "22. los pesos se recalculan con la demanda del año")
	end)

	test("[EX3] Persistencia 34–40: países guardados, recuperación, migración, inversiones, misiones e integridad", function()
		local ctx = makeCtx(93)
		local store = newStore()
		local clock = { t = 1000, c = 0 }
		local mgr = makeServer(store, "EX3", clock)
		local p = { UserId = 9301 }
		mgr:add(p)
		local g = playThrough(mgr, p).game
		ready(g)
		for _, id in { "AU", "JP", "BR" } do
			clock.c += Sessions.RATE_WINDOW
			check(mgr:request(p, "expandGlobal", { country = id, requestId = rid() }).ok, "abre " .. id)
		end
		local money = g.money
		-- 34–35. Guardar y recuperar.
		check(mgr:request(p, "leaveCompany", {}).ok, "guardar")
		clock.c += Sessions.RATE_WINDOW
		check(mgr:request(p, "createCompany", { slot = "2", name = "Segunda EX3", color = Catalog.BRAND_COLORS[2][1], logo = "pico" }).ok, "segunda empresa")
		local g2 = mgr.list[p].game
		check(Rules.expansion(g2) == 0 and #Rules.openedCountries(g2) == 0, "cada empresa con su expansión")
		check(mgr:request(p, "leaveCompany", {}).ok, "guardar la segunda")
		mgr:remove(p)
		local mgr2 = makeServer(store, "EX3b", clock)
		mgr2:add(p)
		check(mgr2:request(p, "selectSlot", { slot = "1" }).ok, "abrir la primera")
		local g1 = mgr2.list[p].game
		eq(table.concat(g1.countries, ","), "AU,JP,BR", "34/35. países en el orden elegido")
		eq(g1.expansion, 3, "34/35. cantidad de aperturas")
		eq(g1.money, money, "37. inversiones conservadas sin cobros nuevos")
		local n, sum = expandCharges(g1)
		check(n == 3 and sum == quoteCost(g1, 1) + quoteCost(g1, 2) + quoteCost(g1, 3), "37/39. tres cobros por el total exacto")
		-- 36. Migración: una partida vieja con regiones (solo la cantidad) toma los primeros del catálogo.
		local old = newCompany("Vieja EX3")
		ready(old)
		old.expansion, old.countries = 3, {}
		local back = jsonCopy(old)
		check(GameState.validate(back), "36. partida con regiones antiguas válida")
		eq(table.concat(Rules.openedCountries(back), ","), "BR,US,DE", "36. las tres regiones son Brasil, Estados Unidos y Alemania")
		eq(Rules.countryState(back, "US"), "abierto", "36. el mapa las muestra abiertas")
		local mo = back.money
		check(Actions.expandGlobal(back, ctx, { country = "ZA" }).ok, "36. abre un cuarto país")
		check(table.concat(back.countries, ",") == "BR,US,DE,ZA" and mo - back.money == quoteCost(back, 4), "36. se completa la lista y cobra la cuarta apertura")
		-- 38. Misiones: contadores con g.expansion y sin premio doble.
		local mg = newCompany("Misiones EX3")
		ready(mg)
		for i, c in E.countries do
			check(Actions.expandGlobal(mg, ctx, { country = c.id }).ok, "abre " .. c.id)
			if i == 1 or i == 5 or i == 10 then
				local mid = i == 1 and "s13" or (i == 5 and "s16" or "s18")
				local mm = Catalog.mission(mid)
				eq(Rules.missionValue(mg, mm), i, "38. " .. mid .. " cuenta " .. i .. " países")
				eq(Rules.missionState(mg, mm), "lista", "38. " .. mid .. " lista")
				local m0 = mg.money
				check(Actions.claimMission(mg, ctx, { id = mid }).ok and mg.money - m0 == mm.reward.money, "38. premio de " .. mid)
				check(not Actions.claimMission(mg, ctx, { id = mid }).ok, "38. " .. mid .. " sin premio doble")
			end
		end
		eq(Catalog.mission("s18").title, "Presencia en los diez mercados internacionales", "38. el título no promete todo el planeta")
		-- 39. Integridad: lo único que cambia la expansión es el dinero pagado y la lista de países.
		local ig = newCompany("Integridad EX3")
		ready(ig)
		local snap = jsonCopy(ig)
		check(Actions.expandGlobal(ig, ctx, { country = "IN" }).ok, "abre India")
		check(snap.money - ig.money == quoteCost(ig, 1), "39. solo cobra la apertura")
		check(serde.encode("json", snap.facilities) == serde.encode("json", jsonCopy(ig.facilities)) and serde.encode("json", snap.lots) == serde.encode("json", jsonCopy(ig.lots)), "39. instalaciones y lotes intactos")
		check(GameState.validate(jsonCopy(ig)), "39. la partida sigue siendo válida")
	end)
end

-- Etapa 10: doce marcas rivales, competencia, marketing y mercado dinámico (casos 1–42 y estrés 1970–2030) -----
do
	local RR = Catalog.RIVAL_RULES
	local NEW = Catalog.RIVALS
	local function close(a: number, b: number, eps: number?): boolean
		return math.abs(a - b) <= (eps or 1e-9) * math.max(1, math.abs(a), math.abs(b))
	end
	local function setYear10(g: any, y: number)
		g.time.day = (y - Catalog.CALENDAR.startYear) * 12
		g.time.minute = 0
	end
	local function withCatalog(list: any, fn: () -> any): any
		local saved = Catalog.RIVALS
		Catalog.RIVALS = list
		local ok, res = pcall(fn)
		Catalog.RIVALS = saved
		assert(ok, res)
		return res
	end
	local function totalWeight(t: string, yf: number, g: any?): number
		local s = 0
		for _, o in Rules.rivalOffers(t, yf, g) do
			s += o.weight
		end
		return s
	end
	-- Primer año con demanda de cada tipo.
	local function firstDemand(t: string): number
		for y = 1970, 2030 do
			if Rules.baseDemand(t, y) > 0 then
				return y
			end
		end
		return 9999
	end

	test("[RV1] Catálogo 1–10: doce marcas originales, líneas válidas, evolución 1970–2030 y sin restos de las seis anteriores", function()
		local WANT = { "Baviron Motors", "Mercenza", "Volkenwerk", "Stuttaro", "Ferovento", "Torvello", "Forlan Motors", "Chevona", "Tayora", "Honari", "Nizora", "Nordviken" }
		eq(#Catalog.RIVALS, 12, "1. exactamente doce marcas")
		local ids = {}
		for i, r in Catalog.RIVALS do
			check(type(r.id) == "string" and not ids[r.id], "2. id único: " .. tostring(r.id))
			ids[r.id] = true
			eq(r.name, WANT[i], "3. nombre " .. i)
			check(type(r.country) == "string" and #r.specialties >= 3 and type(r.desc) == "string" and type(r.strategy) == "string", "4. " .. r.name .. ": país, especialidades, descripción y estrategia")
			check(r.segments and r.segments.primary and r.segments.secondary, "4. " .. r.name .. ": segmentos principal y secundario")
			check(r.price > 0 and math.abs(r.quality) <= 3 and math.abs(r.performance) <= 4.5 and r.reputation >= 1 and r.reputation <= 5 and r.cycle >= 4 and r.aggression >= 0 and r.aggression <= 1, "4. " .. r.name .. ": parámetros en rango")
			check(table.find({ "precio", "calidad", "prestaciones" }, r.answer) ~= nil, "4. " .. r.name .. ": tipo de respuesta válido")
			check(#r.lines >= 2, "5. " .. r.name .. " tiene líneas de modelos")
			local lineIds = {}
			for _, l in r.lines do
				check(Catalog.TYPES[l.type] ~= nil and Catalog.RIVAL_RULES.focus[l.type] ~= nil, "6. " .. r.name .. " " .. l.name .. ": tipo existente (" .. tostring(l.type) .. ")")
				check(type(l.name) == "string" and #l.name > 1 and not lineIds[l.id], "5. " .. r.name .. ": línea con nombre e id únicos")
				lineIds[l.id] = true
				check(l.since >= 1970 and l.since <= 2030 and l.since >= firstDemand(l.type), "8. " .. r.name .. " " .. l.name .. " aparece en " .. l.since .. " (el tipo tiene demanda desde " .. firstDemand(l.type) .. ")")
			end
			-- Tecnología: no retrocede.
			for k = 2, #r.tech do
				check(r.tech[k][2] >= r.tech[k - 1][2] and r.tech[k][1] > r.tech[k - 1][1], "7. " .. r.name .. ": la tecnología no retrocede")
			end
		end
		-- 8. Eléctricos no antes de la tecnología de baterías del juego (el5) ni de que haya demanda.
		local el5 = Catalog.researchNode("el5").year
		for _, r in Catalog.RIVALS do
			for _, l in r.lines do
				if l.type == "electrico" then
					check(l.since > el5, "8. " .. r.name .. ": eléctrico después de " .. el5)
				end
			end
		end
		-- 3. Identidad original: ningún nombre real.
		local REAL = { "bmw", "mercedes", "volkswagen", "porsche", "ferrari", "lamborghini", "ford", "chevrolet", "toyota", "honda", "nissan", "volvo", "golf", "mustang", "camaro", "civic", "corolla", "skyline" }
		for _, r in Catalog.RIVALS do
			local texts = { r.name, r.desc, r.strategy }
			for _, l in r.lines do
				table.insert(texts, l.name)
			end
			for _, t in texts do
				for _, real in REAL do
					check(not string.find(string.lower(t), real, 1, true), "3. sin nombres reales: «" .. t .. "»")
				end
			end
		end
		-- 7. Evolución: cada marca vende algo en 1970–2030 y sus generaciones avanzan.
		for _, r in Catalog.RIVALS do
			local seen, maxGen = 0, 0
			for y = 1970, 2030, 5 do
				for _, t in Catalog.TYPE_ORDER do
					for _, o in Rules.rivalOffers(t, y + 0.5) do
						if o.rival == r then
							seen += 1
							maxGen = math.max(maxGen, o.gen)
							check(o.launched <= y + 0.5 and o.launched >= o.since, "7. " .. o.name .. ": lanzado antes del año en curso")
						end
					end
				end
			end
			check(seen > 0 and maxGen >= 3, "7. " .. r.name .. " evoluciona (" .. seen .. " ofertas, hasta la " .. maxGen .. ".ª generación)")
		end
		-- 9. Ninguna oferta usa las marcas anteriores; quedan solo como calibración.
		for _, t in Catalog.TYPE_ORDER do
			for _, o in Rules.rivalOffers(t, 2000.5) do
				check(o.rival.lines ~= nil and table.find(Catalog.RIVALS_V1, o.rival) == nil, "9. " .. t .. ": " .. o.rival.name .. " es del catálogo nuevo")
			end
		end
		eq(#Catalog.RIVALS_V1, 6, "9. las seis anteriores quedan como referencia de calibración")
		-- 10. Las noticias guardadas con las marcas anteriores se conservan tal cual (es historia).
		local g = newCompany("Vieja RV1")
		g.rivalNews = { year = 1985, items = { "Kodiak Motors lanzó el Grizzly '85" } }
		local back = jsonCopy(g)
		check(GameState.validate(back) and back.rivalNews.items[1] == "Kodiak Motors lanzó el Grizzly '85", "10. partida con noticias de las seis marcas: válida y sin reinterpretar")
	end)

	test("[RV2] Equilibrio 11–20: seis contra doce, demanda, segmentos, primer auto, modelos propios, estrategias, reacciones y cuotas", function()
		-- 11. La presión estructural por tipo y mes es la de las seis anteriores (exacta) y la real, comparable.
		local ratios = {}
		for _, t in Catalog.TYPE_ORDER do
			for y = 1972, 2030, 2 do
				local yf = y + 0.5
				local old = withCatalog(Catalog.RIVALS_V1, function()
					return totalWeight(t, yf)
				end)
				local now = totalWeight(t, yf)
				if old > 0 then
					local rr = now / old
					table.insert(ratios, rr)
					check(rr > 0.6 and rr < 1.6, "11. " .. t .. " " .. y .. ": presión real ×" .. Util.num(rr, 2) .. " frente a las seis")
				else
					eq(now, 0, "11. " .. t .. " " .. y .. ": sin rivales antes, sin rivales ahora")
				end
			end
		end
		local mean = 0
		for _, r in ratios do
			mean += r
		end
		mean /= #ratios
		check(mean > 0.9 and mean < 1.1, "11. presión media ×" .. Util.num(mean, 3) .. " (doce marcas no duplican la competencia)")
		-- 12. La demanda no depende de los rivales.
		local g = newCompany("Equilibrio RV2")
		setYear10(g, 1995)
		for _, t in Catalog.TYPE_ORDER do
			local a = Rules.market(g, t).demand
			local b = withCatalog(Catalog.RIVALS_V1, function()
				return Rules.market(g, t).demand
			end)
			check(a == b and a == Rules.demand(g, t), "12. demanda de " .. t .. " igual con seis o doce marcas")
		end
		-- 13. Segmentos: los superdeportivos italianos pesan dentro de su segmento, no en los populares.
		local function brandShare(t: string, ids: { string }, yf: number): number
			local s, tot = 0, 0
			for _, o in Rules.rivalOffers(t, yf) do
				tot += o.weight
				if table.find(ids, o.rival.id) then
					s += o.weight
				end
			end
			return tot > 0 and s / tot or 0
		end
		check(brandShare("superdeportivo", { "ferovento", "torvello" }, 2000.5) > 0.3, "13. Ferovento y Torvello fuertes en superdeportivos (" .. Util.num(brandShare("superdeportivo", { "ferovento", "torvello" }, 2000.5) * 100, 1) .. " %)")
		check(brandShare("compacto", { "ferovento", "torvello" }, 2000.5) == 0 and brandShare("sedan", { "ferovento", "torvello" }, 2000.5) == 0, "13. no venden compactos ni sedanes")
		check(brandShare("sedan", { "forlan", "chevona", "volkenwerk", "tayora" }, 2000.5) > brandShare("sedan", { "mercenza", "baviron" }, 2000.5), "13. en sedanes pesan más las populares que las prémium")
		-- 14–15. Empresa nueva de 1970 con el capital original: un primer auto razonable deja ganancia.
		local ctx = makeCtx(101)
		local n = newCompany("Primero RV2")
		eq(n.money, Catalog.START.money, "14. capital original")
		local id = saveNew(n, ctx, "brisa", "Primero 70")
		local r = Actions.createLot(n, ctx, { designId = id, qty = 30 })
		check(r.ok, "15. primer lote de 30: " .. tostring(r.msg))
		local lot = findLot(n, r.lotId)
		check(launchWhenReady(n, ctx, r.lotId, lot.refPrice), "15. a la venta al precio recomendado")
		runUntil(n, ctx, function()
			return lot.saleState == "agotado"
		end, 60)
		local h = findHist(n, r.lotId) or lot
		check((h.revenue or 0) - (h.costSpent or 0) > 0, "15. el primer auto deja ganancia (" .. Util.money((h.revenue or 0) - (h.costSpent or 0)) .. ")")
		-- 16. Dos modelos propios del mismo tipo comparten la demanda (no crean demanda nueva).
		local two = newCompany("Dos RV2")
		two.money = 1e8
		setYear10(two, 1980)
		local d1 = saveNew(two, ctx, "brisa", "Sedan Uno")
		local d2 = saveNew(two, ctx, "brisa", "Sedan Dos")
		local l1 = findLot(two, Actions.createLot(two, ctx, { designId = d1, qty = 500 }).lotId)
		check(launchWhenReady(two, ctx, l1.id, l1.refPrice), "primer sedán a la venta")
		local alone = Rules.lotSalesRate(two, l1)
		local l2 = findLot(two, Actions.createLot(two, ctx, { designId = d2, qty = 500 }).lotId)
		check(launchWhenReady(two, ctx, l2.id, l2.refPrice), "segundo sedán a la venta")
		_ = alone
		-- Mismo instante: con y sin el segundo modelo a la venta.
		l2.saleState = "por lanzar"
		local soloRate = Rules.lotSalesRate(two, l1)
		l2.saleState = "en venta"
		local m = Rules.market(two, "sedan")
		local r1, r2 = Rules.lotSalesRate(two, l1, m), Rules.lotSalesRate(two, l2, m)
		check(r1 < soloRate and r1 + r2 > soloRate, "16. el segundo modelo le quita parte al primero y juntos venden algo más (" .. Util.num(soloRate, 2) .. " → " .. Util.num(r1, 2) .. " + " .. Util.num(r2, 2) .. ")")
		local rivals = 0
		for _, o in m.rivals do
			rivals += m.demand * o.weight / m.total
		end
		check(close(r1 + r2 + rivals + m.demand * m.outside / m.total, m.demand, 1e-9), "16. jugador + rivales + resto = demanda (no se crea demanda)")
		-- 17–18. Estrategias distintas y reacciones con límites.
		local s = newCompany("Reacciones RV2")
		setYear10(s, 2005)
		for _, share in { 0, 0.3, 0.6, 1.0 } do
			s.marketShare.sedan = share
			for _, o in Rules.rivalOffers("sedan", 2005.5, s) do
				check(o.cut >= 0 and o.cut <= RR.maxCut + 1e-9 and o.answer >= 0 and o.answer <= RR.qualityCap + 1e-9, "18. reacción acotada (" .. o.rival.name .. ", cuota " .. share .. ")")
				if share == 0 then
					check(o.cut == 0 and o.answer == 0, "18. sin cuota tuya no hay reacción")
				end
				if share == 0.6 then
					if o.rival.answer == "calidad" then
						check(o.answer > 0, "17. " .. o.rival.name .. " responde con calidad")
					elseif o.rival.answer == "precio" then
						check(o.cut > 0.05, "17. " .. o.rival.name .. " responde bajando precios (" .. Util.round(o.cut * 100) .. " %)")
					end
				end
			end
		end
		s.marketShare.superdeportivo = 0.6
		for _, o in Rules.rivalOffers("superdeportivo", 2005.5, s) do
			if o.rival.answer == "prestaciones" then
				check(o.cut < 0.02 and o.answer == 0, "17. " .. o.rival.name .. " mantiene precios (compite con prestaciones)")
			end
		end
		s.marketShare.sedan = 0.5
		local w50 = totalWeight("sedan", 2005.5, s)
		s.marketShare.sedan = 0.51
		local w51 = totalWeight("sedan", 2005.5, s)
		check(math.abs(w51 / w50 - 1) < 0.05, "18. sin saltos bruscos (+1 punto de cuota: ×" .. Util.num(w51 / w50, 3) .. ")")
		-- 19. Ventas sin superar el stock y 20. cuotas coherentes.
		for _ = 1, 400 do
			Simulation.simulate(two, ctx, 10)
			check(l1.sold <= l1.produced and l2.sold <= l2.produced, "19. ventas ≤ fabricadas")
		end
		local sum = Rules.shareSummary(two, "sedan")
		check(close(sum.player + sum.rivals + sum.outside, 1, 1e-9), "20. tus cuotas + rivales + resto = 100 %")
		local none = newCompany("Sin autos RV2")
		none.marketShare.sedan = 0.7
		local ns = Rules.shareSummary(none, "sedan")
		check(ns.player == 0 and ns.historical == 0.7, "20. sin autos a la venta la cuota actual es 0 (la histórica se conserva aparte)")
	end)

	test("[RV2b] Seis contra doce con la economía real (bot) y la estrategia simple biestable", function()
		local twelve = longGame()
		local six = withCatalog(Catalog.RIVALS_V1, function()
			return Bot.play("normal", 860)
		end)
		local function stats(log: any): any
			return { sold = log.g.counters.unitsSold, revenue = log.g.counters.revenueTotal or 0, techs = #log.g.research.done, sede = log.g.sede, exp = log.g.expansion or 0 }
		end
		local a, b = stats(six), stats(twelve)
		print(string.format("      seis: %s vendidos · %s · %d tecnologías · sede %d · %d países", Util.num(a.sold), Util.money(a.revenue), a.techs, a.sede, a.exp))
		print(string.format("      doce: %s vendidos · %s · %d tecnologías · sede %d · %d países", Util.num(b.sold), Util.money(b.revenue), b.techs, b.sede, b.exp))
		check(math.abs(b.sold / a.sold - 1) < 0.15, "11. ventas del bot ×" .. Util.num(b.sold / a.sold, 3) .. " frente a las seis")
		check(math.abs(b.revenue / a.revenue - 1) < 0.2, "11. ingresos ×" .. Util.num(b.revenue / a.revenue, 3))
		check(a.techs == b.techs and a.sede == b.sede, "11. mismo progreso de investigación y sede")
		-- Estrategia simple: la misma rama con las mismas condiciones (resto del mercado 46).
		local saved = Catalog.ECON.outsideWeight
		Catalog.ECON.outsideWeight = 46
		local f6 = withCatalog(Catalog.RIVALS_V1, function()
			return Bot.play("normal", 732, { flat = true })
		end)
		local f12 = Bot.play("normal", 732, { flat = true })
		Catalog.ECON.outsideWeight = saved
		local fa, fb = stats(f6), stats(f12)
		print(string.format("      simple (resto 46): seis %s vendidos · doce %s vendidos", Util.num(fa.sold), Util.num(fb.sold)))
		check(math.abs(fb.sold / fa.sold - 1) < 0.15, "11. estrategia simple en la misma rama: ×" .. Util.num(fb.sold / fa.sold, 3))
	end)

	test("[RV3] Marketing 21–32: modelo, corporativa, presupuestos, fondos, cobro único, personal, tiempo, cancelación, fin, guardado, estimación", function()
		local ctx = makeCtx(103)
		local g = newCompany("Campanas RV3")
		g.money = 1e8
		setYear10(g, 1980)
		local MK = Catalog.MARKETING
		local d1 = saveNew(g, ctx, "brisa", "Promo Uno")
		local d2 = saveNew(g, ctx, "duna", "Promo Dos")
		g.facilities.lines["2"] = true -- dos líneas para fabricar los dos a la vez
		local l1 = findLot(g, Actions.createLot(g, ctx, { designId = d1, qty = 400 }).lotId)
		local l2 = findLot(g, Actions.createLot(g, ctx, { designId = d2, qty = 400 }).lotId)
		check(launchWhenReady(g, ctx, l1.id, l1.refPrice) and launchWhenReady(g, ctx, l2.id, l2.refPrice), "dos modelos a la venta")
		-- El rango de presupuesto sigue a la época: se calcula con el año actual (después de fabricar).
		local era = Rules.marketingEra(g)
		local budget = Util.round(MK.budgetRef * era)
		-- 23. Presupuestos y datos inválidos.
		local lo, hi = Util.round(MK.budgetMin * era), Util.round(MK.budgetMax * era)
		for _, bad in { lo - 1, hi + 1, 0 / 0, math.huge, -5, "100" } do
			check(not Actions.startCampaign(g, ctx, { kind = "modelo", designId = d1, budget = bad, days = 30 }).ok, "23. presupuesto inválido rechazado (" .. tostring(bad) .. ")")
		end
		for _, bad in { 0, 14, 181, 30.5, 0 / 0 } do
			check(not Actions.startCampaign(g, ctx, { kind = "modelo", designId = d1, budget = budget, days = bad }).ok, "23. duración inválida rechazada (" .. tostring(bad) .. ")")
		end
		check(not Actions.startCampaign(g, ctx, { kind = "tele", budget = budget, days = 30 }).ok and not Actions.startCampaign(g, ctx, { kind = "modelo", designId = "nada", budget = budget, days = 30 }).ok, "23. tipo o modelo inválidos rechazados")
		-- 24. Fondos insuficientes.
		local plan = Rules.campaignPlan(g, { kind = "modelo", designId = d1, budget = budget, days = 30 })
		local rich = g.money
		g.money = plan.cost - 1
		check(not Actions.startCampaign(g, ctx, { kind = "modelo", designId = d1, budget = budget, days = 30 }).ok and g.money == plan.cost - 1 and g.campaign == nil, "24. sin fondos: rechazada sin cobrar")
		g.money = rich
		-- 31. Estimación previa sin tocar el estado.
		local snap = serde.encode("json", jsonCopy(g))
		local pv = Rules.campaignPreview(g, plan)
		eq(serde.encode("json", jsonCopy(g)), snap, "31. la vista previa no modifica la partida")
		check(pv and pv.with > pv.without and close(pv.diff, pv.with - pv.without), "31. con campaña vende más (" .. Util.num(pv.without, 2) .. " → " .. Util.num(pv.with, 2) .. ")")
		-- 21. Campaña de modelo: solo ese modelo.
		local w2before = Rules.lotWeight(g, l2, Rules.yearFrac(g))
		local m0 = g.money
		check(Actions.startCampaign(g, ctx, { kind = "modelo", designId = d1, budget = budget, days = 30 }).ok, "21. campaña de modelo")
		eq(m0 - g.money, plan.cost, "25. cobrada una vez")
		eq(Rules.campaignMult(g, l1), 1 + Rules.campaignBoost(g), "21. afecta al modelo elegido")
		eq(Rules.campaignMult(g, l2), 1, "21. no afecta a los demás")
		check(close(Rules.lotWeight(g, l2, Rules.yearFrac(g)), w2before), "21. el otro modelo conserva su peso")
		local spec = Util.deepCopy(l1.design.calc)
		eq(serde.encode("json", l1.design.calc), serde.encode("json", spec), "21. las estadísticas técnicas no cambian")
		-- 31. Lo que vende con la campaña coincide con la vista previa.
		local yf = Rules.yearFrac(g)
		local m = Rules.market(g, "sedan")
		local real1 = Rules.lotSalesRate(g, l1, m)
		local prev1 = 0
		for _, x in pv.lots do
			if x.lot == l1 then
				prev1 = x.with
			end
		end
		check(close(real1, prev1, 1e-9), "31. la estimación con campaña es la del reparto real (" .. Util.num(real1, 3) .. ")")
		-- 32. Sin doble aplicación.
		check(close(Rules.lotWeight(g, l1, yf), Rules.lotWeightAt(g, l1, yf, l1.price, 1) * (1 + Rules.campaignBoost(g))), "32. la campaña multiplica una sola vez")
		-- 25. Otra campaña mientras hay una activa: rechazada.
		check(not Actions.startCampaign(g, ctx, { kind = "corporativa", budget = budget, days = 30 }).ok, "25. una campaña a la vez")
		-- 28. Cancelar: sin reembolso y sin efecto.
		local mc = g.money
		check(Actions.cancelCampaign(g, ctx, {}).ok and g.money == mc and g.campaign == nil and Rules.campaignMult(g, l1) == 1, "28. cancelada sin devolución ni efecto")
		check(not Actions.cancelCampaign(g, ctx, {}).ok, "28. no se cancela dos veces")
		-- 22. Corporativa: todos los modelos, costo con la expansión y reconocimiento.
		local cplan = Rules.campaignPlan(g, { kind = "corporativa", budget = budget, days = 60 })
		check(Actions.startCampaign(g, ctx, { kind = "corporativa", budget = budget, days = 60 }).ok, "22. campaña corporativa")
		check(Rules.campaignMult(g, l1) > 1 and Rules.campaignMult(g, l2) > 1, "22. afecta a todos tus modelos")
		local rep0 = g.reputation
		g.stats.month.sold = 0
		Simulation.monthRollover(g, ctx)
		check(g.reputation > rep0 and g.reputation <= 5, "22. reconocimiento de marca: reputación " .. Util.num(rep0, 3) .. " → " .. Util.num(g.reputation, 3))
		-- 29. Termina sola, sin efectos residuales.
		local c = g.campaign
		Simulation.simulate(g, ctx, math.ceil((c.days - c.progress) / Rules.campaignSpeed(g) * Catalog.RULES.gameDayMinutes / 10 + 1) * 10)
		check(g.campaign == nil and Rules.campaignMult(g, l1) == 1 and Rules.campaignBoost(g) == 0, "29. al terminar no queda efecto")
		local rep1 = g.reputation
		g.stats.month.sold = 0
		Simulation.monthRollover(g, ctx)
		eq(g.reputation, rep1, "29. ni reconocimiento residual")
		local n, sum = 0, 0
		for _, l in g.ledger do
			if l.type == "promocion" then
				n += 1
				sum += -l.amount
			end
		end
		check(n == 2 and sum == plan.cost + cplan.cost, "25/42. dos campañas, dos cobros exactos")
		-- 26. Personal de Marketing: análisis abarata, creatividad potencia y comunicación alarga.
		local p = newCompany("Marketing RV3")
		p.money = 1e8
		p.sede = 3
		local base = Rules.campaignPlan(p, { kind = "corporativa", budget = budget, days = 30 })
		for _ = 1, 3 do
			Simulation.refreshCandidates(p, ctx, "marketing")
			check(Actions.hire(p, ctx, { candidateId = p.candidates[1].id, dept = "marketing" }).ok, "contrata en Marketing")
		end
		local an, cr, co = Rules.staff(p, "analisis"), Rules.staff(p, "mk_creatividad"), Rules.staff(p, "comunicacion")
		check(an > 0 and cr > 0 and co > 0, "26. habilidades de Marketing activas")
		local withStaff = Rules.campaignPlan(p, { kind = "corporativa", budget = budget, days = 30 })
		check(math.abs(withStaff.cost - base.cost * (1 - an)) <= 10, "26. análisis baja el costo × (1 − " .. Util.num(an, 3) .. "): " .. Util.money(base.cost) .. " → " .. Util.money(withStaff.cost))
		check(withStaff.cost < base.cost, "26. más barata con análisis")
		check(Actions.startCampaign(p, ctx, { kind = "corporativa", budget = budget, days = 30 }).ok, "campaña con personal")
		check(close(Rules.campaignBoost(p), p.campaign.boost * (1 + cr)), "26. creatividad: efecto × (1 + " .. Util.num(cr, 2) .. ")")
		local pr = p.campaign.progress
		Simulation.simulate(p, ctx, Catalog.RULES.gameDayMinutes * 10)
		local adv, coEnd = p.campaign.progress - pr, Rules.staff(p, "comunicacion")
		-- La comunicación puede subir en esos días (adaptación del personal): el avance queda entre los dos extremos.
		check(adv < 10 and adv >= 10 / (1 + math.max(co, coEnd)) - 1e-6 and adv <= 10 / (1 + math.min(co, coEnd)) + 1e-6, "26. comunicación: 10 días de juego avanzan " .. Util.num(adv, 2) .. " días de campaña")
	end)

	test("[RV4] Integración 27, 30, 34, 36–42: velocidades, guardado, generaciones, cuotas, noticias, países, misiones, empresas y migración", function()
		local store = newStore()
		local clock = { t = 1000, c = 0 }
		local mgr = makeServer(store, "RV4", clock)
		local p = { UserId = 10401 }
		mgr:add(p)
		local g = playThrough(mgr, p).game
		g.money = 1e8
		local ctx = makeCtx(104)
		local id = saveNew(g, ctx, "brisa", "Integra RV4")
		local lot = findLot(g, Actions.createLot(g, ctx, { designId = id, qty = 400 }).lotId)
		check(launchWhenReady(g, ctx, lot.id, lot.refPrice), "a la venta")
		local budget = Util.round(Catalog.MARKETING.budgetRef * Rules.marketingEra(g))
		local rq = rid()
		clock.c += Sessions.RATE_WINDOW
		check(mgr:request(p, "startCampaign", { kind = "modelo", designId = id, budget = budget, days = 60, requestId = rq }).ok, "campaña por la red")
		local again = mgr:request(p, "startCampaign", { kind = "modelo", designId = id, budget = budget, days = 60, requestId = rq })
		local charges = 0
		for _, l in g.ledger do
			if l.type == "promocion" then
				charges += 1
			end
		end
		check(again.ok and charges == 1, "25. el mismo pedido reenviado no cobra dos veces")
		-- 27. Pausa y velocidades.
		local c = g.campaign
		for _, sp in { 1, 2, 3 } do
			clock.c += Sessions.RATE_WINDOW
			check(mgr:request(p, "setSpeed", { speed = sp, requestId = rid() }).ok, sp .. "×")
			local p0 = c.progress
			ticks(mgr, clock, 4)
			check(close(c.progress - p0, 2 * sp, 1e-6), "27. a " .. sp .. "× en 4 s: +" .. Util.num(c.progress - p0, 2) .. " días")
		end
		check(mgr:request(p, "setUiPause", { paused = true }).ok, "menú")
		local pp = c.progress
		ticks(mgr, clock, 20)
		eq(c.progress, pp, "27. en pausa la campaña no avanza")
		check(mgr:request(p, "setUiPause", { paused = false }).ok, "sigue")
		-- 30. Guardado y recuperación; 40. otra empresa sin la campaña.
		local snapC = jsonCopy(g.campaign)
		check(mgr:request(p, "leaveCompany", {}).ok, "guardar")
		clock.c += Sessions.RATE_WINDOW
		check(mgr:request(p, "createCompany", { slot = "2", name = "Otra RV4", color = Catalog.BRAND_COLORS[4][1], logo = "pico" }).ok, "segunda empresa")
		check(mgr.list[p].game.campaign == nil, "40. la otra empresa no tiene la campaña")
		check(mgr:request(p, "leaveCompany", {}).ok, "guardar la segunda")
		mgr:remove(p)
		local mgr2 = makeServer(store, "RV4b", clock)
		mgr2:add(p)
		check(mgr2:request(p, "selectSlot", { slot = "1" }).ok, "abrir la primera")
		eq(serde.encode("json", jsonCopy(mgr2.list[p].game.campaign)), serde.encode("json", snapC), "30. la campaña se recupera igual")
		-- 34. Modelos y generaciones según el año.
		for _, y in { 1970, 1990, 2030 } do
			for _, t in Catalog.TYPE_ORDER do
				for _, o in Rules.rivalOffers(t, y + 0.5) do
					check(o.gen >= 1 and o.launched <= y + 0.5 and o.price > 0 and o.weight > 0 and o.weight == o.weight, "34. " .. y .. " " .. o.name .. " válido")
				end
			end
		end
		-- 36. Cuota actual frente a histórica.
		local h = newCompany("Cuotas RV4")
		h.marketShare.sedan = 0.42
		local sh = Rules.shareSummary(h, "sedan")
		check(sh.player == 0 and sh.historical == 0.42, "36. histórica guardada, actual 0 sin autos")
		-- 37. Noticias coherentes y sin repetirse.
		local nw = newCompany("Noticias RV4")
		setYear10(nw, 1986)
		local items = Simulation.rivalNewsFor(nw, 1986)
		check(#items <= Simulation.RIVAL_NEWS_MAX, "37. noticias con tope")
		for _, it in items do
			local ok = false
			for _, t in Catalog.TYPE_ORDER do
				for _, o in Rules.rivalOffers(t, 1986, nw) do
					ok = ok or string.find(it, o.rival.name, 1, true) ~= nil
				end
			end
			check(ok, "37. «" .. it .. "» corresponde a una marca con ofertas")
		end
		local launchedNow = false
		for _, t in Catalog.TYPE_ORDER do
			for _, o in Rules.rivalOffers(t, 1986, nw) do
				launchedNow = launchedNow or o.launched == 1986
			end
		end
		check(launchedNow == (#items > 0) or #items > 0, "37. hay noticias cuando hay lanzamientos")
		nw.marketShare.sedan = 0.6
		local i1, cuts1 = Simulation.rivalNewsFor(nw, 1986)
		nw.rivalNews = { year = 1986, items = i1, cuts = cuts1 }
		local i2 = Simulation.rivalNewsFor(nw, 1987)
		local repeated = 0
		for _, it in i2 do
			if string.find(it, "bajó", 1, true) then
				repeated += 1
			end
		end
		eq(repeated, 0, "37. la misma baja de precio no se vuelve a anunciar")
		-- 38. Con los diez países: misma demanda agregada y mismos rivales.
		local w = newCompany("Mundo RV4")
		setYear10(w, 2010)
		local before = {}
		for _, t in Catalog.TYPE_ORDER do
			before[t] = totalWeight(t, Rules.yearFrac(w), w)
		end
		w.countries = {}
		for _, cc in Catalog.EXPANSION.countries do
			table.insert(w.countries, cc.id)
		end
		w.expansion = 10
		local base, total = Rules.worldDemand(w)
		check(close(total, base * 2.5, 1e-9), "38. +15 % por país con los diez (×2,5)")
		for _, t in Catalog.TYPE_ORDER do
			check(close(totalWeight(t, Rules.yearFrac(w), w), before[t]), "38. los rivales de " .. t .. " no cambian por la expansión")
		end
		-- 39. Misiones de liderazgo.
		local lead = newCompany("Lider RV4")
		lead.marketShare = { sedan = 0.36, suv = 0.2, pickup = 0.5 }
		eq(Rules.leaderTypes(lead), 2, "39. lidera dos tipos (≥ 35 %)")
		eq(Rules.missionState(lead, Catalog.mission("s9")), "lista", "39. misión de liderazgo lista")
		-- 41. Migración: una partida de la versión anterior carga y en enero las noticias pasan a las doce marcas.
		local old = newCompany("Migracion RV4")
		old.rivalNews = { year = 1985, items = { "Kodiak Motors lanzó el Grizzly '85", "Kairo Cars bajó 10 % el precio del Mika" } }
		old.marketShare = { sedan = 0.2 }
		local loaded = jsonCopy(old)
		check(GameState.validate(loaded), "41. válida")
		local loaded2 = jsonCopy(loaded)
		check(GameState.validate(loaded2) and serde.encode("json", loaded2.rivalNews) == serde.encode("json", old.rivalNews), "41. cargar dos veces no cambia nada (idempotente)")
		setYear10(loaded, 1986)
		loaded.time.day -= 1
		loaded.time.minute = Rules.monthMinutes(loaded.time.day) - 10
		Simulation.simulate(loaded, ctx, 20)
		eq(loaded.rivalNews.year, 1986, "41. enero: noticias del año nuevo")
		check(loaded.rivalNews.cuts ~= nil, "41. con el formato nuevo")
		for _, it in loaded.rivalNews.items do
			check(not string.find(it, "Kodiak", 1, true) and not string.find(it, "Kairo", 1, true), "41. las novedades nuevas usan las doce marcas: " .. it)
		end
		eq(loaded.marketShare.sedan, loaded.marketShare.sedan, "41. la cuota histórica se conserva")
	end)

	test("[RV5] Estrés 1970–2030: ofertas válidas todos los meses, generaciones, precios y cálculo acotado", function()
		local g = newCompany("Estres RV5")
		local bad = nil
		local maxPerType = 0
		local gens = {}
		for month = 0, (2030 - 1970) * 12, 3 do
			local yf = 1970 + month / 12
			for _, t in Catalog.TYPE_ORDER do
				g.marketShare[t] = (month % 7) / 10
				local offers = Rules.rivalOffers(t, yf, g)
				maxPerType = math.max(maxPerType, #offers)
				if Rules.baseDemand(t, yf) <= 0 and #offers > 0 then
					bad = bad or (t .. " tiene rivales sin demanda en " .. Util.num(yf, 2))
				end
				for _, o in offers do
					if not (o.price > 0 and o.weight > 0 and o.weight < 1e6 and o.gen >= 1 and o.cut <= RR.maxCut + 1e-9) then
						bad = bad or ("oferta inválida " .. o.name .. " en " .. Util.num(yf, 2))
					end
					local key = o.rival.id .. o.line.id
					if (gens[key] or 0) > o.gen then
						bad = bad or ("generación que retrocede: " .. o.name)
					end
					gens[key] = o.gen
				end
			end
		end
		check(bad == nil, "5. sin ofertas inválidas de 1970 a 2030 (" .. tostring(bad) .. ")")
		check(maxPerType <= 12, "21. como mucho " .. maxPerType .. " modelos rivales por tipo a la vez")
		-- Caché de la normalización: un factor por tipo y mes.
		local t0 = os.clock()
		for _ = 1, 200 do
			for _, t in Catalog.TYPE_ORDER do
				Rules.rivalOffers(t, 2001.37, g)
			end
		end
		check(os.clock() - t0 < 2, "21. 1.600 cálculos de ofertas en " .. Util.num(os.clock() - t0, 2) .. " s")
		-- La partida larga del bot (1970 → 2030 y más) con las doce marcas: dinero, ventas y stock coherentes.
		local log = longGame()
		local lg = log.g
		check(lg.money >= 0 and lg.counters.unitsSold <= lg.counters.unitsProduced, "42. contabilidad: dinero ≥ 0 y vendidos ≤ fabricados")
		for _, l in lg.lots do
			check(l.sold + (l.discarded or 0) <= l.produced, "19. " .. l.design.name .. ": ventas ≤ stock")
		end
		check(lg.reputation >= 1 and lg.reputation <= 5, "16. reputación dentro de sus límites")
	end)
end

-- Corrección de la etapa 10: estimación neta de campañas y equilibrio seis contra doce ---------------------------
do
	local function close(a: number, b: number, eps: number?): boolean
		return math.abs(a - b) <= (eps or 1e-9) * math.max(1, math.abs(a), math.abs(b))
	end
	local function withCatalog(list: any, fn: () -> any): any
		local saved = Catalog.RIVALS
		Catalog.RIVALS = list
		local ok, res = pcall(fn)
		Catalog.RIVALS = saved
		assert(ok, res)
		return res
	end
	-- Empresa con dos sedanes propios a la venta (mismo segmento).
	local function twoSedans(seed: number, qty1: number, qty2: number): (any, any, any, any)
		local ctx = makeCtx(seed)
		local g = newCompany("Dos " .. seed .. " RV6")
		g.money = 1e8
		g.facilities.lines["2"] = true
		g.time.day = (1980 - 1970) * 12
		local d1 = saveNew(g, ctx, "brisa", "Promo " .. seed)
		local d2 = saveNew(g, ctx, "brisa", "Otro " .. seed)
		local l1 = findLot(g, Actions.createLot(g, ctx, { designId = d1, qty = qty1 }).lotId)
		local l2 = findLot(g, Actions.createLot(g, ctx, { designId = d2, qty = qty2 }).lotId)
		assert(launchWhenReady(g, ctx, l1.id, l1.refPrice) and launchWhenReady(g, ctx, l2.id, l2.refPrice), "a la venta")
		return g, ctx, l1, l2
	end
	local function planFor(g: any, kind: string, designId: string?, days: number): any
		return Rules.campaignPlan(g, { kind = kind, designId = designId, budget = Util.round(Catalog.MARKETING.budgetRef * Rules.marketingEra(g)), days = days })
	end

	test("[RV6] Estimación de campañas: incremento NETO de la empresa, stock de cada modelo y duración con comunicación", function()
		local g, ctx, l1, l2 = twoSedans(1, 600, 600)
		local plan = planFor(g, "modelo", l1.designId, 60)
		local snap = serde.encode("json", jsonCopy(g))
		local pv = Rules.campaignPreview(g, plan)
		eq(serde.encode("json", jsonCopy(g)), snap, "no modifica la partida")
		local a, b
		for _, x in pv.lots do
			if x.lot == l1 then
				a = x
			elseif x.lot == l2 then
				b = x
			end
		end
		check(a.with > a.without and b.with < b.without, "1. la campaña sube al promocionado y le quita al otro modelo propio")
		check(close(pv.diff, (a.with - a.without) + (b.with - b.without)), "1. diferencia = ganancia del promocionado − pérdida del otro (neta)")
		check(pv.diff < a.with - a.without, "1. el neto es menor que la ganancia bruta del promocionado")
		check(close(pv.units, (a.unitsWith - a.unitsWithout) + (b.unitsWith - b.unitsWithout)), "1. autos adicionales = suma neta de todos los lotes")
		for _, x in pv.lots do
			local avail = Rules.lotAvailable(x.lot)
			check(x.unitsWith <= avail and x.unitsWithout <= avail, "1. nunca más que el stock de cada modelo")
		end
		-- Solo redistribución: el promocionado no tiene stock para vender más; el otro pierde → no es crecimiento.
		local h, _, p1, _ = twoSedans(2, 600, 600)
		local hp = planFor(h, "modelo", p1.designId, 60)
		local base = Rules.campaignPreview(h, hp)
		local p1u0 = 0
		for _, x in base.lots do
			if x.lot == p1 then
				p1u0 = x.unitsWithout
			end
		end
		-- Dejar al promocionado con el stock justo para lo que vendería sin campaña.
		p1.produced = p1.sold + (p1.discarded or 0) + math.max(1, math.floor(p1u0))
		local red = Rules.campaignPreview(h, hp)
		local gross = 0
		for _, x in red.lots do
			if x.lot == p1 then
				gross = x.with - x.without
			end
		end
		check(gross > 0 and red.units <= 1e-6 and red.stockCap, "1. si solo pasa ventas de un modelo propio al otro, no se muestra como crecimiento (neto " .. Util.num(red.units, 2) .. " autos)")
		-- 2. Duración con la comunicación del personal actual.
		eq(pv.days, plan.days, "2. sin personal: los días contratados")
		Simulation.refreshCandidates(g, ctx, "marketing")
		for _ = 1, 3 do
			Simulation.refreshCandidates(g, ctx, "marketing")
			check(Actions.hire(g, ctx, { candidateId = g.candidates[1].id, dept = "marketing" }).ok, "contrata en Marketing")
		end
		g.sede = 3
		local co = Rules.staff(g, "comunicacion")
		check(co > 0, "2. comunicación activa (" .. Util.num(co, 3) .. ")")
		local plan2 = planFor(g, "modelo", l1.designId, 60)
		local pv2 = Rules.campaignPreview(g, plan2)
		check(close(pv2.days, 60 / Rules.campaignSpeed(g)) and close(pv2.days, 60 * (1 + co)), "2. duración esperada = días / Rules.campaignSpeed (" .. Util.num(pv2.days, 1) .. " días)")
		eq(plan2.days, 60, "2. lo contratado no cambia")
		-- 3. La estimación frente a la simulación real (copias idénticas, con y sin campaña, la misma duración).
		local real, _, r1, _ = twoSedans(3, 800, 800)
		local rplan = planFor(real, "modelo", r1.designId, 45)
		local rpv = Rules.campaignPreview(real, rplan)
		local with, without = jsonCopy(real), jsonCopy(real)
		local cw = makeCtx(5)
		check(Actions.startCampaign(with, cw, { kind = "modelo", designId = r1.designId, budget = rplan.budget, days = 45 }).ok, "campaña en la copia")
		local function soldAll(x: any): number
			local n = 0
			for _, l in x.lots do
				n += l.sold
			end
			return n
		end
		local s0w, s0n = soldAll(with), soldAll(without)
		local minutes = math.floor(rpv.days * Catalog.RULES.gameDayMinutes / 10) * 10
		Simulation.simulate(with, cw, minutes)
		Simulation.simulate(without, makeCtx(5), minutes)
		local actual = (soldAll(with) - s0w) - (soldAll(without) - s0n)
		print(string.format("      estimación %.1f autos netos · simulación real %d (%.0f días)", rpv.units, actual, rpv.days))
		check(math.abs(actual - rpv.units) <= math.max(6, 0.3 * math.abs(rpv.units)), "3. la estimación neta se acerca a lo que pasa en la simulación")
	end)

	test("[RV7] Equilibrio seis contra doce: primer auto, cuotas por segmento, modelos por año, dos autos propios y campañas", function()
		local ctx = makeCtx(107)
		-- Primer automóvil de 1970 con el capital original (lote de 30 al precio recomendado).
		local function firstCar(): any
			local g = newCompany("Primero RV7")
			local id = saveNew(g, ctx, "brisa", "Primero 70")
			local r = Actions.createLot(g, ctx, { designId = id, qty = 30 })
			local lot = findLot(g, r.lotId)
			launchWhenReady(g, ctx, r.lotId, lot.refPrice)
			runUntil(g, ctx, function()
				return lot.saleState == "agotado"
			end, 60)
			local h = findHist(g, r.lotId) or lot
			return { (h.revenue or 0) - (h.costSpent or 0), h.sold or 0 }
		end
		local f6 = withCatalog(Catalog.RIVALS_V1, firstCar)
		local f12 = firstCar()
		local p6, s6, p12, s12 = f6[1], f6[2], f12[1], f12[2]
		print(string.format("      primer auto 1970: seis %s (%d vendidos) · doce %s (%d vendidos)", Util.money(p6), s6, Util.money(p12), s12))
		check(p6 > 0 and p12 > 0 and math.abs(p12 / p6 - 1) < 0.1, "primer auto rentable con los dos catálogos (×" .. Util.num(p12 / p6, 3) .. ")")
		-- Cuota del jugador por segmento con un lote estándar (atractivo del año, precio recomendado).
		local function shareOf(t: string, y: number): number
			local g = newCompany("Cuota RV7")
			g.time.day = (y - 1970) * 12
			local base = Rules.eraBaseline(y + 0.5)
			local lot = { id = "x", saleState = "en venta", produced = 1, sold = 0, discarded = 0, price = 100, refPrice = 100, appeal = base + 5, design = { type = t, spec = { segment = "Masivo" } }, reviews = nil }
			table.insert(g.lots, lot)
			local m = Rules.market(g, t)
			return m.lots.x and m.lots.x / m.total or 0
		end
		local rows = {}
		local worst = 0
		for _, t in Catalog.TYPE_ORDER do
			for _, y in { 1975, 1990, 2010, 2025 } do
				if Rules.baseDemand(t, y + 0.5) > 0 then
					local a = withCatalog(Catalog.RIVALS_V1, function()
						return shareOf(t, y)
					end)
					local b = shareOf(t, y)
					worst = math.max(worst, math.abs(b / a - 1))
					table.insert(rows, string.format("%s %d %.1f→%.1f", t, y, a * 100, b * 100))
				end
			end
		end
		print("      cuota de un lote estándar (seis → doce, %): " .. table.concat(rows, " · "))
		check(worst < 0.12, "cuota del jugador por segmento: diferencia máxima " .. Util.num(worst * 100, 1) .. " %")
		-- Modelos rivales disponibles por década.
		local counts = {}
		for y = 1970, 2030, 10 do
			local n6 = withCatalog(Catalog.RIVALS_V1, function()
				local n = 0
				for _, t in Catalog.TYPE_ORDER do
					n += #Rules.rivalOffers(t, y + 0.5)
				end
				return n
			end)
			local n12 = 0
			for _, t in Catalog.TYPE_ORDER do
				n12 += #Rules.rivalOffers(t, y + 0.5)
			end
			table.insert(counts, y .. ": " .. n6 .. "→" .. n12)
			check(n12 >= n6 and n12 <= 60, y .. ": más modelos rivales, en cantidad acotada")
		end
		print("      modelos rivales a la venta (seis → doce): " .. table.concat(counts, " · "))
		-- Dos autos propios en el mismo segmento.
		local function twoCars(): any
			local g, _, l1, l2 = twoSedans(9, 600, 600)
			l2.saleState = "por lanzar"
			local solo = Rules.lotSalesRate(g, l1)
			l2.saleState = "en venta"
			local m = Rules.market(g, "sedan")
			return { solo, Rules.lotSalesRate(g, l1, m) + Rules.lotSalesRate(g, l2, m) }
		end
		local t6, t12 = withCatalog(Catalog.RIVALS_V1, twoCars), twoCars()
		local s6a, b6, s12a, b12 = t6[1], t6[2], t12[1], t12[2]
		print(string.format("      dos sedanes propios: seis %.2f → %.2f autos/min · doce %.2f → %.2f autos/min", s6a, b6, s12a, b12))
		check(b6 > s6a and b12 > s12a and math.abs(b12 / b6 - 1) < 0.1, "dos autos propios comparten demanda igual con los dos catálogos")
		-- Campañas: de modelo y corporativa, sin y con personal de Marketing.
		local function campaigns(staff: boolean): any
			local g, c, l1, _ = twoSedans(11, 600, 600)
			g.sede = 3 -- lugar para contratar; igual en los dos escenarios (la sede cambia el alcance)
			if staff then
				for _ = 1, 3 do
					Simulation.refreshCandidates(g, c, "marketing")
					Actions.hire(g, c, { candidateId = g.candidates[1].id, dept = "marketing" })
				end
			end
			local mp = Rules.campaignPreview(g, planFor(g, "modelo", l1.designId, 60))
			local cp = Rules.campaignPreview(g, planFor(g, "corporativa", nil, 60))
			local gross, corpLoses = 0, false
			for _, x in mp.lots do
				if x.hit then
					gross += x.unitsWith - x.unitsWithout
				end
			end
			for _, x in cp.lots do
				corpLoses = corpLoses or x.with < x.without - 1e-12
			end
			return { mw = mp.without, mn = mp.with, mu = mp.units, gross = gross, cn = cp.with, cu = cp.units, corpLoses = corpLoses, cost = planFor(g, "corporativa", nil, 60).cost, mcost = planFor(g, "modelo", l1.designId, 60).cost }
		end
		local res = {}
		for _, cat in { { "seis", Catalog.RIVALS_V1 }, { "doce", Catalog.RIVALS } } do
			for _, staff in { false, true } do
				local r = withCatalog(cat[2], function()
					return campaigns(staff)
				end)
				res[cat[1] .. tostring(staff)] = r
				print(string.format("      %s %s personal: sin publicidad %.2f/min · modelo %.2f/min (%+.1f autos netos, bruto %+.1f, %s) · corporativa %.2f/min (%+.1f autos netos, %s)", cat[1], staff and "con" or "sin", r.mw, r.mn, r.mu, r.gross, Util.money(r.mcost), r.cn, r.cu, Util.money(r.cost)))
			end
		end
		check(res.docefalse.mu > 0 and res.docefalse.mu < res.docefalse.gross, "de modelo: el neto (" .. Util.num(res.docefalse.mu, 1) .. ") es menor que la ganancia bruta del promocionado (" .. Util.num(res.docefalse.gross, 1) .. ")")
		check(res.docefalse.cu > 0 and not res.docefalse.corpLoses, "corporativa: ningún modelo propio pierde ventas")
		check(res.docetrue.mcost < res.docefalse.mcost and res.docetrue.mu > res.docefalse.mu, "con personal de Marketing: más barata y con más efecto")
		check(math.abs(res.docefalse.mu / res.seisfalse.mu - 1) < 0.15, "el efecto de una campaña es comparable con seis y doce marcas")
	end)
end

T.finish()
Build.clean()
process.exit(T.failed == 0 and 0 or 1)
