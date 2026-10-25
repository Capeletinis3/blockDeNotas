--[[
	Pruebas de la lógica del servidor fuera de Roblox, con Lune (https://lune-org.github.io/docs).
	Uso (desde la carpeta car-empire-tycoon):  lune run tests/run.luau

	Los módulos de src/ usan require(script.Parent.X) y require(Shared.X) como en Roblox.
	Este script copia los módulos puros a tests/.build/ reescribiendo esos require a rutas
	de archivo, y después ejecuta los casos. No modifica src/.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local ROOT = process.cwd
local BUILD = "tests/.build"

local function prepare()
	if fs.isDir(BUILD) then
		fs.removeDir(BUILD)
	end
	fs.writeDir(BUILD .. "/shared")
	fs.writeDir(BUILD .. "/server")
	local files = {
		{ "src/shared/Catalog.luau", "shared/Catalog.luau" },
		{ "src/shared/Util.luau", "shared/Util.luau" },
		{ "src/shared/DesignCalc.luau", "shared/DesignCalc.luau" },
		{ "src/server/GameState.luau", "server/GameState.luau" },
		{ "src/server/Simulation.luau", "server/Simulation.luau" },
		{ "src/server/Actions.luau", "server/Actions.luau" },
		{ "src/server/DataService.luau", "server/DataService.luau" },
	}
	for _, f in files do
		local src = fs.readFile(f[1])
		src = src:gsub('local ReplicatedStorage = game:GetService%("ReplicatedStorage"%)\n', "")
		src = src:gsub('local Shared = ReplicatedStorage:WaitForChild%("CarEmpireShared"%)\n', "")
		src = src:gsub("require%(Shared%.(%w+)%)", 'require("../shared/%1")')
		src = src:gsub("require%(script%.Parent%.(%w+)%)", 'require("./%1")')
		assert(not src:find("game:GetService"), f[1] .. " usa servicios de Roblox y no es puro")
		fs.writeFile(BUILD .. "/" .. f[2], src)
	end
end
prepare()

local Catalog = require("./.build/shared/Catalog")
local Util = require("./.build/shared/Util")
local DesignCalc = require("./.build/shared/DesignCalc")
local GameState = require("./.build/server/GameState")
local Simulation = require("./.build/server/Simulation")
local Actions = require("./.build/server/Actions")
local DataService = require("./.build/server/DataService")

-- Mini marco de pruebas --------------------------------------------------------------
local passed, failed = 0, 0
local current = ""
local function check(cond: any, what: string)
	if cond then
		passed += 1
	else
		failed += 1
		print("  ✗ [" .. current .. "] " .. what)
	end
end
local function eq(a: any, b: any, what: string)
	check(a == b, what .. " (esperado " .. tostring(b) .. ", obtenido " .. tostring(a) .. ")")
end
local function test(name: string, fn: () -> ())
	current = name
	local before = failed
	local ok, err = pcall(fn)
	if not ok then
		failed += 1
		print("  ✗ [" .. name .. "] error: " .. tostring(err))
	end
	print((failed == before and "✓ " or "✗ ") .. name)
end

-- Generador pseudoaleatorio determinista (para que las pruebas sean repetibles).
local function seeded(seed: number)
	local state = seed
	return function(): number
		state = (state * 1103515245 + 12345) % 2147483648
		return state / 2147483648
	end
end

local function makeCtx(seed: number)
	local ctx = { events = {} }
	ctx.rng = seeded(seed)
	ctx.notify = function(kind: string, text: string)
		table.insert(ctx.events, { kind, text })
	end
	return ctx
end

-- Serializa como lo haría el DataStore (JSON): detecta tablas no guardables.
local function jsonCopy(v: any): any
	return serde.decode("json", serde.encode("json", v))
end

local function newCompany(name: string, color: string): any
	local clean, err = Actions.validateCompany({ name = name, color = color, difficulty = "normal" })
	assert(clean, err)
	return GameState.newGame({ name = clean.name, color = clean.color, difficulty = clean.difficulty, now = 1000 })
end

local function draftFor(g: any, baseId: string): any
	local d = DesignCalc.newDraft(g, baseId)
	return jsonCopy(d) -- lo que llega por la red es una copia
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

-- Casos ------------------------------------------------------------------------------

test("Catálogo: dos bases disponibles en nivel 1 y piezas indexadas", function()
	local g = newCompany("Ruta Norte Motors", "#7667FF")
	local available = 0
	for _, b in Catalog.BASES do
		if DesignCalc.baseAvailable(g, b) == nil then
			available += 1
		end
	end
	check(available >= 2, "al menos dos bases disponibles")
	check(Catalog.part("frenos", "sport") ~= nil, "pieza frenos deportivos")
	check(Catalog.part("escape", "none").need == "electrico", "categorías con ids repetidos no se pisan")
end)

test("Cálculo de diseño igual a la V3 (Pixel C1 de serie)", function()
	local g = newCompany("Ruta Norte Motors", "#7667FF")
	local c = DesignCalc.computeDesign(g, DesignCalc.newDraft(g, "pixel"))
	eq(c.unitCost, 15550, "costo por unidad")
	eq(c.quality, 61, "calidad")
	eq(c.hp, 130, "potencia")
	eq(c.price, 28700, "precio recomendado")
	eq(c.build, 181, "minutos de producción base")
end)

test("Validación de empresa", function()
	check(Actions.validateCompany({ name = "ab", color = "#7667FF" }) == nil, "rechaza nombres cortos")
	check(Actions.validateCompany({ name = "Empresa OK", color = "#123456" }) == nil, "rechaza colores fuera de la lista")
	check(Actions.validateCompany({ name = "Ñandú Autos", color = "#42E58D" }) ~= nil, "acepta tildes y eñes")
	check(Actions.validateCompany({ name = string.rep("x", 25), color = "#42E58D" }) == nil, "rechaza más de 24 caracteres")
end)

test("Saneamiento: el cliente no puede inventar piezas, bases ni precios", function()
	local g = newCompany("Ruta Norte Motors", "#7667FF")
	local ctx = makeCtx(1)
	local d = draftFor(g, "pixel")
	d.parts.motor = "v8" -- requiere investigación y nivel 5
	local r = Actions.saveDesign(g, ctx, { draft = d })
	check(not r.ok, "pieza bloqueada rechazada")
	d = draftFor(g, "aurora") -- nivel 2
	r = Actions.saveDesign(g, ctx, { draft = d })
	check(not r.ok, "base bloqueada rechazada")
	d = draftFor(g, "pixel")
	d.unitCost = 1
	d.price = 999999
	d.paint.finish = "Cromado"
	r = Actions.saveDesign(g, ctx, { draft = d })
	check(not r.ok, "acabado bloqueado rechazado")
	eq(g.money, 50000, "nada se cobró en los intentos rechazados")
	eq(#g.designs, 0, "nada se guardó")
end)

-- Recorrido completo de la etapa 1 ------------------------------------------------------
local A = newCompany("Ruta Norte Motors", "#7667FF")
local ctxA = makeCtx(42)

test("1-4. Diseñar con piezas, pintura y alerón; cobrar el desarrollo una sola vez", function()
	local d = draftFor(A, "pixel")
	d.name = "Pixel Norte"
	d.parts.frenos = "sport" -- prototipo $3.500
	d.paint.primary = "#D6333F"
	d.paint.secondary = "#15171C"
	d.spoiler = true
	local r = Actions.saveDesign(A, ctxA, { draft = d })
	check(r.ok, "guardado: " .. tostring(r.msg))
	eq(r.paid, 12000 + 3500, "licencia + prototipo cobrados")
	eq(A.money, 50000 - 15500, "dinero tras el desarrollo")
	eq(A.designs[1].version, 1, "versión 1")
	eq(A.counters.designsSaved, 1, "contador de diseños")

	-- Guardar sin cambios: no cobra ni crea versión.
	local again = Actions.saveDesign(A, ctxA, { draft = jsonCopy(A.designs[1]), sourceId = A.designs[1].id })
	check(not again.ok, "sin cambios no se guarda")
	eq(A.money, 34500, "sin cobro extra")

	-- Nueva versión con otra pintura: el desarrollo ya está pago.
	local v2 = jsonCopy(A.designs[1])
	v2.paint.primary = "#3B82F6"
	local r2 = Actions.saveDesign(A, ctxA, { draft = v2, sourceId = A.designs[1].id })
	check(r2.ok, "v2 guardada")
	eq(r2.paid, 0, "v2 sin costo de desarrollo")
	eq(A.designs[1].version, 2, "versión 2")
	eq(A.money, 34500, "dinero intacto")

	-- Segunda base: su licencia se cobra una vez.
	local s = draftFor(A, "brisa")
	s.name = "Brisa Norte"
	local r3 = Actions.saveDesign(A, ctxA, { draft = s })
	check(r3.ok, "sedán guardado")
	eq(r3.paid, 16000, "licencia de Brisa")
	eq(A.money, 34500 - 16000, "dinero tras la segunda licencia")
	local s2 = draftFor(A, "brisa")
	s2.name = "Brisa Norte B"
	local r4 = Actions.saveDesign(A, ctxA, { draft = s2 })
	check(r4.ok, "otro diseño sobre la misma base")
	eq(r4.paid, 0, "la licencia no se vuelve a cobrar")
	A.money += 40000 -- fondos para seguir el recorrido (simula ventas previas)
end)

local orderId: string = ""
test("5. La orden conserva una copia independiente de la versión", function()
	local design = A.designs[1]
	local r = Actions.createOrder(A, ctxA, { designId = design.id, qty = 2 })
	check(r.ok, "orden creada: " .. tostring(r.msg))
	orderId = r.orderId
	local o = A.production.orders[1]
	eq(o.design.version, 2, "la orden fija la v2")
	eq(o.design.spec.paint.primary, "#3B82F6", "copia de la pintura de v2")
	-- Editar el diseño después de crear la orden.
	local v3 = jsonCopy(design)
	v3.paint.primary = "#F7C95C"
	v3.spoiler = false
	local r2 = Actions.saveDesign(A, ctxA, { draft = v3, sourceId = design.id })
	check(r2.ok, "v3 guardada")
	eq(A.designs[1].version, 3, "el proyecto pasó a v3")
	eq(o.design.version, 2, "la orden sigue en v2")
	eq(o.design.spec.paint.primary, "#3B82F6", "la copia no cambió")
	check(o.design.spec.spoiler == true, "la copia conserva el alerón")
	check(o.design.spec ~= A.designs[1], "no comparte la tabla con el proyecto")
	check(not Actions.createOrder(A, ctxA, { designId = design.id, qty = 0 }).ok, "cantidad 0 rechazada")
	check(not Actions.createOrder(A, ctxA, { designId = design.id, qty = 1.5 }).ok, "cantidad fraccionaria rechazada")
	check(not Actions.createOrder(A, ctxA, { designId = "d999", qty = 1 }).ok, "diseño inexistente rechazado")
end)

test("6. Fabricar: cobra dinero y materiales al empezar y entrega al inventario", function()
	local o = A.production.orders[1]
	local cost = o.design.calc.unitCost
	local moneyBefore = A.money
	local acero = A.materials.acero
	Simulation.simulate(A, ctxA, 10)
	check(o.unitStarted, "la unidad empezó")
	eq(A.money, moneyBefore - cost, "cobró el costo fijado")
	eq(A.materials.acero, acero - o.design.calc.mats.acero, "consumió acero")
	local produced = runUntil(A, ctxA, function()
		return A.counters.unitsProduced >= 1
	end, 2000)
	check(produced, "terminó una unidad")
	local u = A.units[1]
	eq(u.status, "almacen", "la unidad está en el almacén")
	eq(u.designVersion, 2, "unidad de la versión fijada")
	eq(u.spec.paint.primary, "#3B82F6", "unidad con la pintura de la copia")
	eq(u.cost, cost, "costo registrado en la unidad")
	check(#A.production.orders == 1 and A.production.orders[1].done == 1, "la orden sigue con 1 de 2")
	runUntil(A, ctxA, function()
		return A.counters.unitsProduced >= 2
	end, 2000)
	eq(#A.production.orders, 0, "orden completa sale de la cola")
	eq(#A.production.history, 1, "orden en el historial")
end)

test("Fabricación detenida por materiales y reintegro al cancelar", function()
	local g = newCompany("Prueba Materiales", "#42E58D")
	local ctx = makeCtx(3)
	local d = draftFor(g, "pixel")
	check(Actions.saveDesign(g, ctx, { draft = d }).ok, "diseño")
	g.materials.electronica = 0
	check(Actions.createOrder(g, ctx, { designId = g.designs[1].id, qty = 1 }).ok, "orden")
	local money = g.money
	Simulation.simulate(g, ctx, 10)
	local o = g.production.orders[1]
	eq(o.status, "detenida", "detenida sin materiales")
	check(string.find(o.reason, "electrónica") ~= nil, "motivo visible: " .. o.reason)
	eq(g.money, money, "no cobró nada sin materiales")
	check(Actions.buyMaterial(g, ctx, { mat = "electronica", qty = 10 }).ok, "compra al proveedor")
	eq(g.money, money - 2600 - 130, "precio + 5 % de impuesto")
	check(not Actions.buyMaterial(g, ctx, { mat = "electronica", qty = 7 }).ok, "paquete inexistente rechazado")
	check(not Actions.buyMaterial(g, ctx, { mat = "oro", qty = 10 }).ok, "material inexistente rechazado")
	Simulation.simulate(g, ctx, 10)
	check(o.unitStarted, "arrancó con materiales")
	local afterStart = g.money
	local elec = g.materials.electronica
	local r = Actions.cancelOrder(g, ctx, { orderId = o.id })
	check(r.ok, "cancelada")
	eq(g.money, afterStart + o.cur.charged, "reintegro exacto del dinero")
	eq(g.materials.electronica, elec + 1, "reintegro de materiales")
end)

test("Fondos insuficientes: la orden se detiene y el dinero nunca queda negativo", function()
	local g = newCompany("Sin Fondos SA", "#FF5F68")
	local ctx = makeCtx(4)
	check(Actions.saveDesign(g, ctx, { draft = draftFor(g, "pixel") }).ok, "diseño")
	g.money = 100
	check(Actions.createOrder(g, ctx, { designId = g.designs[1].id, qty = 1 }).ok, "orden")
	Simulation.simulate(g, ctx, 30)
	eq(g.production.orders[1].status, "detenida", "detenida")
	eq(g.money, 100, "sin cobro")
end)

test("7-8. Concesionario: cliente, oferta, venta e historial", function()
	local u = A.units[1]
	local r = Actions.sendToShowroom(A, ctxA, { unitId = u.id })
	check(r.ok, "enviada al salón")
	eq(u.status, "salon", "estado salón")
	check(not Actions.sendToShowroom(A, ctxA, { unitId = u.id }).ok, "no se envía dos veces")
	local offered = runUntil(A, ctxA, function()
		for _, c in A.customers do
			if c.state == "oferta" and c.unitId == u.id then
				return true
			end
		end
		return false
	end, 6000)
	check(offered, "llegó un cliente con oferta")
	local customer
	for _, c in A.customers do
		if c.state == "oferta" and c.unitId == u.id then
			customer = c
		end
	end
	local moneyBefore = A.money
	local offer = customer.offer
	local sale = Actions.acceptOffer(A, ctxA, { customerId = customer.id })
	check(sale.ok, "venta: " .. tostring(sale.msg))
	eq(A.money, moneyBefore + offer, "entró el dinero de la oferta")
	eq(u.status, "vendido", "unidad vendida")
	eq(#A.sales, 1, "venta en el historial")
	eq(A.sales[1].margin, offer - u.cost, "margen registrado")
	eq(A.counters.unitsSold, 1, "contador de ventas")
	local last = A.ledger[#A.ledger]
	eq(last.type, "venta", "movimiento de venta en el libro")
	-- Repetir la aceptación (doble clic / red): no vuelve a cobrar.
	local again = Actions.acceptOffer(A, ctxA, { customerId = customer.id })
	check(not again.ok, "segunda aceptación rechazada")
	eq(A.money, moneyBefore + offer, "sin doble cobro")
	local sellAgain = Simulation.sellUnit(A, ctxA, u.id, 99999, "concesionario", "x")
	check(not sellAgain.ok, "una unidad vendida no se vende de nuevo")
end)

test("Contraoferta: el servidor tira contra la probabilidad y no vende dos veces", function()
	local g = newCompany("Contra Oferta", "#3B82F6")
	local ctx = makeCtx(7)
	check(Actions.saveDesign(g, ctx, { draft = draftFor(g, "pixel") }).ok, "diseño")
	check(Actions.createOrder(g, ctx, { designId = g.designs[1].id, qty = 1 }).ok, "orden")
	runUntil(g, ctx, function()
		return #g.units > 0
	end, 3000)
	check(Actions.sendToShowroom(g, ctx, { unitId = g.units[1].id }).ok, "al salón")
	runUntil(g, ctx, function()
		return g.customers[1] ~= nil and g.customers[1].state == "oferta"
	end, 6000)
	local c = g.customers[1]
	check(c and c.state == "oferta", "cliente con oferta")
	check(not Actions.counterOffer(g, ctx, { customerId = c.id, amount = c.offer - 100 }).ok, "contraoferta menor rechazada")
	check(not Actions.counterOffer(g, ctx, { customerId = c.id, amount = 0 / 0 }).ok, "NaN rechazado")
	local r = Actions.counterOffer(g, ctx, { customerId = c.id, amount = c.offer + 500 })
	check(r.ok, "contraoferta procesada")
	check(type(r.chance) == "number" and type(r.roll) == "number", "informa probabilidad y tirada")
	local sold = 0
	for _, u in g.units do
		if u.status == "vendido" then
			sold += 1
		end
	end
	check(sold <= 1, "como mucho una venta")
end)

-- Dos jugadores -----------------------------------------------------------------------
test("Dos jugadores: empresas, dinero e inventarios independientes", function()
	local B = newCompany("Kairo Sur", "#FF8A3D")
	local ctxB = makeCtx(99)
	local moneyA = A.money
	local unitsA = #A.units
	local designsA = #A.designs
	check(Actions.saveDesign(B, ctxB, { draft = draftFor(B, "brisa") }).ok, "B guarda su diseño")
	eq(A.money, moneyA, "el dinero de A no cambió")
	eq(#A.designs, designsA, "los diseños de A no cambiaron")
	eq(B.money, 50000 - 16000, "B pagó su propia licencia")
	check(B.devPaid ~= A.devPaid, "listas de desarrollo separadas")
	-- B intenta usar ids de A: solo busca dentro de su propia partida.
	local unitOfA = A.units[#A.units]
	local r = Actions.sendToShowroom(B, ctxB, { unitId = unitOfA.id })
	check(not r.ok, "B no puede mover unidades de A")
	local r2 = Actions.createOrder(B, ctxB, { designId = A.designs[1].id, qty = 1 })
	check(not r2.ok or B.designs[1].id == A.designs[1].id, "B no fabrica diseños de A")
	eq(#A.units, unitsA, "inventario de A intacto")
	eq(#B.units, 0, "B no tiene unidades")
	check(A.company.name ~= B.company.name, "empresas distintas")
end)

-- Guardado ----------------------------------------------------------------------------
local function service(store: any, jobId: string, clock: { t: number })
	return DataService.new(store, {
		jobId = jobId,
		now = function()
			return clock.t
		end,
		wait = function(_: number) end,
		log = function(_: string) end,
		validate = GameState.validate,
		migrate = function(g: any)
			return GameState.migrate(g, clock.t)
		end,
	})
end

test("9. Guardar y recuperar al volver a entrar (por jugador)", function()
	local store = DataService.MemoryStore.new(jsonCopy)
	local clock = { t = 5000 }
	local ds = service(store, "server-1", clock)
	local ok, g = ds:load(111)
	check(ok and g == nil, "jugador nuevo sin partida")
	check(ds:save(111, A), "guardó A")
	local okB = ds:load(222)
	check(okB, "B carga")
	local B = newCompany("Kairo Sur", "#FF8A3D")
	check(ds:save(222, B), "guardó B")
	check(ds:save(111, A, { release = true }), "A sale y libera")
	-- Volver a entrar (otro servidor).
	local ds2 = service(store, "server-2", clock)
	local ok2, loaded = ds2:load(111)
	check(ok2 and loaded ~= nil, "A recuperada")
	eq(loaded.company.name, "Ruta Norte Motors", "nombre")
	eq(loaded.money, A.money, "dinero")
	eq(#loaded.units, #A.units, "inventario")
	eq(#loaded.sales, #A.sales, "historial de ventas")
	eq(loaded.designs[1].version, A.designs[1].version, "versión del diseño")
	local ok3, loadedB = ds2:load(222)
	check(not ok3, "B sigue bloqueada por server-1 (no se pisa)")
	clock.t += DataService.LOCK_TIMEOUT + 1
	ok3, loadedB = ds2:load(222)
	check(ok3 and loadedB.company.name == "Kairo Sur", "candado vencido: B se recupera con sus datos")
	check(store.data["player_111"].game.company.name ~= store.data["player_222"].game.company.name, "claves separadas")
end)

test("Fallos de carga: no se escribe nada y la sesión no guarda", function()
	local store = DataService.MemoryStore.new(jsonCopy)
	local clock = { t = 100 }
	local ds = service(store, "s1", clock)
	ds:load(5)
	ds:save(5, A, { release = true })
	local writes = store.writes
	local snapshot = serde.encode("json", store.data["player_5"])
	store.failNext = DataService.LOAD_ATTEMPTS
	local ok, _, _, code = service(store, "s2", clock):load(5)
	check(not ok, "carga falla con el servicio caído")
	eq(code, "service", "código de error")
	eq(store.writes, writes, "no hubo escrituras")
	eq(serde.encode("json", store.data["player_5"]), snapshot, "datos intactos")

	-- Datos dañados: nunca se pisan.
	store.data["player_6"] = { schema = 1, game = { schema = 1, company = { name = "X" }, money = "mucho" } }
	local before = serde.encode("json", store.data["player_6"])
	local ok2, _, msg2, code2 = service(store, "s2", clock):load(6)
	check(not ok2, "partida dañada no carga")
	eq(code2, "corrupt", "código corrupt")
	check(type(msg2) == "string", "mensaje para el jugador")
	eq(serde.encode("json", store.data["player_6"]), before, "registro dañado intacto")

	-- Reintentos: un fallo transitorio se recupera.
	store.failNext = 2
	local ok3 = service(store, "s3", { t = 100000 }):load(5)
	check(ok3, "se recupera tras fallos transitorios")
end)

test("Fallos de guardado: inválido o sesión perdida no sobrescriben", function()
	local store = DataService.MemoryStore.new(jsonCopy)
	local clock = { t = 100 }
	local ds = service(store, "s1", clock)
	ds:load(7)
	check(ds:save(7, A), "guardado válido")
	local snapshot = serde.encode("json", store.data["player_7"].game)
	local broken = Util.deepCopy(A)
	broken.money = 0 / 0
	local ok, _, code = ds:save(7, broken)
	check(not ok and code == "invalid", "partida inválida no se guarda")
	eq(serde.encode("json", store.data["player_7"].game), snapshot, "se conservan los datos válidos")
	store.failNext = DataService.SAVE_ATTEMPTS
	local ok2, _, code2 = ds:save(7, A)
	check(not ok2 and code2 == "service", "servicio caído informado")
	eq(serde.encode("json", store.data["player_7"].game), snapshot, "datos válidos intactos tras el fallo")
	-- Otro servidor tomó la partida (candado vencido): este deja de guardar.
	clock.t += DataService.LOCK_TIMEOUT + 1
	local other = service(store, "s2", clock)
	check(other:load(7), "s2 toma la partida")
	local ok3, _, code3 = ds:save(7, A)
	check(not ok3 and code3 == "lost_lock", "s1 detecta la sesión perdida")
end)

test("La partida completa es serializable como JSON y valida tras recargar", function()
	local copy = jsonCopy(A)
	local ok, why = GameState.validate(copy)
	check(ok, "valida: " .. tostring(why))
	local v = GameState.view(A)
	check(v.derived.caps.warehouse == 6, "vista con capacidades")
	check(jsonCopy(v) ~= nil, "la vista también es serializable")
end)

print(string.format("\n%d comprobaciones correctas, %d fallidas", passed, failed))
if fs.isDir(BUILD) then
	fs.removeDir(BUILD)
end
process.exit(failed == 0 and 0 or 1)
