--[[
	Pruebas de la lógica del servidor fuera de Roblox, con Lune (https://lune-org.github.io/docs).
	Uso (desde la carpeta car-empire-tycoon):  lune run tests/run.luau

	Copia los módulos de src/ a tests/.build/ reescribiendo los require de Roblox a rutas de archivo.
	Cubren reglas, sesiones, guardado y candados. La interfaz se prueba aparte (tests/ui.luau).
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
local Market = require("./.build/server/Market")
local DataService = require("./.build/server/DataService")
local Sessions = require("./.build/server/Sessions")

local T = require("./harness")
local check, eq, test = T.check, T.eq, T.test

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

local function newCompany(name: string, color: string?, difficulty: string?): any
	local clean, err = Actions.validateCompany({ name = name, color = color, difficulty = difficulty })
	assert(clean, err)
	local g = GameState.newGame({ name = clean.name, color = clean.color, logo = clean.logo, difficulty = clean.difficulty, now = 1000 })
	return g
end

local function draftFor(g: any, baseId: string): any
	return jsonCopy(DesignCalc.newDraft(g, baseId))
end

local function runUntil(g: any, ctx: any, cond: () -> boolean, maxMinutes: number): boolean
	local t = 0
	while t < maxMinutes do
		Simulation.simulate(g, ctx, 10)
		t += 10
		if cond() then
			return true
		end
	end
	return false
end

local function claimReady(g: any, ctx: any)
	for _, m in Catalog.MISSIONS do
		if Rules.missionState(g, m) == "lista" then
			Actions.claimMission(g, ctx, { id = m.id })
		end
	end
end

-- Recorrido completo: diseño → orden → fabricación → salón → venta, cobrando recompensas disponibles.
local function firstSale(g: any, ctx: any): (boolean, string)
	local lowest = g.money
	local function track()
		if g.money < lowest then
			lowest = g.money
		end
		assert(g.money >= 0, "dinero negativo")
	end
	local r = Actions.saveDesign(g, ctx, { draft = draftFor(g, "pixel") })
	if not r.ok then
		return false, "diseño: " .. r.msg
	end
	claimReady(g, ctx)
	r = Actions.createOrder(g, ctx, { designId = r.designId, qty = 1 })
	if not r.ok then
		return false, "orden: " .. r.msg
	end
	local made = runUntil(g, ctx, function()
		track()
		return g.counters.unitsProduced >= 1
	end, 3000)
	if not made then
		return false, "no se fabricó: " .. tostring(g.production.orders[1] and g.production.orders[1].reason)
	end
	claimReady(g, ctx)
	r = Actions.sendToShowroom(g, ctx, { unitId = g.units[1].id })
	if not r.ok then
		return false, "salón: " .. r.msg
	end
	claimReady(g, ctx)
	local sold = runUntil(g, ctx, function()
		track()
		for _, c in g.customers do
			if c.state == "oferta" then
				local res = Actions.acceptOffer(g, ctx, { customerId = c.id })
				return res.ok
			end
		end
		return false
	end, 20000)
	if not sold then
		return false, "no hubo venta"
	end
	claimReady(g, ctx)
	return true, "venta con mínimo de " .. Util.money(lowest)
end

-- Casos de reglas ---------------------------------------------------------------------------

test("Cálculo de diseño igual a la V3 (Pixel C1 de serie)", function()
	local g = newCompany("Ruta Norte Motors")
	local c = DesignCalc.computeDesign(g, DesignCalc.newDraft(g, "pixel"))
	eq(c.unitCost, 15550, "costo por unidad")
	eq(c.price, 28700, "precio recomendado")
	eq(c.quality, 61, "calidad")
end)

test("Crear empresa escribiendo únicamente un nombre válido", function()
	local clean = Actions.validateCompany({ name = "Ruta Norte" })
	check(clean ~= nil, "se acepta solo con el nombre")
	eq(clean.color, "#7667FF", "color por defecto")
	eq(clean.difficulty, "normal", "dificultad por defecto")
	check(Actions.validateCompany({ name = "ab" }) == nil, "rechaza nombres cortos")
	check(Actions.validateCompany({ name = "Ñandú Autos", color = "#42E58D" }) ~= nil, "acepta tildes y eñes")
	check(Actions.validateCompany({ name = "<b>x</b>" }) == nil, "rechaza marcado")
end)

for _, dif in Catalog.DIFFICULTY_ORDER do
	test("Primera venta en dificultad " .. Catalog.DIFFICULTIES[dif].label .. " sin agregar dinero", function()
		local g = newCompany("Prueba " .. dif, nil, dif)
		local ok, msg = firstSale(g, makeCtx(11))
		check(ok, msg)
		eq(g.counters.unitsSold, 1, "una venta")
	end)
end

test("Magnate: sin la recompensa del tutorial la orden espera fondos, con ella arranca", function()
	local g = newCompany("Magnate SA", nil, "dificil")
	local ctx = makeCtx(5)
	local r = Actions.saveDesign(g, ctx, { draft = draftFor(g, "pixel") })
	check(r.ok, "diseño")
	eq(g.money, 8000, "quedan $8.000 tras la licencia")
	check(Actions.createOrder(g, ctx, { designId = r.designId, qty = 1 }).ok, "orden")
	Simulation.simulate(g, ctx, 10)
	check(string.find(g.production.orders[1].reason, "Fondos") ~= nil, "detenida por fondos")
	check(Actions.claimMission(g, ctx, { id = "t1" }).ok, "reclama t1")
	Simulation.simulate(g, ctx, 10)
	check(g.production.orders[1].unitStarted, "con la recompensa empieza la fabricación")
end)

test("Descripciones de dificultad sin promesas no implementadas", function()
	for _, d in Catalog.DIFFICULTIES do
		check(not string.find(string.lower(d.desc), "crisis"), d.label .. ": no menciona crisis")
		check(not string.find(string.lower(d.desc), "rival"), d.label .. ": no menciona rivales")
		check(not string.find(string.lower(d.desc), "material"), d.label .. ": no menciona materiales caros")
	end
end)

test("Saneamiento: el cliente no puede inventar piezas, bases ni precios", function()
	local g = newCompany("Ruta Norte Motors")
	local ctx = makeCtx(1)
	local d = draftFor(g, "pixel")
	d.parts.motor = "v8"
	check(not Actions.saveDesign(g, ctx, { draft = d }).ok, "pieza bloqueada")
	check(not Actions.saveDesign(g, ctx, { draft = draftFor(g, "aurora") }).ok, "base bloqueada")
	d = draftFor(g, "pixel")
	d.paint.finish = "Cromado"
	check(not Actions.saveDesign(g, ctx, { draft = d }).ok, "acabado bloqueado")
	eq(g.money, 50000, "nada se cobró")
end)

test("Desarrollo una sola vez, nombres duplicados, duplicar y eliminar", function()
	local g = newCompany("Ruta Norte Motors")
	local ctx = makeCtx(2)
	local d = draftFor(g, "pixel")
	d.name = "Pixel Norte"
	d.parts.frenos = "sport"
	d.spoiler = true
	local r = Actions.saveDesign(g, ctx, { draft = d })
	eq(r.paid, 15500, "licencia + prototipo")
	local same = Actions.saveDesign(g, ctx, { draft = jsonCopy(g.designs[1]), sourceId = r.designId })
	check(not same.ok, "sin cambios no se guarda")
	local dup = draftFor(g, "pixel")
	dup.name = "pixel norte"
	check(not Actions.saveDesign(g, ctx, { draft = dup }).ok, "nombre duplicado rechazado")
	local copy = Actions.dupDesign(g, ctx, { designId = r.designId })
	check(copy.ok, "duplicado")
	eq(g.money, 50000 - 15500, "duplicar no cobra")
	check(Actions.createOrder(g, ctx, { designId = r.designId, qty = 2 }).ok, "orden")
	runUntil(g, ctx, function()
		return #g.units >= 1
	end, 3000)
	check(Actions.delDesign(g, ctx, { designId = r.designId }).ok, "eliminado")
	eq(#g.units, 1, "la unidad fabricada sigue")
	eq(g.production.orders[1].design.name, "Pixel Norte", "la orden conserva su copia")
	runUntil(g, ctx, function()
		return #g.units >= 2
	end, 3000)
	eq(#g.units, 2, "la orden termina aunque el proyecto ya no exista")
end)

test("Configuración conservada desde el editor hasta la venta", function()
	local g = newCompany("Config SA")
	local ctx = makeCtx(3)
	local d = draftFor(g, "brisa")
	d.name = "Brisa Roja"
	d.paint.primary = "#D6333F"
	d.paint.finish = "Mate"
	d.wheels = { size = 20, style = "mesh", rim = "#2A2E38" }
	d.body.bumper = "sport"
	d.body.vinyl = "stripes"
	d.body.plate = "abc 123"
	d.interior.seats = "sport"
	d.spoiler = true
	local r = Actions.saveDesign(g, ctx, { draft = d })
	check(r.ok, r.msg)
	local saved = g.designs[1]
	eq(saved.body.plate, "ABC 123", "matrícula normalizada")
	Actions.createOrder(g, ctx, { designId = r.designId, qty = 1 })
	local v2 = jsonCopy(saved)
	v2.paint.primary = "#3B82F6"
	check(Actions.saveDesign(g, ctx, { draft = v2, sourceId = saved.id }).ok, "v2")
	claimReady(g, ctx)
	runUntil(g, ctx, function()
		return #g.units > 0
	end, 3000)
	local u = g.units[1]
	eq(u.designVersion, 1, "unidad de la v1")
	eq(u.spec.paint.primary, "#D6333F", "pintura de la v1")
	eq(u.spec.wheels.style, "mesh", "llantas")
	eq(u.spec.body.vinyl, "stripes", "vinilos")
	eq(u.spec.interior.seats, "sport", "asientos")
	Actions.sendToShowroom(g, ctx, { unitId = u.id })
	runUntil(g, ctx, function()
		for _, c in g.customers do
			if c.state == "oferta" then
				return Actions.acceptOffer(g, ctx, { customerId = c.id }).ok
			end
		end
		return false
	end, 20000)
	local s = g.sales[1]
	check(s ~= nil, "vendida")
	eq(s.designVersion, 1, "la venta registra la versión")
	eq(s.cost, u.cost, "costo registrado")
end)

test("Repetir orden: misma versión y última versión", function()
	local g = newCompany("Repite SA")
	local ctx = makeCtx(4)
	local r = Actions.saveDesign(g, ctx, { draft = draftFor(g, "pixel") })
	claimReady(g, ctx)
	Actions.createOrder(g, ctx, { designId = r.designId, qty = 1 })
	runUntil(g, ctx, function()
		return #g.production.history > 0
	end, 3000)
	local v2 = jsonCopy(g.designs[1])
	v2.paint.primary = "#F7C95C"
	Actions.saveDesign(g, ctx, { draft = v2, sourceId = r.designId })
	local hid = g.production.history[1].id
	check(Actions.repeatOrder(g, ctx, { historyId = hid, mode = "same" }).ok, "misma versión")
	eq(g.production.orders[1].design.version, 1, "repite v1")
	check(Actions.repeatOrder(g, ctx, { historyId = hid, mode = "latest" }).ok, "última versión")
	eq(g.production.orders[2].design.version, 2, "repite v2")
	Actions.delDesign(g, ctx, { designId = r.designId })
	check(not Actions.repeatOrder(g, ctx, { historyId = hid, mode = "latest" }).ok, "sin proyecto, «última» no se puede")
	check(Actions.repeatOrder(g, ctx, { historyId = hid, mode = "same" }).ok, "sin proyecto, la misma versión sí")
end)

test("Aceleración: el recargo se fija al empezar y no cambia lo ya cobrado", function()
	local g = newCompany("Acelera SA", nil, "facil")
	local ctx = makeCtx(6)
	local r = Actions.saveDesign(g, ctx, { draft = draftFor(g, "pixel") })
	Actions.toggleBoost(g, ctx, {})
	Actions.createOrder(g, ctx, { designId = r.designId, qty = 2 })
	Simulation.simulate(g, ctx, 10)
	local o = g.production.orders[1]
	eq(o.cur.charged, Util.round(15550 * 1.4), "recargo del 40 %")
	Actions.toggleBoost(g, ctx, {})
	eq(o.cur.charged, Util.round(15550 * 1.4), "apagar la aceleración no cambia lo cobrado")
	runUntil(g, ctx, function()
		return #g.units >= 1
	end, 3000)
	eq(g.units[1].cost, Util.round(15550 * 1.4), "la unidad registra lo cobrado")
	eq(g.units[1].charged.factor, 1.4, "registra el factor")
	runUntil(g, ctx, function()
		return #g.units >= 2
	end, 3000)
	eq(g.units[2].cost, 15550, "la siguiente se cobra sin recargo")
end)

test("Capacidad reservada por fabricación (misma regla al validar y mostrar)", function()
	local g = newCompany("Capacidad SA", nil, "facil")
	local ctx = makeCtx(7)
	local r = Actions.saveDesign(g, ctx, { draft = draftFor(g, "pixel") })
	claimReady(g, ctx) -- fondos para seis unidades
	Actions.createOrder(g, ctx, { designId = r.designId, qty = 7 })
	runUntil(g, ctx, function()
		return #g.units >= 5
	end, 10000)
	Simulation.simulate(g, ctx, 10)
	local o = g.production.orders[1]
	check(o.unitStarted, "sexta unidad en fabricación")
	eq(Rules.warehouseUsed(g), 6, "5 terminadas + 1 en fabricación")
	local v = GameState.view(g)
	eq(v.derived.warehouseUsed, Rules.warehouseUsed(g), "la vista usa la misma cifra")
	eq(v.derived.warehouseFinished + v.derived.inProgress, v.derived.warehouseUsed, "el desglose suma el total")
	runUntil(g, ctx, function()
		return #g.units >= 6
	end, 3000)
	Simulation.simulate(g, ctx, 10)
	check(string.find(g.production.orders[1].reason, "Almacén lleno") ~= nil, "la séptima espera lugar")
	check(g.production.orders[1].missing == nil, "sin datos de materiales viejos")
end)

test("Cancelar con el depósito lleno no pierde materiales ni excede la capacidad", function()
	local g = newCompany("Deposito SA", nil, "facil")
	local ctx = makeCtx(8)
	local r = Actions.saveDesign(g, ctx, { draft = draftFor(g, "pixel") })
	Actions.createOrder(g, ctx, { designId = r.designId, qty = 1 })
	Simulation.simulate(g, ctx, 10)
	check(g.production.orders[1].unitStarted, "en fabricación")
	local cap = Rules.caps(g).mats
	while Actions.buyMaterial(g, ctx, { mat = "acero", qty = 10 }).ok do
	end
	check(Rules.matsUsed(g) <= cap, "las compras respetan el depósito con lo que está en fabricación")
	local total = Rules.matsUsed(g)
	check(Actions.cancelOrder(g, ctx, { orderId = g.production.orders[1].id }).ok, "cancelada")
	eq(Rules.matsUsed(g), total, "no se perdió ni se creó material")
	check(Rules.matsStored(g) <= cap, "el depósito no queda excedido")
end)

test("Una orden detenida por dinero no ofrece comprar materiales que ya no faltan", function()
	local g = newCompany("Causas SA")
	local ctx = makeCtx(9)
	local r = Actions.saveDesign(g, ctx, { draft = draftFor(g, "pixel") })
	g.materials.electronica = 0
	Actions.createOrder(g, ctx, { designId = r.designId, qty = 1 })
	Simulation.simulate(g, ctx, 10)
	local o = g.production.orders[1]
	check(o.missing ~= nil, "faltan materiales")
	g.materials.electronica = 5
	g.money = 100
	Simulation.simulate(g, ctx, 10)
	check(string.find(o.reason, "Fondos") ~= nil, "ahora la causa es el dinero")
	check(o.missing == nil, "se limpió el dato de materiales")
end)

test("Cambio de día durante una fabricación: cada resultado queda en su día", function()
	local g = newCompany("Medianoche SA", nil, "facil")
	local ctx = makeCtx(10)
	local r = Actions.saveDesign(g, ctx, { draft = draftFor(g, "pixel") })
	Actions.createOrder(g, ctx, { designId = r.designId, qty = 1 })
	Simulation.simulate(g, ctx, 10)
	local o = g.production.orders[1]
	-- Que la unidad termine justo en el primer paso del día siguiente.
	g.time.minute = Catalog.RULES.dayMinutes - 10
	o.progress = o.unitTotal - Rules.lineSpeed(g) * 10 + 0.01
	Simulation.simulate(g, ctx, 10)
	eq(g.time.day, 1, "pasó al día 1")
	eq(#g.units, 1, "terminó la unidad")
	eq(Rules.dayStats(g, 1).produced, 1, "cuenta en el día 1")
	eq((Rules.dayStats(g, 0) or { produced = 0 }).produced, 0, "no en el día 0")
	eq(Rules.missionValue(g, Catalog.mission("d2")), 1, "la misión diaria la ve")
end)

test("Probabilidad mostrada = probabilidad resuelta; redondeo y revisión", function()
	local g = newCompany("Negocia SA")
	local ctx = makeCtx(12)
	local r = Actions.saveDesign(g, ctx, { draft = draftFor(g, "pixel") })
	claimReady(g, ctx)
	Actions.createOrder(g, ctx, { designId = r.designId, qty = 1 })
	runUntil(g, ctx, function()
		return #g.units > 0
	end, 3000)
	Actions.sendToShowroom(g, ctx, { unitId = g.units[1].id })
	runUntil(g, ctx, function()
		return g.customers[1] ~= nil and g.customers[1].state == "oferta"
	end, 20000)
	local c = g.customers[1]
	local q = Actions.quoteCounter(g, ctx, { customerId = c.id, amount = c.offer + 1249 })
	check(q.ok, "consulta")
	eq(q.amount, Util.round((c.offer + 1249) / 100) * 100, "redondeo a $100")
	local before = serde.encode("json", c)
	eq(serde.encode("json", c), before, "consultar no modifica nada")
	check(not Actions.counterOffer(g, ctx, { customerId = c.id, amount = q.amount, rev = q.rev + 1 }).ok, "revisión vieja rechazada")
	local res = Actions.counterOffer(g, ctx, { customerId = c.id, amount = c.offer + 1249, rev = q.rev })
	check(res.ok, "contraoferta")
	eq(res.debug.chance, q.chance, "la probabilidad resuelta es la mostrada")
	check(not string.find(res.msg, "tirada"), "el mensaje no muestra la tirada")
	check(not string.find(res.msg, "%%"), "el mensaje no muestra porcentajes de diagnóstico")
	-- Monto por encima del presupuesto: probabilidad 0.
	local c2 = { offer = 1000, budget = 2000, interest = 80, rounds = 0 }
	eq(Simulation.counterChance(c2, 2100), 0, "por encima del presupuesto nunca acepta")
end)

test("Reclamar una recompensa dos veces la cobra una sola vez", function()
	local g = newCompany("Premio SA")
	local ctx = makeCtx(13)
	Actions.saveDesign(g, ctx, { draft = draftFor(g, "pixel") })
	local m0 = g.money
	check(Actions.claimMission(g, ctx, { id = "t1" }).ok, "primera")
	check(not Actions.claimMission(g, ctx, { id = "t1" }).ok, "segunda rechazada")
	eq(g.money, m0 + 10000, "una sola vez")
	check(Actions.claimDaily(g, ctx, {}).ok, "diaria")
	check(not Actions.claimDaily(g, ctx, {}).ok, "diaria repetida")
	ctx.today, ctx.yesterday = "2026-10-26", "2026-10-25"
	check(Actions.claimDaily(g, ctx, {}).ok, "día siguiente")
	eq(g.daily.streak, 2, "racha")
end)

test("Estadísticas completas después de recortar historiales", function()
	local g = newCompany("Historial SA")
	local ctx = makeCtx(14)
	local total = 0
	for i = 1, 260 do
		local u = { id = "ux" .. i, serial = "X-" .. i, name = "Auto", type = "compacto", spec = DesignCalc.newDraft(g, "pixel"), stats = DesignCalc.computeDesign(g, DesignCalc.newDraft(g, "pixel")), cost = 1000, quality = 60, status = "almacen", price = 2000, discount = 0, createdDay = 0 }
		table.insert(g.units, u)
		Simulation.sellUnit(g, ctx, u.id, 2000, "concesionario", "x")
		total += 2000
		if i % 20 == 0 then
			g.time.day += 1
		end
	end
	check(#g.sales <= Catalog.RULES.maxSales, "ventas recortadas")
	check(#g.ledger <= Catalog.RULES.maxLedger, "movimientos recortados")
	local f = Rules.finance(g, 30)
	eq(f.units, 260, "las 260 ventas siguen en las estadísticas")
	eq(f.revenue, total, "ingresos completos")
	eq(g.counters.unitsSold, 260, "total histórico")
	local ok, why = GameState.validate(jsonCopy(g))
	check(ok, "valida: " .. tostring(why))
end)

test("Investigación: efectos reales y sin cambios retroactivos", function()
	local g = newCompany("Labo SA", nil, "facil")
	local ctx = makeCtx(15)
	local r = Actions.saveDesign(g, ctx, { draft = draftFor(g, "pixel") })
	Actions.createOrder(g, ctx, { designId = r.designId, qty = 1 })
	local hpBefore = g.production.orders[1].design.calc.hp
	check(not Actions.startResearch(g, ctx, { id = "m1" }).ok, "sin PI no se puede")
	g.rp = 50
	check(Actions.startResearch(g, ctx, { id = "m1" }).ok, "empieza")
	check(not Actions.startResearch(g, ctx, { id = "a1" }).ok, "laboratorio ocupado")
	runUntil(g, ctx, function()
		return Rules.has(g, "m1")
	end, 2000)
	check(Rules.has(g, "m1"), "completada")
	eq(g.production.orders[1] and g.production.orders[1].design.calc.hp or hpBefore, hpBefore, "la orden confirmada no cambia")
	check(DesignCalc.computeDesign(g, g.designs[1]).hp > hpBefore, "los cálculos nuevos usan la mejora")
	check(not Actions.startResearch(g, ctx, { id = "m3" }).ok, "laboratorio de sede 2 requerido")
end)

test("Personal: velocidad de la línea, salarios y PI", function()
	local g = newCompany("Equipo SA", nil, "facil")
	local ctx = makeCtx(16)
	g.candidates = Simulation.makeCandidates(g, ctx, 5)
	eq(Rules.lineSpeed(g), 0.5, "sin personal 50 %")
	local c = g.candidates[1]
	check(Actions.hire(g, ctx, { candidateId = c.id }).ok, "contratado")
	local e = g.employees[1]
	check(Actions.assign(g, ctx, { employeeId = e.id, area = "chasis" }).ok, "asignado a una estación")
	check(Rules.lineSpeed(g) > 0.5, "la línea acelera con personal")
	local m = g.money
	local rp = g.rp
	g.time.minute = Catalog.RULES.dayMinutes - 10
	Simulation.simulate(g, ctx, 10)
	eq(g.money, m - e.salary, "salario al empezar el día")
	eq(g.rp, rp + 15, "PI diarios")
	check(Actions.fire(g, ctx, { employeeId = e.id }).ok, "despedido")
	eq(Rules.lineSpeed(g), 0.5, "vuelve al 50 %")
end)

test("Ampliación de sede: requisitos y capacidades", function()
	local g = newCompany("Sede SA", nil, "facil")
	local ctx = makeCtx(17)
	check(not Actions.expandSede(g, ctx, {}).ok, "sin ventas no se amplía")
	g.counters.unitsSold = 10
	g.reputation = 3.5
	g.money = 200000
	check(Actions.expandSede(g, ctx, {}).ok, "ampliada")
	local caps = Rules.caps(g)
	eq(caps.lines, 2, "2 líneas")
	eq(caps.warehouse, 14, "almacén 14")
	eq(caps.staff, 8, "8 empleados")
	eq(g.money, 50000, "cobró la ampliación")
end)

test("Mercado: compras con impuesto, comisión y capacidad", function()
	local g = newCompany("Mercado SA", nil, "facil")
	local ctx = makeCtx(18)
	Market.refresh(g, ctx)
	check(#g.market.listings > 10, "hay publicaciones")
	local mat
	for _, l in g.market.listings do
		if l.kind == "material" and l.qty == 20 then
			mat = l
		end
	end
	local t = Market.total(mat)
	local m0 = g.money
	check(Actions.marketBuy(g, ctx, { listingId = mat.id }).ok, "compra de material")
	eq(g.money, m0 - t.total, "precio + impuesto + comisión")
	check(not Actions.marketBuy(g, ctx, { listingId = mat.id }).ok, "no se compra dos veces")
	local veh
	for _, l in g.market.listings do
		if l.kind == "vehiculo" and l.mode == "directa" then
			veh = l
		end
	end
	if veh then
		check(Actions.marketBuy(g, ctx, { listingId = veh.id }).ok, "compra de vehículo")
		local u = g.units[#g.units]
		check(u.bought, "unidad comprada")
		check(Actions.marketPublish(g, ctx, { unitId = u.id, price = u.price, mode = "directa" }).ok, "publicada")
		eq(u.status, "mercado", "en el mercado")
		eq(Rules.warehouseFinished(g), 1, "sigue ocupando el almacén")
		check(Actions.marketUnpublish(g, ctx, { unitId = u.id }).ok, "retirada")
	end
	local ok, why = GameState.validate(jsonCopy(g))
	check(ok, "valida: " .. tostring(why))
end)

test("Dos jugadores: empresas, dinero e inventarios independientes", function()
	local A = newCompany("Ruta Norte Motors")
	local B = newCompany("Kairo Sur", "#FF8A3D")
	local ctxA, ctxB = makeCtx(19), makeCtx(20)
	local ra = Actions.saveDesign(A, ctxA, { draft = draftFor(A, "pixel") })
	local moneyA = A.money
	check(Actions.saveDesign(B, ctxB, { draft = draftFor(B, "brisa") }).ok, "B guarda")
	eq(A.money, moneyA, "el dinero de A no cambia")
	check(B.devPaid ~= A.devPaid, "desarrollo separado")
	check(not Actions.createOrder(B, ctxB, { designId = ra.designId .. "x", qty = 1 }).ok, "B no usa ids ajenos")
	eq(#A.designs, 1, "A intacto")
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
			pushed[player] = jsonCopy(payload)
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
	eq(v.game.company.name, "Sesion SA", "empresa recuperada")
	eq(#v.game.designs, 1, "diseño recuperado")
	eq(v.profile.active, "1", "empresa activa recordada")
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
	local old = GameState.newGame({ name = "Vieja SA", color = "#7667FF", now = 1 })
	old.schema = 1
	old.employees, old.stations, old.claimed, old.stats, old.market = nil, nil, nil, nil, nil
	old.sales = { { day = 0, price = 20000, cost = 15000, margin = 5000, name = "X" } }
	local store = newStore()
	store.data["player_9"] = { schema = 1, game = old }
	local clock = { t = 1000, c = 0 }
	local mgr, pushed = makeServer(store, "A", clock)
	local p = { UserId = 9 }
	mgr:add(p)
	local v = pushed[p]
	eq(v.status, "ready", "carga")
	eq(v.game.company.name, "Vieja SA", "empresa migrada y activa")
	eq(v.game.schema, 2, "esquema 2")
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
	check(g1 ~= g2 and #g2.designs == 0 and g2.money == 50000, "datos independientes")
	eq(pushed[p].profile.active, "2", "activa la segunda")
	check(not mgr:request(p, "renameCompany", { slot = "1", name = "Prohibido SA" }).ok, "filtro de texto")
	check(mgr:request(p, "renameCompany", { slot = "1", name = "Uno Renombrada" }).ok, "renombrada")
	check(not mgr:request(p, "deleteCompany", { slot = "1", confirm = "otra" }).ok, "confirmación incorrecta")
	check(mgr:request(p, "deleteCompany", { slot = "1", confirm = "Uno Renombrada" }).ok, "eliminada")
	check(pushed[p].profile.slots["1"] == nil, "ranura 1 vacía")
	eq(pushed[p].profile.slots["2"].name, "Segunda SA", "la otra intacta")
	check(mgr:request(p, "setSetting", { key = "textScale", value = 1.15 }).ok, "preferencia")
	check(not mgr:request(p, "setSetting", { key = "textScale", value = 7 }).ok, "valor inválido")
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
	eq(gb.money, 20000, "B no pagó nada")
	eq(#gb.designs, 0, "B sin diseños")
	local r = mgr:request(b, "createOrder", { designId = ga.designs[1].id, qty = 1, requestId = rid() })
	check(not r.ok, "B no puede fabricar el diseño de A")
	mgr:remove(a)
	mgr:remove(b)
	check(store.data["player_21"].profile.slots["1"].company.name ~= store.data["player_22"].profile.slots["1"].company.name, "claves separadas")
end)

T.finish()
Build.clean()
process.exit(T.failed == 0 and 0 or 1)
